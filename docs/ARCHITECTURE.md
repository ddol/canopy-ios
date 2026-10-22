# Architecture

Canopy is a SwiftUI app on top of seven local Swift packages. The packages hold the logic and can be tested
without a device; the app target wires them together and draws the screens.

## Layers

```
                         ┌──────────────────────────────────────────┐
App (SwiftUI)            │ CanopyApp · AppModel · Map · Census ·     │
                         │ Tag · Me                                  │
                         └──────────────────────────────────────────┘
                              │          │          │          │
         ┌────────────────────┼──────────┼──────────┼──────────┼───────────────┐
         ▼                    ▼          ▼          ▼          ▼               ▼
   CanopyMap           CanopyCapture  CanopyStore  CanopySync  CanopyPlayers  CanopyDesign
   (MapKit renderer)   (ARKit, GLB,   (SQLite,     (Gerardus   (Game Center)  (tokens,
         │              DBH)           blobs)       client)                     components)
         │                    │          │          │          │
         └────────────────────┴──────────┴──────────┴──────────┘
                                         ▼
                                   CanopyModel
                          (value types, S2 cell ids,
                           derivation, changesets)
```

`CanopyModel` and `CanopyDesign` depend on nothing. Every other package depends on `CanopyModel`;
`CanopyMap` also uses `CanopyDesign`. Packages never depend on the app, or on each other sideways: the app is
where the store, capture, sync and players meet.

| Package | Platforms | What it owns |
|---|---|---|
| `CanopyModel` | iOS, macOS | Value types (`Tree`, `Tag`, `Route`, `FieldObservation`, `Changeset`, `Evidence`, `Player`, `CountStatus`), `S2CellID`, positions and local frames, `CensusState` derivation, `ChangesetBuilder`, `CensusSummary`, GeoJSON reading |
| `CanopyDesign` | iOS | Colour, type, spacing and radius tokens; `StatusBadge`, `SummaryBar`, button styles; `QuantityFormat` |
| `CanopyStore` | iOS, macOS | `LocalStore` (SQLite: append-only log, changesets, evidence, derived tables) and `BlobStore` (SHA-256 named files) |
| `CanopyCapture` | iOS (AR), macOS (geometry) | `CaptureSession` (ARKit + LiDAR), `Mesh`, `GLB`, `CircleFit`, `TrunkAnalysis`, `GeoReference`, Quick Look previews |
| `CanopyMap` | iOS | `MapLayers`, the `MapRenderer` protocol, `MapKitRenderer`, status presentation (word, icon, tone) |
| `CanopySync` | iOS, macOS | `GerardusClient` protocol, `FakeGerardusClient`, `SyncCoordinator` |
| `CanopyPlayers` | iOS | `PlayerService` (Game Center sign-in, alias, trusted flag) |

The packages that build on macOS can be tested with `swift test` in a second or two; the full scheme runs
everything on the simulator.

## Data flow

```
 player action ──► AppModel.record(kind) ──► LocalStore.record
                                               │  one transaction:
                                               │   1. append FieldObservation
                                               │   2. insert Changeset (ChangesetBuilder)
                                               │   3. CensusState.derive → rewrite trees/tags
                                               ▼
                                         AppModel.refresh ──► screens
 Me → Sync ──► SyncCoordinator ──► GerardusClient (fake)  ──► LocalStore.updateChangeset ──► derive
```

- **Observations are the source of truth.** The store never edits one; the current trees and tags are derived
  from the aerial base layer plus the log, folded once over agreed changesets and once over this device's open
  ones (see [DATA-MODEL.md](DATA-MODEL.md)). Rejected changesets drop their observations from the fold.
- **Evidence is immutable and content-addressed.** A trunk or limb scan is cropped, written as GLB, stored
  under its SHA-256 and referenced by hash from observations and changesets.
- **Sync is a boundary, not a feature yet.** `GerardusClient` is the whole contract with the future Rust
  server: upload blobs, submit changesets, read their state, pull applied changes per level-16 tile. The fake
  applies the real policy (two players agree, at least one trusted) so the rest of the app can be built and
  tested against it. The fake lives in memory: after a relaunch it has forgotten earlier submissions, and the
  next sync submits open changesets again.

## Capture

`CaptureSession` runs `ARWorldTrackingConfiguration` with scene reconstruction (with classification where
supported) and `gravityAndHeading` alignment, so world +x is east and −z is north. The mesh overlay is
RealityKit's scene-understanding debug view. Camera frames stay inside ARKit; the app never reads
`capturedImage`.

**Measure trunk** raycasts through the screen centre against the mesh (within 6 m), snapshots the mesh anchors
near the hit, crops a vertical cylinder (radius 1.5 m) centred on the hit, and runs `TrunkAnalysis` off the main
actor:

1. **Ground**: the median height of floor-classified faces under the trunk, else the lower quartile of
   near-horizontal triangles within 1 m. On a slope this lands between the uphill and downhill sides rather
   than on the uphill side the DBH convention asks for; a Milestone 1 refinement.
2. **DBH**: the mesh is sliced at five heights around 1.37 m (±4 cm); the edge intersections are pooled and fitted
   with a circle (algebraic start, Levenberg–Marquardt on orthogonal distances, outliers dropped). DBH is twice
   the radius; its uncertainty combines the fit's (from the covariance) with a 5 mm systematic term for LiDAR
   noise and mesh smoothing. Fits covering less than 75° of the trunk, or giving a diameter outside 0.03 to 4 m,
   are refused.
3. **Lean**: circles at 0.6 to 2.4 m give stem centres; a straight line through them gives the angle from
   vertical and, with north alignment, its direction.

The cropped mesh (positions and indices only) is the evidence. A trunk's position on the map comes from the
GPS fix plus the AR offset from the camera to the trunk (`GeoReference`), with the GPS accuracy as its
uncertainty.

**Tag** places a limb point by raycasting against the mesh within 5 m; the height above ground uses the same
ground estimate. Without LiDAR, the player enters the height and the point sits at the tree.

## Map

`MapLayers` is a plain description of what to draw, built from `CensusState`. Renderers implement
`MapRenderer`; `MapKitRenderer` uses MapKit for SwiftUI. A MapLibre Native renderer with offline PMTiles (a
Milestone 1 issue) can implement the same protocol without changing the screens.

## Players

`PlayerService` wraps `GKLocalPlayer`. The player id is Game Center's `teamPlayerID` (stable across games from
the same developer team, so trust can carry between Gerardus apps); until sign-in succeeds the app uses a
pseudonymous `local:<uuid>` id kept in user defaults. When Game Center is unavailable (no account, simulator, an
app that is not yet registered in App Store Connect) the app keeps working with the local id. The trusted flag
will come from the server; it is false for now.

## Concurrency

Swift 6 language mode with complete strict concurrency throughout. The app target uses main-actor default
isolation. `LocalStore` and `FakeGerardusClient` are actors; model types are `Sendable` values; mesh analysis
runs in a detached task on `Sendable` copies of the mesh.

## Platform and dependencies

iOS 18.0 or later, iPhone and iPad. No third-party runtime code; see [DEPENDENCIES.md](DEPENDENCIES.md). The
Xcode project is generated by XcodeGen from `project.yml`.
