"""Simulate the LPB load model on the sample case and read its VARs.

The example loads ``sample_case/lpb_load_bench.sav``, attaches the
``LPB1BL`` load model (``sample_case/LPB1BL.dyr``) to bus 1 and the
``PLBVFU1`` playback model to the slack bus 3, and plays ``sample.lpb`` as the
active and reactive demand of the load.  While running it:

* records the bus voltages, the requested load, the power delivered by the
  network and the eight model VARs as channels;
* pauses at a few instants and prints the VARs read directly from PSS/E;
* writes ``output/<case>.out``, ``output/<case>.csv`` and ``output/<case>.log``.

Run it with the Python interpreter that matches your PSS/E installation:

    python examples/run_lpb_load_example.py --psse-version 35
    python examples/run_lpb_load_example.py --psse-version 35 --tfp 0.2 --tfq 0.5 --plot

The code runs under Python 2.7 (PSS/E 33) and Python 3.
"""

from __future__ import print_function

import argparse
import csv
import glob
import os
import sys

MODEL_NAME = "LPB1BL"
SUPPORTED_VERSIONS = (33, 34, 35, 36)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASE_DIR = os.path.join(ROOT, "sample_case")
LIBRARY_DIR = os.path.join(ROOT, "libraries")
OUTPUT_DIR = os.path.join(ROOT, "output")

SAV_FILE = "lpb_load_bench.sav"
DYR_FILE = "LPB1BL.dyr"
TABLE_NAME = "sample"      # ICON 3 of the load model, file sample.lpb
SLACK_PROFILE = "Flat"     # character ICON 3 of PLBVFU1, file Flat.plb

LOAD_BUS, MID_BUS, SLACK_BUS = 1, 2, 3
LOAD_ID, SLACK_ID = "1", "1"

DELT = 0.001               # integration step [s]
PQBRAK = 0.7               # constant-power breakpoint for the network solution
PAUSES = (0.5, 1.5, 2.5, 5.5)

# Meaning of each model VAR, counted from the first one (L).
VAR_NAMES = (
    "P initial", "Q initial",
    "P lag previous", "Q lag previous",
    "P lag", "Q lag",
    "previous instant", "current instant",
)
POWER_VARS = range(6)      # VARs in system per unit


# ----------------------------------------------------------------------
# PSS/E start-up
# ----------------------------------------------------------------------

def find_psse_folders(version):
    """Return (PSSBIN, PSSPY) for a standard installation of ``version``."""
    python_tag = "PSSPY%d%d" % sys.version_info[:2]
    roots = [r"C:\Program Files\PTI\PSSE%d" % version,
             r"C:\Program Files (x86)\PTI\PSSE%d" % version]
    for root in roots:
        # PSS/E 35 and later install under a minor-version folder (35.5, ...).
        for base in sorted(glob.glob(os.path.join(root, "*")), reverse=True) + [root]:
            pssbin = os.path.join(base, "PSSBIN")
            if not os.path.isdir(pssbin):
                continue
            psspy_dir = os.path.join(base, python_tag)
            return pssbin, psspy_dir if os.path.isdir(psspy_dir) else pssbin
    return None, None


def start_psse(version, pssbin=None, psspy_dir=None):
    """Import and initialise ``psspy`` for the requested PSS/E version."""
    if pssbin is None:
        pssbin, found_psspy = find_psse_folders(version)
        psspy_dir = psspy_dir or found_psspy
    if pssbin is None:
        raise RuntimeError("PSS/E %d not found; pass --pssbin and --psspy-dir" % version)
    psspy_dir = psspy_dir or pssbin

    for folder in (pssbin, psspy_dir):
        if folder not in sys.path:
            sys.path.insert(0, folder)
    os.environ["PATH"] = pssbin + os.pathsep + os.environ["PATH"]
    if hasattr(os, "add_dll_directory"):
        os.add_dll_directory(pssbin)

    try:
        __import__("psse%d" % version)    # sets up PSS/E 34 and later
    except ImportError:
        pass
    import psspy
    import redirect

    redirect.psse2py()
    check("psseinit", psspy.psseinit(50))
    return psspy


def check(label, result):
    """Raise if a psspy call returned a nonzero error code."""
    code = result[0] if isinstance(result, (tuple, list)) else result
    if code != 0:
        raise RuntimeError("%s returned error code %s" % (label, code))
    return result


# ----------------------------------------------------------------------
# Case preparation
# ----------------------------------------------------------------------

