# PSS/E LPB LOAD — model LPB1BL

User load characteristic for PSS/E. It replaces the static demand of a load with the active and reactive power read from an `.lpb` table, with an optional first-order lag on each component.

| Item | Value |
| --- | --- |
| Model type | `USRLOD`, coordinated (`IT=1`) |
| Main entry | `LPB1BL` |
| Network entry | `TPB1BL` |
| PSS/E versions | 33, 34, 35, 36 |
| Build date | 2026-10-28 |

## Contents

```text
libraries/v<version>/LPB1BL_v<version>.dll   compiled model, one per PSS/E version
fortran/                                     Fortran source of the model (see below)
sample_case/                                 three-bus case ready to simulate
    lpb_load_bench.sav                       network (60 Hz, 100 MVA)
    LPB1BL.dyr                               dynamic data
    sample.lpb                               sample demand table of the load
    Flat.plb                                 flat voltage and frequency profile of the slack
    Vsteps.plb                               slack voltage steps up and down (validation)
examples/run_lpb_load_example.py             simulation and VAR access example
report/LPB1BL_validation_report.pdf          validation report
MANIFEST.json                                model data and SHA-256 of every file
```

### Libraries

| PSS/E | DLL |
| --- | --- |
| 33 | `libraries/v33/LPB1BL_v33.dll` |
| 34 | `libraries/v34/LPB1BL_v34.dll` |
| 35 | `libraries/v35/LPB1BL_v35.dll` |
| 36 | `libraries/v36/LPB1BL_v36.dll` |

Load the DLL that matches your PSS/E version before reading the dynamic data:

```python
psspy.addmodellibrary(r"libraries\v35\LPB1BL_v35.dll")
psspy.dyre_new([1, 1, 1, 1], "LPB1BL.dyr", "", "", "")
```

### Fortran sources

| PSS/E | Fortran source |
| --- | --- |
| 33, 34, 35 | `fortran/LPB1BL.f` |
| 36 | `fortran/LPB1BL_VINDP.f`, the PSS/E 36 `PSSDM` interface source |

Both files describe the same model. PSS/E 36 accesses the dynamic data through the `PSSDM` module instead of `COMON4.INS`, so its DLL is compiled from a copy converted automatically during the build.

## Behaviour

- Until the first instant of the table, the standard PSS/E load is left untouched.
- From the first instant on, each enabled component (P and/or Q) follows the table with linear interpolation between rows and holds the last value after the last row.
- Each component passes through a first-order lag with time constant `Tfp` (P) or `Tfq` (Q), solved exactly: `y = u + (y_prev - u)·exp(-Δt/T)`.
- If a time constant is below `4·DELT`, its lag is bypassed. With `DELT = 1 ms`, any value below 4 ms (including 0) disables the lag.
- When the table takes over, the lags start from the standard load, so the transition from the static load is continuous.
- If the table file is missing or invalid, the problem is reported in the PSS/E log and the load keeps its standard behaviour.

## Load characteristics

### The three standard parts

PSS/E represents every load as the sum of three parts. Each part is given by its value at 1 pu voltage (`P0`, `Q0`) and changes with the bus voltage `V` (pu) in its own way:

| Part | Demand at voltage `V` | Behaviour |
| --- | --- | --- |
| Constant power (MVA) | `P = P0`, `Q = Q0` | The demand does not depend on the voltage, so the current grows as the voltage falls. It is the most demanding part for the network. Below the breakpoint `PQBRAK` (0.7 pu by default), PSS/E reduces it along an elliptical current-voltage curve that reaches zero at `V = 0`, so the network solution does not diverge. |
| Constant current | `P = P0·V`, `Q = Q0·V` | The demand is proportional to the voltage and the current stays constant. Below 0.5 pu, a fixed breakpoint, PSS/E reduces it in the same way. |
| Constant admittance | `P = P0·V²`, `Q = Q0·V²` | The load behaves as a fixed impedance, and its demand falls with the square of the voltage. It needs no breakpoint. |

A load flow case holds every load as constant power. The split between the three parts is set before the dynamic simulation with `conl` (see below).

### How LPB1BL uses them

- Before the first table instant, the load keeps the mix of characteristics set with `conl`. The same holds at all times for a component whose ICON is `0`.
- Once the table takes over, the model rebuilds the whole standard demand of the load (all three parts at the present voltage) and replaces it with the table value. Two consequences follow:
  - The table demand behaves as **constant power**, whatever the `conl` split.
  - Below `PQBRAK`, the table demand is reduced by the same factor that PSS/E applies to a constant-power load.
