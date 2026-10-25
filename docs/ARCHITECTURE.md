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

`CanopyReference` sits beside `CanopySync`: it talks to the Gerardus *align* service (reference data and scan
registration), where `CanopySync` is the boundary for the census changesets.

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
| `CanopyReference` | iOS, macOS | A Gerardus server over gRPC (HTTP/1.1, hand-written protobuf): `AlignClient` (reference data, registration) and `GerardusMapClient` (the shared census, CanopySync's `GerardusClient`); `SiteGeoreference`, `TreeDetector`, `AerialTrees`, `ScanRegistration` / `RegisteredScan` |

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
 Me → Sync ──► SyncCoordinator ──► GerardusClient ──► LocalStore.updateChangeset ──► derive
                                      (GerardusMapClient, or the fake when no server is set)
```

- **Observations are the source of truth.** The store never edits one; the current trees and tags are derived
  from the aerial base layer plus the log, folded once over agreed changesets and once over this device's open
  ones (see [DATA-MODEL.md](DATA-MODEL.md)). Rejected changesets drop their observations from the fold.
- **Evidence is immutable and content-addressed.** A trunk or limb scan is cropped, written as GLB, stored
  under its SHA-256 and referenced by hash from observations and changesets.
- **Sync goes through one boundary.** `GerardusClient` is the whole contract with a Gerardus server: upload
  blobs, submit changesets, read their state, and pull applied changes per L16 tile. With a server set in Settings,
  `GerardusMapClient` speaks the server's map service (see *Shared census*). Without one, `FakeGerardusClient`
  applies the same policy in memory (two players agree, at least one trusted), so the app works offline and in
  tests. The fake forgets everything on relaunch, and the next sync submits open changesets again. With a real
  server, sync also pulls the shared map and the review queue (see *Shared census*).

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

## Aerial data and registration (Gerardus align)

A Gerardus align server (`gerardus.align.v1alpha1`, the one set in Me → Settings) prepares a **site** for
an L16 tile: the tile and its 8 neighbours, with USGS 3DEP aerial LiDAR points, OpenStreetMap features, building
footprints and a 1 m ground model, all in a site frame that is east-north-up metres from the tile centre on
NAD83(2011), with NAVD88 heights. `CanopyReference` is the client.

**Transport.** The server speaks gRPC over HTTP/2 and also accepts HTTP/1.1. URLSession cannot do cleartext
HTTP/2, so the client sends gRPC over HTTP/1.1 (`URLSessionGRPCTransport`) and decodes the messages itself
(`Protobuf.swift`, `AlignMessages.swift`); there is no gRPC or protobuf library. HTTP/1.1 trailers are invisible to
URLSession, so a status the server sends after messages is lost; failures before any message arrive as headers and
are reported. The message definitions come from the server by gRPC reflection. Every call has a time limit
(`AlignClient.Timeouts`: 10 s for single answers, 30 s to prepare a site, 45 s to stream reference layers, 180 s for
registration) and a call that receives nothing for 30 s fails, so a slow server or link shows an error instead of
a spinner. The server keeps preparing a site after the call that asked for it gives up, so the app says the area is
still being prepared and the next try finds it ready.

**Site frame to the map.** `SiteGeoreference` asks the server (`PoseFromHint`) where a handful of WGS 84 points
around the site land in the site frame and fits an affine map. Across a site this is exact to well under a
millimetre (the fit's RMS is reported), and it carries the datum shift (about 1.6 m in San Francisco) without any
projection or datum code in Canopy.

**Real trees.** `AerialTrees.load` prepares the site if needed and streams the canopy classes (unclassified and
vegetation; 3DEP's San Francisco tiles leave trees unclassified), the DataSF building footprints and the ground
model. OpenStreetMap is not loaded: the shared tree layer takes nothing from it (Gerardus ADR-0005, ADR-0008), so
detection must not depend on it. An admin can opt in for checking (see *Admin flags*). Given an
`Area` it streams only a circle (`StreamReferenceRequest`'s centre and radius, in the site frame) plus a 20 m margin
so edge crowns are whole; the app asks for the map's visible region, at most 150 m from its centre, which is about
4 MB at 1 m voxels instead of 15 MB for the whole site. Then it runs `TreeDetector`:

1. a 0.5 m canopy height model: the highest return above the ground model in each cell, single-cell pits filled,
   smoothed with a 3 × 3 binomial kernel;
2. tree tops: cells at least 5 m high that are the highest within a radius of 1 m + 0.08 × height (1.5 to 4.5 m);
3. crowns: every cell at least 2 m high climbs to its highest neighbour until it reaches a top (a suppressed local
   maximum goes to the nearest kept top);
4. buildings (DataSF footprints) are masked out, and tops within 8 m of the data's edge are dropped.

Each tree becomes a `TreeCandidate` with its height, crown radius, a confidence from crown size, height and point
density, the source for attribution, and an id derived from its position, so loading the area again finds the same
trees. A result answers for the part of its area inside the site's own 9 tiles (`SiteResult.covers`):
`LocalStore.replaceCandidates(where:with:)` swaps the candidates there for the new ones, keeping any a player has
already acted on (and dropping a new one within 2.5 m of such a kept one).
On a site with 26 million points this takes under 2 s including download; the dense groves are somewhat over-split,
which players correct with Not a tree. The Map tab's Layers menu has **Load real trees in view**, and the map shows
the data's credits while real trees are loaded. Reducing the data further is on the [backlog](BACKLOG.md).

If a server has no ground layer, the ground model is built from the ground and water returns instead (lowest return
per cell, gaps filled from their neighbours).

**Registration.** On a LiDAR device, Census → **Register with 3DEP** (after the player agrees to the upload) takes
the session's reconstructed mesh within 60 m of where the session started, thins it to one point per 10 cm cube, and
uploads it as a scan in a z-up sensor frame (ARKit (x, y, z) → (x, −z, y), so +y points north and a north-aligned
session has heading 0). The pose hint is the session origin's GPS position and its height above the ground. The
server levels the scan, searches around the hint for where it meets 3DEP's elevated structure, refines with ICP and
gates the result. When every gate passes, `RegisteredScan` places ARKit points on the map through the pose and the
site georeference, and the Census screen uses it instead of GPS for the rest of the session: new trees and trunk
measurements land with the registration's uncertainty instead of the GPS fix's. A synthetic scan cut from 3DEP with
a known pose registers back to within 9 mm.

**Tests.** Offline tests cover the codec, framing, the client over a mock transport, the georeference fit, detection
on a synthetic forest and the scan conventions. `CANOPY_GERARDUS_URL=http://… swift test` in
`Packages/CanopyReference` also runs the live tests against a server, and `TEST_RUNNER_CANOPY_GERARDUS_URL=…` runs
the app's live UI test.

## Shared census (Gerardus map service)

The Gerardus server's map service (`gerardus.map.v1alpha1`, same port as align) keeps the shared tree census as a
changeset log in its trees layer, which is CC0 and takes nothing from OpenStreetMap. `GerardusMapClient` implements
`GerardusClient` on it, plus a few extra calls:

- `UploadBlob`, `SubmitChangeset`, `GetChangesets` and `PullChanges`, following every page.
- `ReviewChangeset`: another player agrees, or a trusted player rejects.
- `GetTile`: the tile's entities and the sequence to pull from next.
- `GetPlayer`: roles, and whether OpenStreetMap may be sent.
- `ImportDetectedTrees`.
- `GetBlob`: an evidence mesh another device uploaded.

Every call is unary, and failures arrive before any message, so HTTP/1.1 loses nothing. Op fields travel as
CanopyModel's own JSON (`CanopyJSON`).

**Identity.** Every call to a Gerardus server carries `x-gerardus-player-id` (the Game Center team-scoped id, or
`local:<uuid>` before sign-in) and `x-gerardus-player-alias` (`GerardusIdentity`). The server keys accounts and roles
on the id, which it does not verify yet. A changeset's author must be the caller.

**Detected trees.** After **Load real trees in view**, the app saves the area's candidates with
`ImportDetectedTrees`. The server applies them at once as detected trees, skipping ids it already has and L22 cells
that are already occupied. This has to happen before anyone confirms them, because a change to a tree the server
has never seen comes back conflicted. Candidates found with OpenStreetMap stay on the phone, and the server refuses
them anyway.

**Pulling the shared map.** After pushing, sync brings this device's copy of the shared map up to date
(`AppModel.pullSharedMap`). It follows every tile pulled before, plus the tiles in view when the map shows at most
400 m from centre to corner. A tile it has never pulled gets a snapshot (`GetTile`); the rest get the ops applied since
their cursor (`PullChanges`). If the server's log goes backwards (its database was replaced), or an update names a
tree the device has never seen, the tile gets a fresh snapshot.

Everything lands in one store transaction (`LocalStore.applyShared`), in the `shared` and `shared_tiles` tables.
Derivation then starts from the shared map, so the server's trees and tags win over the aerial candidates and other
players' trees appear. This device's applied observations are folded only for entities the server has not sent yet,
so nothing is counted twice, and its open proposals still show on top as `proposedStatus`.

**Syncing on its own.** With a server set, the app syncs without being asked (`AppModel.syncSoon`): a couple of
seconds after each change, three seconds after the map settles on tiles not pulled yet (within the 400 m limit), right
after a load of real trees, and when the app comes to the front. Requests in a row become one sync, one sync runs at a
time, and a request during a sync runs once more after it. **Sync now** still works. Under tests nothing syncs on its
own.

**Evidence from other devices.** A tree's evidence refs name the meshes behind its measurements. The tree sheet's
**Evidence** section previews each one: a mesh on this device opens straight away; one recorded on another device is
downloaded first (`GetBlob`, `AppModel.evidenceFile`), checked against its hash and kept in the blob store, then
opened the same way, as a throwaway USDZ in Quick Look. Blobs are uploaded with the changeset that references them.

**Reviewing.** The review queue (Me → **Review**) lists other players' open changesets in the followed tiles
(`ListOpenChangesets`), leaving out the player's own changes and ones they have already agreed with. **Agree**
records an approval (`ReviewChangeset`). A trusted player (`GetPlayer`) can also **Reject**, with a reason. The server
applies a change once two players agree and one of them is trusted, and the next sync brings it back.

**OpenStreetMap.** The server sends OSM only to its admins (its own `--admin` list). Anyone else who names the layer
is refused the whole stream, so `AerialTrees` asks for OSM in a separate call after the main stream. A refusal is
reported to the player and detection carries on without it.

## Map

`MapLayers` is a plain description of what to draw, built from `CensusState`: trees filtered by the statuses the
player shows (`Visibility.statuses`, the chips under the summary bar), tags, routes, tiles, the boundary, and
`Reference`, the last loaded area's own data. Renderers implement `MapRenderer`:

- `MapKitRenderer` draws on Apple's map with MapKit for SwiftUI. Each tree is a view, so detected trees are capped
  (250 to 400, nearest the centre first).
- `GerardusRenderer` (Layers → **Gerardus only**) draws with no base map. It is a SwiftUI `Canvas` on a flat
  projection showing only Canopy's own data: the canopy height grid from the aerial point cloud (1 m, light to dark
  green with height), DataSF building outlines, OpenStreetMap roads and paths when an admin loaded them, then the
  boundary, tiles, routes, every tree and the tags. Drag to pan, pinch to zoom, tap to select. The grid and outlines
  are kept in memory after **Load real trees in view**.