def prepare_case(psspy, version, log_path):
    _i = psspy.getdefaultint()
    _f = psspy.getdefaultreal()

    check("case", psspy.case(SAV_FILE))
    for output in (psspy.progress_output, psspy.report_output,
                   psspy.alert_output, psspy.prompt_output):
        output(2, log_path, [0, 0])

    # Machines to Norton equivalents.  conl runs in three steps (APIOPT 1
    # initialize, 2 convert, 3 housekeeping); converting 0 % to constant
    # current or admittance keeps every load as constant power.
    check("cong", psspy.cong(0))
    for apiopt in (1, 2, 3):
        check("conl", psspy.conl(0, 1, apiopt, [0, 0], [0.0, 0.0, 0.0, 0.0]))
    check("ordr", psspy.ordr(0))
    check("fact", psspy.fact())
    check("tysl", psspy.tysl(0))

    library = os.path.join(LIBRARY_DIR, "v%d" % version,
                           "%s_v%d.dll" % (MODEL_NAME, version))
    if not os.path.isfile(library):
        raise RuntimeError("model library not found: %s" % library)
    check("addmodellibrary", psspy.addmodellibrary(library))
    check("dyre_new", psspy.dyre_new([1, 1, 1, 1], DYR_FILE, "", "", ""))
    check("set_netfrq", psspy.set_netfrq(0))
    check("solution_parameters_4",
          psspy.solution_parameters_4([_i] * 5, [_f] * 9 + [PQBRAK] + [_f] * 9))
    check("dynamics_solution_param_2",
          psspy.dynamics_solution_param_2([250, _i, _i, _i, _i, _i, _i, _i],
                                          [0.2, 0.0001, DELT, 0.08, _f, _f, _f, _f]))
    check("change_plmod_chricn",
          psspy.change_plmod_chricn(SLACK_BUS, SLACK_ID, "PLBVFU1", 3, SLACK_PROFILE))


def model_index(psspy, kind):
    """First CON, ICON or VAR index of the load model."""
    return check("lmodind " + kind, psspy.lmodind(LOAD_BUS, LOAD_ID, "CHARAC", kind))[1]


def set_lag_constants(psspy, tfp, tfq):
    """CON 1 is Tfp and CON 2 is Tfq; values below 4*DELT bypass the lag."""
    check("change_ldmod_con Tfp", psspy.change_ldmod_con(LOAD_BUS, LOAD_ID, MODEL_NAME, 1, tfp))
    check("change_ldmod_con Tfq", psspy.change_ldmod_con(LOAD_BUS, LOAD_ID, MODEL_NAME, 2, tfq))


def add_channels(psspy, first_var):
    check("voltage_channel", psspy.voltage_channel([-1, -1, -1, LOAD_BUS], "V BUS1"))
    check("voltage_channel", psspy.voltage_channel([-1, -1, -1, SLACK_BUS], "V BUS3"))
    check("load_array_channel", psspy.load_array_channel([-1, 1, LOAD_BUS], LOAD_ID, "P LOAD"))
    check("load_array_channel", psspy.load_array_channel([-1, 2, LOAD_BUS], LOAD_ID, "Q LOAD"))
    # Flow from bus 1 towards bus 2; the power delivered to the load is its negative.
    check("branch_p_and_q_channel",
          psspy.branch_p_and_q_channel([-1, -1, -1, LOAD_BUS, MID_BUS], "1",
                                       ["P DELIVERED", "Q DELIVERED"]))
    for offset, name in enumerate(VAR_NAMES):
        check("var_channel", psspy.var_channel([-1, first_var + offset], "VAR " + name.upper()))


# ----------------------------------------------------------------------
# Reading the model during the run
# ----------------------------------------------------------------------

def read_vars(psspy, first_var):
    """Return the eight model VARs as a list of floats."""
    return [check("dsrval", psspy.dsrval("VAR", first_var + offset))[1]
            for offset in range(len(VAR_NAMES))]


def print_vars(instant, values, system_mva):
    print("\nModel VARs at t = %.3f s" % instant)
    for offset, (name, value) in enumerate(zip(VAR_NAMES, values)):
        if offset in POWER_VARS:
            shown = "%10.4f %s" % (value * system_mva, "MW" if offset % 2 == 0 else "Mvar")
        elif value < 0.0:
            shown = "    (table not active yet)"
        else:
            shown = "%10.4f s" % value
        print("  L+%d  %-17s %s" % (offset, name, shown))