- In the sample case and in the example, all loads stay at 100 % constant power. The demand before the table therefore equals the first row of `sample.lpb` exactly.

### Converting loads with `conl`

`conl` converts the constant-power part of the loads into the requested mix of constant current and constant admittance. Whatever is not converted stays as constant power. It runs on the solved load flow case, after `cong` and before `ordr`, `fact` and `tysl`:

```python
ierr, rlods = psspy.conl(sid, all, apiopt, status, loadin)
```

| Argument | Meaning |
| --- | --- |
| `sid`, `all` | Loads to convert. `all = 1` converts every bus; `all = 0` converts only the buses of subsystem `sid`. Used only with `apiopt = 2`. |
| `apiopt` | Step of the conversion. It must be called three times: `1` initializes, `2` converts and `3` does the closing housekeeping. |
| `status[0]` | Conversion method, used with `apiopt = 1`: `0` converts the existing constant-power load; `1` and `2` first rebuild the loads at the present voltage or at unity voltage. |
| `status[1]` | Bus filter, used with `apiopt = 2`: `0` all buses, `1` type 1 buses only, `2` type 2 and 3 buses only. |
| `loadin` | Percentages, used with `apiopt = 2`: `[P to constant current, P to constant admittance, Q to constant current, Q to constant admittance]`. |
| `rlods` | Returned: the number of loads still unconverted. If it is not zero after `apiopt = 2`, call that step again with `all = 1`. |

Keep every load as constant power, as the sample case does:

```python
for apiopt in (1, 2, 3):
    ierr, rlods = psspy.conl(0, 1, apiopt, [0, 0], [0.0, 0.0, 0.0, 0.0])
```

Mixed conversion. The active power becomes 40 % constant current, 30 % constant admittance and 30 % constant power, and the reactive power becomes 100 % constant admittance:

```python
psspy.cong(0)
ierr, rlods = psspy.conl(0, 1, 1, [0, 0], [0.0, 0.0, 0.0, 0.0])        # initialize
ierr, rlods = psspy.conl(0, 1, 2, [0, 0], [40.0, 30.0, 0.0, 100.0])    # convert
ierr, rlods = psspy.conl(0, 1, 3, [0, 0], [0.0, 0.0, 0.0, 0.0])        # housekeeping
psspy.ordr(0)
psspy.fact()
psspy.tysl(0)
```

### Changing `PQBRAK`

`PQBRAK` is element 10 of the real array of the solution parameters. The default values (`getdefaultint`, `getdefaultreal`) leave every other parameter unchanged:

```python
_i = psspy.getdefaultint()
_f = psspy.getdefaultreal()
ierr = psspy.solution_parameters_4([_i] * 5, [_f] * 9 + [0.7] + [_f] * 9)    # PQBRAK = 0.7 pu
```

- `solution_parameters_4` exists from PSS/E 33 on, and the example uses it for that reason.
- From PSS/E 35 on, the same can be done with `solution_parameters_5`: `PQBRAK` is still element 10 of the real array, but the arrays hold 9 integers and 21 reals.

  ```python
  ierr = psspy.solution_parameters_5([_i] * 9, [_f] * 9 + [0.7] + [_f] * 11)
  ```

- Set `PQBRAK` before `strt`.
- A lower `PQBRAK` keeps the constant-power demand, and the table demand of LPB1BL, at its full value down to a lower voltage. It also makes convergence harder during deep voltage dips.

## DYR record

```text
1 'USRLOD' '1' 'LPB1BL' 12 1 3 2 0 8 0  1 1 'sample'  0.0 0.0 /
```

The fields after the model name are `IT=12` (load characteristic), `IT=1` (coordinated), 3 ICONs, 2 CONs, 0 STATEs and 8 VARs.

| Data | Description |
| --- | --- |
| ICON 1 | `1`: the table sets P; `0`: standard P |
| ICON 2 | `1`: the table sets Q; `0`: standard Q |
| ICON 3 | Table name without the `.lpb` extension |
| CON 1 | `Tfp`, P lag time constant [s] |
| CON 2 | `Tfq`, Q lag time constant [s] |

### VARs

