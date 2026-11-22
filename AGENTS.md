# TandemDiff development guide

TandemDiff compares two local folders or text files on macOS. Use the [supported inputs and product scope](docs/design.md#inputs-and-scope) when evaluating a feature request. For a new write operation, describe which paths it can change and how the user reviews the change.

## Where to make changes

- Put scanning, text comparison, and filesystem writes in [TandemDiffCore](Sources/TandemDiffCore). Cover these changes in [TandemDiffCoreTests](Tests/TandemDiffCoreTests).
- Put windows, comparison sessions, and user interactions in [TandemDiff](Sources/TandemDiff). Cover these changes in [TandemDiffAppTests](Tests/TandemDiffAppTests).
- Write new UI labels in English and Simplified Chinese using the existing [localization helpers](Sources/TandemDiff/AppSettings.swift). Use [DiagnosticText](Sources/TandemDiffCore/DiagnosticText.swift) for messages that the core returns to the app.

## File operations

Keep folder copies tied to the preview the user approved. Recheck the source and destination before writing. Excluded items stay protected from copying and editing even when the user reveals them.

Save the two text panes independently. A failed save must leave that pane’s edits available. Use disposable files for write tests. See the [comparison and write rules](docs/design.md) and [acceptance fixtures](docs/acceptance.md).

## Verify a change

- For comparison, write, or session changes, run `swift test`.
- For a file operation fix, reproduce it with disposable files and check the resulting bytes on both sides. For a blocked write, also check that the destination kept its original contents or stayed absent.
- For UI changes, run `./script/build_and_run.sh` and exercise the affected flow in the freshly built app. See the [visual style guide](docs/visual-style.md) for appearance and difference colors.
- For packaging changes, run `./script/build_and_run.sh --universal --build-only`. Follow the [compatibility checks](docs/compatibility.md) to verify the signature, both CPU architectures, and the minimum macOS version.

## Document a change

- When a change adds a feature, fixes behavior a user can observe, or changes platform support, add a short entry under [Unreleased](CHANGELOG.md#unreleased) in the same change. Describe what the user can now do or what went wrong before. Tests, refactors, and CI changes with no user-visible effect can skip an entry.
- If a change affects a documented workflow, update the [English](README.md) and [Chinese](README.zh-CN.md) READMEs together. Refresh a screenshot when it would otherwise show the old behavior.
- When comparison or write rules change, update the [design](docs/design.md) and the corresponding [acceptance case](docs/acceptance.md). When preparing a release, follow the [release notes procedure](docs/compatibility.md#prepare-release-notes).
