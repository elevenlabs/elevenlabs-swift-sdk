# Release

Create a new release of the ElevenLabs Swift SDK.

## Arguments

The user may provide a version number (e.g. `3.2.0`). If not provided, determine the next version by:
1. Running `git describe --tags --abbrev=0` to get the latest tag
2. Incrementing the patch version (e.g. `v3.1.2` -> `3.1.3`)
3. Confirming the version with the user before proceeding

## Version locations

The version string must be updated in exactly these 4 files:

| File | Pattern |
|------|---------|
| `Sources/ElevenLabs/Internal/Version.swift` | `static let version = "X.Y.Z"` |
| `Sources/ElevenLabs/Public/ElevenLabs/ElevenLabs.swift` | `public static let version = "X.Y.Z"` |
| `Tests/ElevenLabsTests/Unit/ElevenLabsSDKTests.swift` | `XCTAssertEqual(ElevenLabs.version, "X.Y.Z")` |
| `README.md` | `.package(url: "https://github.com/elevenlabs/elevenlabs-swift-sdk.git", from: "X.Y.Z")` |

## Steps

1. **Verify clean state**: Run `git status` on `main` branch. Abort if there are uncommitted changes or if not on `main`.

2. **Update versions**: Edit all 4 files listed above with the new version string.

3. **Lint**: Run `swiftformat . --strict` and fix any issues (commit lint fixes separately if needed).

4. **Test**: Run `swift build` and `swift test` to verify everything compiles and passes.

5. **Commit**: Stage the 4 version files and commit:
   ```
   chore: bump version to X.Y.Z
   ```

6. **Grep for old version**: Search the repo for any remaining references to the previous version string to make sure nothing was missed.

7. **Confirm with user**: Before pushing, show the user a summary of what will happen (push to main, create tag, create GitHub release) and ask for confirmation.

8. **Push and tag**:
   ```bash
   git push origin main
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

9. **Create GitHub release**:
   ```bash
   gh release create vX.Y.Z --generate-notes
   ```

10. **Report**: Share the release URL with the user.