A MapLibre Native renderer with offline PMTiles (a Milestone 1 issue) can implement the same protocol without
changing the screens.

## Admin flags

`AdminSettings` holds flags for checking the data. **Me → Settings → Admin** shows them to Game Center players whose
team-scoped id is in the `CANOPY_ADMIN_PLAYER_IDS` build setting. It is set in `Configs/Local.xcconfig`, so the list
stays out of the repository, and reaches the app as Info.plist `CanopyAdminPlayerIDs`. Debug builds show the flags to
everyone, and every flag is off until turned on. The one flag today is **Use OpenStreetMap**: tree detection also
masks OSM buildings, the Gerardus map gets roads and paths, and the trees found are marked as for checking only. The
section also shows the player's id, to copy into the allowlist.

## Server settings

`ServerSettings` (in the app) keeps the Gerardus server's address in user defaults under `canopy.gerardusURL`,
as scheme, host and port, and runs the connection test: `GerardusStatusClient` sends `GET /` over URLSession and
decodes the status JSON (`status`, `service`, `server_version`, `git_sha`, `api_version`, `serve_scans`,
`started_at`, `uptime_s`, `available_layers`). Only `status` is required, so a newer server with more or
different fields still passes. **Me → Settings** shows the answer. With an address set, sync and the aerial trees
use that server; without one, sync uses the fake.

The setting is the only source of the server's address: `AppModel.gerardusURL` and `alignClient`, used by Load
real trees here and Register with 3DEP, read `serverSettings.endpoint` and are nil until a server is set, when
those actions say to set one. UI tests can pass a server as the launch argument `-canopy.gerardusURL <url>`.

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
