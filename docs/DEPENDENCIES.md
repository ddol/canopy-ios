# Dependencies

Canopy uses Apple's frameworks first. Every third-party dependency, whether runtime code, a bundled asset
or a development tool, is listed here with a justification. A pull request that adds one must update this
file.

## Runtime code

**None.** The app and its packages link only Apple frameworks that ship with iOS:

| Framework | Used for |
|---|---|
| SwiftUI | App lifecycle and all UI |
| Observation | `@Observable` view models |
| MapKit | The map (behind `CanopyMap`'s renderer protocol) |
| ARKit | World tracking, LiDAR scene reconstruction, raycasts |
| RealityKit | AR view and mesh overlay |
| ModelIO | Debug-only USDZ preview of a captured mesh for Quick Look |
| QuickLook | Debug preview of captured meshes |
| GameKit | Game Center sign-in |
| CoreLocation | Device position |
| CryptoKit | SHA-256 for blob names |
| SQLite3 | The system `libsqlite3` for the local store |
| CoreText | Registering the bundled font |

## Bundled assets

| Asset | Licence | Why |
|---|---|---|
| [DM Sans](https://github.com/google/fonts/tree/main/ofl/dmsans) (`DMSans[opsz,wght].ttf`, variable) | SIL Open Font License 1.1 (`OFL.txt` is bundled next to the font) | The Canopy design system uses DM Sans for titles. Body text uses the system font and numbers use SF Mono, so this is the only font we bundle. |

## Development tools

These are used to build and check the project. None of them ends up in the app.

| Tool | Licence | Why |
|---|---|---|
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | MIT | Generates `Canopy.xcodeproj` from `project.yml`, so the project file is reviewable text and never hand-edited. Installed by `scripts/bootstrap.sh` (Homebrew). |
| swift-format | Apache-2.0 | Formatting and lint. Ships with the Xcode toolchain (`swift format`), so there is nothing to install. |

## Test data generation

| Tool | Licence | Why |
|---|---|---|
| [golang/geo](https://github.com/golang/geo) (`s2` package) | Apache-2.0 | Google's S2 implementation in Go. `scripts/s2-reference` (a small Go program) uses it to generate the reference S2 vectors in `CanopyModel`'s tests and the cells in `Fixtures/ggp/s2-cells.geojson`. Only needed to regenerate them; not part of the app or its build. |
