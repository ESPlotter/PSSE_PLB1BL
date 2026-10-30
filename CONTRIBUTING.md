# Contributing

Thank you for your interest in improving `LPB1BL`. Issues and pull requests are welcome.

## Before making a change

1. Search existing issues and pull requests to avoid duplicate work.
2. For a substantial change, open an issue first to agree on the intended behavior and compatibility impact.
3. Keep changes focused. Explain the problem they solve and any effect on PSS/E versions 33, 34, 35, and 36.

## Pull requests

Include:

- A clear summary of the change and its motivation.
- The PSS/E version or versions affected.
- The validation performed, including the PSS/E version and scenario where relevant.
- Updated examples or documentation when behavior or setup changes.

Do not include Siemens manuals, PSS/E installation files, credentials, customer network models, or other confidential data. If a failure depends on a private case, describe a minimal reproducible example instead of uploading the case.

The checked-in DLLs are release artifacts. Do not submit hand-edited binaries. A proposed model change should include the corresponding Fortran source changes and validation evidence; maintainers handle release binaries.

## Validation

Use the example and validation instructions in `README.md` with the Python interpreter supported by the selected PSS/E installation. State clearly when a change could not be tested in PSS/E.

## License and contributions

The project is distributed under the MIT License; see `LICENSE`. By submitting a contribution for inclusion, you confirm that you have the right to submit it and agree that accepted contributions may be distributed under the project's MIT License.