def export_csv(out_path, csv_path, system_mva):
    """Write every channel as CSV, with powers in MW and Mvar."""
    import dyntools

    _, names, data = dyntools.CHNF(out_path).get_data()
    columns = [key for key in names if key != "time"]
    labels = [names[key].strip() for key in columns]
    scale = []
    for label in labels:
        upper = label.upper()
        if upper in ("P LOAD", "Q LOAD") or any(
                upper == "VAR " + VAR_NAMES[offset].upper() for offset in POWER_VARS):
            scale.append(system_mva)
        elif upper in ("P DELIVERED", "Q DELIVERED"):
            scale.append(-1.0)
        else:
            scale.append(1.0)

    with open(csv_path, "w") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(["Time"] + labels)
        for row, instant in enumerate(data["time"]):
            writer.writerow(["%.6f" % instant] +
                            ["%.6f" % (data[key][row] * factor)
                             for key, factor in zip(columns, scale)])
    return labels


def plot_csv(csv_path, png_path):
    """Plot the requested and delivered power, if matplotlib is available."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib is not installed; skipping the plot")
        return
    with open(csv_path) as handle:
        rows = list(csv.DictReader(handle))
    time = [float(row["Time"]) for row in rows]
    figure, axes = plt.subplots(2, 1, sharex=True, figsize=(10, 6))
    for axis, component, unit in ((axes[0], "P", "MW"), (axes[1], "Q", "Mvar")):
        axis.plot(time, [float(row[component + " LOAD"]) for row in rows], label="requested")
        axis.plot(time, [float(row[component + " DELIVERED"]) for row in rows], "--",
                  label="delivered")
        axis.set_ylabel("%s [%s]" % (component, unit))
        axis.grid(True)
        axis.legend()
    axes[1].set_xlabel("Time [s]")
    figure.tight_layout()
    figure.savefig(png_path, dpi=120)
    print("Plot written to %s" % png_path)


# ----------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--psse-version", type=int, default=35, choices=SUPPORTED_VERSIONS)
    parser.add_argument("--pssbin", help="PSSBIN folder, if not in the default location")
    parser.add_argument("--psspy-dir", help="folder with psspy for this Python")
    parser.add_argument("--tfp", type=float, default=0.0, help="P lag time constant [s]")
    parser.add_argument("--tfq", type=float, default=0.0, help="Q lag time constant [s]")
    parser.add_argument("--t-end", type=float, default=10.0, help="simulation end [s]")
    parser.add_argument("--case-name", default="example", help="name of the output files")
    parser.add_argument("--plot", action="store_true", help="save a PNG with matplotlib")
    args = parser.parse_args()

    if not os.path.isdir(OUTPUT_DIR):
        os.makedirs(OUTPUT_DIR)
    out_path = os.path.join(OUTPUT_DIR, args.case_name + ".out")
    csv_path = os.path.join(OUTPUT_DIR, args.case_name + ".csv")
    log_path = os.path.join(OUTPUT_DIR, args.case_name + ".log")

    psspy = start_psse(args.psse_version, args.pssbin, args.psspy_dir)
    # The model and the playback read sample.lpb and Flat.plb from the working folder.
    os.chdir(CASE_DIR)
    prepare_case(psspy, args.psse_version, log_path)
    set_lag_constants(psspy, args.tfp, args.tfq)

    first_con = model_index(psspy, "CON")
    first_var = model_index(psspy, "VAR")
    system_mva = psspy.sysmva()
    print("Model %s at bus %d: Tfp = %.4f s, Tfq = %.4f s (CON %d and %d), VARs %d..%d"
          % (MODEL_NAME, LOAD_BUS,
             check("dsrval", psspy.dsrval("CON", first_con))[1],
             check("dsrval", psspy.dsrval("CON", first_con + 1))[1],
             first_con, first_con + 1, first_var, first_var + len(VAR_NAMES) - 1))

    add_channels(psspy, first_var)
    check("strt", psspy.strt(0, out_path))
    for pause in [instant for instant in PAUSES if instant < args.t_end] + [args.t_end]:
        check("run", psspy.run(0, pause, 0, 1, 0))
        print_vars(pause, read_vars(psspy, first_var), system_mva)

    export_csv(out_path, csv_path, system_mva)
    print("\nChannels written to %s" % csv_path)
    print("PSS/E log written to %s" % log_path)
    if args.plot:
        plot_csv(csv_path, os.path.join(OUTPUT_DIR, args.case_name + ".png"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
