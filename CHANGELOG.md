# Changelog

## Unreleased

### Added

- Command-click items on opposite sides of Folder Compare to compare two text files directly or set two folders as the comparison roots, even when their names differ.

### Changed

- `script/build_and_run.sh` now installs the app it builds to `/Applications/TandemDiff.app` and opens it from there, so the Mac keeps a single app copy instead of an extra one under `dist/`. `--build-only` still writes `dist/TandemDiff.app` for packaging.

### Fixed

- Open two text files selected with Command-click while Folder Compare scans the remaining items.

## 0.1.0 (2026-11-22)

### Added

- Save a folder comparison and reopen it from Home with its paths, filters, and selected row restored.
- Compare two local APFS folders side by side. Filter files and folders separately, then preview which files a copy will create, replace, or skip.
- Compare two text files or pasted snippets side by side. Apply individual changes in either direction, undo edits, and save each file independently.
- Download a Universal macOS build from GitHub Releases.