Powers are in system per unit (multiply by `SBASE` for MW/Mvar).

| VAR | Content |
| --- | --- |
| L, L+1 | P and Q at initialization |
| L+2, L+3 | P and Q lag outputs at the previous instant |
| L+4, L+5 | P and Q lag outputs at the current instant (the demand requested) |
| L+6 | Previous instant [s] |
| L+7 | Current instant [s]; holds a large negative marker until the table takes over |

`L` is obtained with:

```python
ierr, first_var = psspy.lmodind(bus, load_id, "CHARAC", "VAR")
ierr, p_lag_pu = psspy.dsrval("VAR", first_var + 4)
```

The model name `LPB1BL` is fixed: the DYR record, `change_ldmod_con` calls and the DLL name all use it.

## Table file

The `.lpb` file must be in the PSS/E working directory. Each nonblank line holds three numbers separated by spaces, commas or both, with a decimal point:

```text
time_s  P_MW  Q_Mvar
```

```text
1.000, 1.00, 0.30
2.000, 1.00, 0.30
2.001, 2.00, 0.80
```

Times must be strictly increasing. The model converts MW and Mvar to per unit with `SBASE`.

## Sample case

```text
bus 1 (0.8 kV, load) --[5 MVA 50/0.8 kV transformer]-- bus 2 (50 kV) --[line]-- bus 3 (50 kV, slack)
```

- The load at bus 1 starts at 1.0 MW and 0.3 Mvar, the first row of `sample.lpb`.
- The slack at bus 3 is driven by `PLBVFU1` with the flat profile `Flat.plb`. `Vsteps.plb` is the profile of the `voltage_steps` validation scenario: it steps the slack voltage from 1.0 pu up to 1.05 and 1.10 pu, back to 1.0 pu, down to 0.95 and 0.90 pu and back to 1.0 pu. To replay it, set ICON 3 of `PLBVFU1` to `'Vsteps'` in the DYR or with `psspy.change_plmod_chricn(3, '1', 'PLBVFU1', 3, 'Vsteps')`.
- Base frequency 60 Hz, system base 100 MVA.

## Running the example

Use the Python interpreter that matches your PSS/E installation (Python 2.7 for PSS/E 33, Python 3 for later versions):

```powershell
python examples\run_lpb_load_example.py --psse-version 35
python examples\run_lpb_load_example.py --psse-version 35 --tfp 0.2 --tfq 0.5 --plot
```

The script:

1. Starts PSS/E, opens `lpb_load_bench.sav`, converts the case and loads the DLL and the DYR.
2. Sets `Tfp` and `Tfq` with `change_ldmod_con`.
3. Adds channels for the bus voltages, the requested load (`P LOAD`, `Q LOAD`), the power delivered through the transformer (`P DELIVERED`, `Q DELIVERED`) and the eight model VARs.
4. Runs to 10 s, pausing at 0.5, 1.5, 2.5 and 5.5 s to print the VARs read with `dsrval`.
5. Writes `output/example.out`, `output/example.csv` (powers in MW/Mvar), `output/example.log` and, with `--plot`, `output/example.png`.

If PSS/E is not installed in the default folder, pass `--pssbin` and `--psspy-dir`.

## Validation

`report/LPB1BL_validation_report.pdf` documents the validation of `LPB1BL` with PSS/E 35, using `sample_case/sample.lpb` as the demand table. It includes the summary table and all result charts with numbered captions. Five scenarios were simulated on the sample case:

| Scenario | Tfp [s] | Tfq [s] | Slack profile | Purpose |
| --- | --- | --- | --- | --- |
| `base` | 0 | 0 | `Flat.plb` | No lag |
| `filtered` | 0.2 | 0.5 | `Flat.plb` | Active lags with different constants |
| `bypass` | 0.0039 | 0.0039 | `Flat.plb` | Just below `4·DELT`: must match `base` |
| `threshold` | 0.005 | 0.005 | `Flat.plb` | Just above `4·DELT`: the lag acts |
| `voltage_steps` | 0 | 0 | `Vsteps.plb` | Slack voltage steps up and down: the demand must not change |

In every scenario, the requested demand follows the interpolated and lagged table within 0.005 MW/Mvar, the delivered power matches the requested power within 0.01 MW/Mvar, and the network converges at every step. In `voltage_steps` the load bus voltage follows the slack steps while the requested demand stays identical to `base`.
