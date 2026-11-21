# Compatibility and distribution

| | TandemDiff |
| --- | --- |
| Deployment target | macOS 14.0 or later |
| Local build | The build script defaults to a debug app for the build Mac. Pass `--universal --build-only` for a release build containing arm64 and x86_64. |
| Native runtime check | Apple M5 (arm64), macOS 27.0.1 (26A434), Xcode 27.2 |
| Other environments | Native execution on an Intel Mac and execution on macOS 14 have yet to be verified. Reports from other Macs are welcome. |
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

## Distributing a binary

The build script ad hoc signs the local app. For a downloadable macOS release, build from the tagged source and sign with Developer ID. After notarization, staple the ticket to the app or disk image. If distributing a ZIP, create the final archive from the stapled app. Check a fresh download through Gatekeeper, publish its checksum, and identify the macOS version and CPU used for runtime checks in the release notes. [Apple’s notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
