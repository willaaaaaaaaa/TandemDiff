# TandemDiff development guide

## Where to make changes

- Put scanning, text comparison, and filesystem writes in [TandemDiffCore](Sources/TandemDiffCore). Cover these changes in [TandemDiffCoreTests](Tests/TandemDiffCoreTests).
- Put windows, comparison sessions, and user interactions in [TandemDiff](Sources/TandemDiff). Cover these changes in [TandemDiffAppTests](Tests/TandemDiffAppTests).

## File operations

Keep folder copies tied to the preview the user approved. Recheck the source and destination before writing. Excluded items stay protected from copying and editing even when the user reveals them.

Save the two text panes independently. A failed save must leave that pane’s edits available. Use disposable files for write tests. See the [comparison and write rules](docs/design.md) and [acceptance fixtures](docs/acceptance.md).

## Verify a change

- For comparison, write, or session changes, run `swift test`.
- For UI changes, run `./script/build_and_run.sh` and exercise the affected flow in the freshly built app. See the [visual style guide](docs/visual-style.md) for appearance and difference colors.
- For packaging changes, run `./script/build_and_run.sh --universal --build-only`. Follow the [compatibility checks](docs/compatibility.md) to verify the signature, both CPU architectures, and the minimum macOS version.
