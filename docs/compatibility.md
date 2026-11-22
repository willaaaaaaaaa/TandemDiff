# Compatibility and distribution

| | TandemDiff |
| --- | --- |
| Deployment target | macOS 14.0 or later |
| Local build | The build script defaults to a debug app for the build Mac. Pass `--universal --build-only` for a release build containing arm64 and x86_64. |
| Local runtime check | Apple M5 (arm64), macOS 27.0.1 (26A434), Xcode 27.2 |
| GitHub-hosted CI | The Swift test suite passed on Apple silicon (macOS 15) and Intel (macOS 26). The Apple silicon job also built the Universal app and checked its signature and both CPU architectures. [CI run](https://github.com/willaaaaaaaaa/TandemDiff/actions/runs/44920419448) |
| Open runtime checks | Interactive use on an Intel Mac and running TandemDiff on macOS 14. Reports from either environment are welcome. |
| Input storage | Local APFS. Copy inputs out of network shares and cloud-managed folders before comparing them. |

The minimum OS comes from the [package manifest](../Package.swift) and the app bundle. A Mac must run a compatible macOS version and have a CPU architecture included in the build. The project uses Apple frameworks and has no external Swift package dependencies.

## Verify a build

Run these commands from the checkout on a Mac with Xcode.

```sh
swift test
./script/build_and_run.sh --universal --build-only
app=dist/TandemDiff.app
bin="$app/Contents/MacOS/TandemDiff"
codesign --verify --strict --verbose=2 "$app"
lipo -archs "$bin"
xcrun vtool -arch arm64 -show-build "$bin"
xcrun vtool -arch x86_64 -show-build "$bin"
```

The expected architectures are `arm64` and `x86_64`, with `minos 14.0` on both slices. Launch the bundle to check runtime behavior on the test Mac. When reporting a compatibility issue, include the source revision, macOS version, CPU, and the steps that reproduce it with disposable files. See the [acceptance checks](acceptance.md).

## Prepare release notes

1. Review the entries under [Unreleased](../CHANGELOG.md#unreleased). Combine duplicates and keep one bullet per user-visible change. Use headings such as `Added`, `Changed`, and `Fixed` when they have entries.
2. Before tagging a release, check the app version (`CFBundleShortVersionString`) and build number (`CFBundleVersion`) in the [build script](../script/build_and_run.sh). Confirm the built app’s `Contents/Info.plist` contains those values.
3. Rename the completed section to `X.Y.Z (YYYY-MM-DD)` using the app version and the release date. Keep released versions in descending order and use the matching `vX.Y.Z` tag.
4. Keep a fresh `Unreleased` heading at the top for the next change, then push the matching `vX.Y.Z` tag. The Release workflow builds from the tag and uses that section as the GitHub Release description.

## Distributing a binary

The build script ad hoc signs the local app. Pushing a `vX.Y.Z` tag runs the Release workflow, which builds the Universal app from the tagged source on a GitHub-hosted Apple silicon runner (macOS 15), verifies the signature, both CPU architectures, and `minos 14.0`, and publishes a ZIP of the app with its SHA-256 checksum to the GitHub Release described by the changelog section for that version. Release downloads are ad hoc signed, so Gatekeeper shows an unidentified-developer warning. Right-click the app and choose **Open** the first time. Signing with Developer ID and notarizing needs a signing identity in repository secrets. Until one is configured, releases stay ad hoc signed. [Apple’s notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
