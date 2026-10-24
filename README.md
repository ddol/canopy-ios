# Canopy

🌲 Canopy is a shared, living census of every tree in Golden Gate Park, San Francisco.

Players walk the park with an iPhone or iPad. They confirm trees that aerial LiDAR detected, measure
trunks (diameter 1.37 m above the ground, and lean), tag limb hazards in 3D, and label routes. A change
reaches the shared map only when two players agree and at least one of them is trusted.

Canopy is the second app built on **Gerardus**, an open map spec: S2 L16 tiles and L19 chunks,
immutable evidence, and changesets. The Gerardus Rust core and server do not exist yet; this app talks to
them through Swift protocols with in‑memory fakes so the real implementations can be swapped in later.

> **Status:** Milestone 0. Everything works locally against a simulated Gerardus server; nothing is uploaded
> anywhere yet. The tree candidates in this build are synthetic sample data.

## What works in Milestone 0

| Tab | |
|---|---|
| **Map** | The park with 200 synthetic aerial candidates: faint dot = detected, dashed ring = proposed, ring = confirmed, solid = verified. Summary bar (Confirmed · Estimated · Coverage), layer toggles (including S2 L16 tiles), and a tree sheet with Confirm / Not a tree / Tag. |
| **Real trees** | Map → Layers → **Load real trees in view** loads the trees found in USGS 3DEP aerial LiDAR for the part of the map in view (up to 150 m from its centre), from the Gerardus align server set in **Me → Settings**, replacing the synthetic sample there. |
| **Census** | With LiDAR: an AR view with the reconstructed mesh, Confirm tree, Not a tree, New tree here, **Register with 3DEP** (match the session's mesh to aerial LiDAR so positions are good to centimetres instead of GPS metres), and **Scan trunk**: walk round the trunk while the app keeps the most detailed mesh it sees, then get the diameter 1.37 m above the ground with ±, the lean, and the trunk's mesh saved as GLB evidence. Without LiDAR: a verification list of nearby trees. |
| **Tag** | Pick a tree, place the limb point (on the LiDAR mesh within ~5 m, or by height), choose issue, what it could hit, size and urgency. Saved as a proposed tag. |
| **Me** | Game Center sign-in (falls back to a local id), pending changes, sync with the simulated server, and debug tools: simulate a trusted approval, reset local data. **Settings** sets the Gerardus server's address and tests the connection: version, commit, uptime and reference layers. |

Debug builds can share a measurement's GLB and preview it in Quick Look (as a temporary USDZ, since GLB is not
a Quick Look format on iOS).

## Privacy first

- Canopy **never stores or uploads photos**. Evidence is a colourless 3D mesh (geometry only), cropped to
  the tree or limb being recorded.
- The only identity in the data is your Game Center player id and alias.
- See [PRIVACY.md](PRIVACY.md) for exactly what is stored and synced.

## Requirements

| | |
|---|---|
| Devices | iPhone and iPad (universal) |
| Minimum iOS | **18.0** (the test suite runs on iOS 18.2 and 26.3 simulators) |
| LiDAR features | iPhone Pro / iPad Pro with LiDAR; other devices get the map, tagging and verification |
| Xcode | 26.3 or later (Swift 6, strict concurrency) |
| Tools | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (installed by `scripts/bootstrap.sh`) |

**Why iOS 18.0:** it is the oldest iOS that supports everything Canopy uses. SwiftUI's `Tab` API and the
adaptable iPad sidebar need iOS 18; MapKit for SwiftUI and the Observation framework need iOS 17; ARKit
scene reconstruction needs iOS 13.4. Anything newer than iOS 18 is used only behind `if #available`.

## Getting started

```sh
scripts/bootstrap.sh          # installs XcodeGen if missing, generates Canopy.xcodeproj
open Canopy.xcodeproj
```

Run every test (app, UI and all packages) on the newest available iPhone simulator:

```sh
scripts/test.sh
```

which is `xcodebuild test -project Canopy.xcodeproj -scheme Canopy -destination 'id=<simulator>'`. The
packages that do not need UIKit (`CanopyModel`, `CanopyStore`, `CanopySync`, `CanopyCapture`'s geometry) also
build on macOS, so `swift test` inside one of them is the quickest loop.

To run on an iPhone or iPad, or ship a TestFlight build, see [docs/DEVICE-TESTING.md](docs/DEVICE-TESTING.md):
set your `DEVELOPMENT_TEAM` in `Configs/Local.xcconfig` (git-ignored), then `scripts/device.sh` or
`scripts/testflight.sh`. LiDAR features need an iPhone 12 Pro or later Pro model, or an iPad Pro with LiDAR.
Game Center sign-in only succeeds once the app is set up in App Store Connect; until then the app says Game
Center is unavailable and uses a local player id.

The `.xcodeproj` is generated from [`project.yml`](project.yml) and is not committed. Change the
project by editing `project.yml` and re-running `scripts/bootstrap.sh`.

## Repository layout

```
project.yml          XcodeGen spec: app target Canopy, unit and UI test targets
App/                 SwiftUI app: CanopyApp, tab shell (Map · Census · Tag · Me), screens
Packages/
  CanopyDesign/      design tokens and base components
  CanopyModel/       value types and S2 cell ids
  CanopyStore/       SQLite: append-only observation log, current state, sha256 blob store
  CanopyCapture/     ARKit + LiDAR capture, GLB writer, trunk DBH and lean
  CanopyMap/         map behind a protocol (MapKit now), layers
  CanopySync/        GerardusClient protocol and an in-memory fake
  CanopyPlayers/     Game Center sign-in wrapper
  CanopyReference/   Gerardus align client: 3DEP aerial trees, scan registration
Tests/               app unit tests (Swift Testing) and UI tests (XCTest)
Configs/             xcconfig files; Local.xcconfig (git-ignored) holds your signing team
Fixtures/ggp/        sample park boundary, synthetic aerial tree candidates, S2 cells
docs/                architecture, data model, design tokens, dependencies
scripts/             bootstrap, test, device install, TestFlight upload, fixture and icon generation
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Data model](docs/DATA-MODEL.md)
- [Design tokens](docs/DESIGN-TOKENS.md)
- [Dependencies](docs/DEPENDENCIES.md)
- [Testing on a device and TestFlight](docs/DEVICE-TESTING.md)
- [Backlog](docs/BACKLOG.md)

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately as described in
[SECURITY.md](SECURITY.md).

## Licence

Apache License 2.0, see [LICENSE](LICENSE). The bundled DM Sans font is licensed under the SIL Open Font
License 1.1 (see [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)).
