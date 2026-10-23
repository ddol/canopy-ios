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
| `CanopySync` | iOS, macOS | `GerardusClient` protocol, `FakeGerardusClient`, `SyncCoordinator`; `GerardusEndpoint` and `GerardusStatusClient` for a real server's status page |
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
  server: upload blobs, submit changesets, read their state, pull applied changes per L16 tile. The fake
  applies the real policy (two players agree, at least one trusted) so the rest of the app can be built and
  tested against it. The fake lives in memory: after a relaunch it has forgotten earlier submissions, and the
  next sync submits open changesets again.

## Capture

`CaptureSession` runs `ARWorldTrackingConfiguration` with scene reconstruction (with classification where
supported) and `gravityAndHeading` alignment, so world +x is east and −z is north. The mesh overlay is
RealityKit's scene-understanding debug view. Camera frames stay inside ARKit; the app never reads
`capturedImage`.

**Scan trunk** raycasts through the screen centre against the mesh (within 6 m) to find a point on the trunk,
then keeps the scene around it while the player walks round. ARKit keeps refining its reconstruction: the side
scanned first is re-meshed from further away and loses detail, and mesh anchors are merged or dropped. So, as
mesh anchors update, a `MeshAccumulator` splits their triangles inside a vertical cylinder (radius 2 m, from 3 m
below to 4 m above the start point) into 10 cm cells, in each anchor's own coordinates, and keeps for every cell
the version with the most triangles it has seen: a coarser re-mesh never replaces finer detail, and cells missing
from a later update are kept. Kept cells follow their anchor's latest transform, so ARKit's drift corrections move
them too. Where anchors overlap, each cell of space comes from the anchor with the most triangles there, so
surfaces are not doubled.

About once a second the kept mesh is drawn in translucent lime over the camera view, and a quick fit reports how
much of the trunk's circumference 1.37 m above the ground is covered (aim for 270° or more). **Finish scan** runs
`TrunkAnalysis` on the kept mesh off the main actor:

1. **Ground**: the median height of floor-classified faces under the trunk, else the lower quartile of
   near-horizontal triangles within 1.5 m. On a slope this lands between the uphill and downhill sides rather
   than on the uphill side the DBH convention asks for; a Milestone 1 refinement.
2. **DBH**: the mesh is sliced at five heights around 1.37 m (±4 cm); the edge intersections are pooled and fitted
   with a circle (algebraic start, Levenberg–Marquardt on orthogonal distances, outliers dropped). DBH is twice
   the radius; its uncertainty combines the fit's (from the covariance) with a 5 mm systematic term for LiDAR
   noise and mesh smoothing. Fits covering less than 75° of the trunk, or giving a diameter outside 0.03 to 4 m,
   are refused.
3. **Lean**: circles at 0.6 to 2.4 m give stem centres; a straight line through them gives the angle from
   vertical and, with north alignment, its direction.

The evidence is the kept mesh (positions and indices only) re-cropped around the fitted trunk centre: the trunk
plus 0.6 m around it, at most 2 m. A trunk's position on the map comes from the GPS fix plus the AR offset from
the camera to the trunk (`GeoReference`), with the GPS accuracy as its uncertainty.

The AR session pauses while the measurement sheet is up (Quick Look's AR preview needs the camera) and resumes
without resetting, so the mesh and the scan carry on; **Keep scanning** goes back to walking round and measuring
again, and saving ends the scan.

**Tag** places a limb point by raycasting against the mesh within 5 m; the height above ground uses the same
ground estimate. Without LiDAR, the player enters the height and the point sits at the tree.

## Map

`MapLayers` is a plain description of what to draw, built from `CensusState`. Renderers implement
`MapRenderer`; `MapKitRenderer` uses MapKit for SwiftUI. A MapLibre Native renderer with offline PMTiles (a
Milestone 1 issue) can implement the same protocol without changing the screens.

## Server settings

`ServerSettings` (in the app) keeps the Gerardus server's address in user defaults under `canopy.gerardusURL`,
as scheme, host and port, and runs the connection test: `GerardusStatusClient` sends `GET /` over URLSession and
decodes the status JSON (`status`, `service`, `server_version`, `git_sha`, `api_version`, `serve_scans`,
`started_at`, `uptime_s`, `available_layers`). Only `status` is required, so a newer server with more or
different fields still passes. **Me → Settings** shows the answer; sync still uses the fake.

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
Xcode project is generated by XcodeGen from `project.yml`; `App/Info.plist` holds only App Transport Security
(plain HTTP to local names, IP addresses and `*.ts.net`) and is merged with the keys Xcode generates.
