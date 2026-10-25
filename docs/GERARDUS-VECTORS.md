# Viewing Gerardus buildings in 3D

Set the server in **Me → Settings**, then **Map → Layers → Kirkham & 9th in 3D**. The action reads the prepared
Kirkham–9th site, `8085875ef`, without having to navigate Apple's map or run tree detection first.
**3D vectors in view** reads the prepared site at the current map centre. A missing prepared site is reported;
the viewer does not silently substitute sample buildings.

Drag to orbit, pinch to zoom, and drag with two fingers to pan. **3D layers** toggles buildings, measured facades,
streets/kerbs and ground. **Reset view** restores the initial camera. **Reload vectors** downloads the current
model. **Sources and model** shows attribution, bundle identity and the model identity returned by the server.
The phone needs access to the configured server (including Tailscale when that is how it is reached).

## Available building layers

The implementation follows Gerardus's `gerardus.align.v1alpha1` contract, including the W4–W7 enum additions
in Gerardus commit `596fc63`. `GetServerInfo.available_layers` determines which layers are requested.

| Layer | What the viewer draws |
| --- | --- |
| `FOOTPRINTS` (3) | DataSF outlines, with their supplied extrusion heights as a fallback when there are no box walls/building parts. |
| `GROUND_MESH` (7) | The site's actual ground elevation grid, displayed at roughly 4 m spacing; missing heights remain holes. |
| `BOXES` (8) | Explicit vertical wall rectangles, with the server's shifted positions and measured/fallback heights. Their `height_m` metadata is **not** applied again to the already elevated vertices. |
| `OBSERVED` (6) | Measured `WALL_PLANE` polygons, including bays/recesses, facade traces and poles from the registered site model. Sensor/correction arrows are omitted. These are derived proposals, not player-confirmed census objects. |
| `CITY_STREETS`, `KERBS`, `STREET_USE` (9, 11, 12) | Public street lines, kerbs/islands and operator-marked surfaces. |
| `BUILDINGS` (13) | Explicit roof planes and building parts, **if advertised and populated**. The current Gerardus W4 plan still describes LoD2 reconstruction as future work; enum definitions alone do not provide roofs. |
| `LANE_MARKINGS`, `STREET_FURNITURE`, `TREES` (14–16) | Forward-compatible vector lines/polygons when the server advertises and supplies them. |

The summary reports the actual box-wall, measured-plane and roof-plane counts. No roof geometry is invented.
Height provenance for boxes is the server's choice: 3DEP p95, the DataSF 2010 height, or its default when neither
is available. A box wall is not proof of a measured roof or a confirmed facade.

No OSM layers, registered scan point clouds or aerial point clouds are requested. The site's source list is
filtered to the displayed layers and their 3DEP/DataSF inputs; contributed scans are credited for observed geometry.
Vector viewing is independent of the tree census and does not write server data.

## Coordinates and consistency

The scene uses the server's site ENU coordinates directly: east → SceneKit x, north → −z, and NAVD88 elevation → y,
with a local ground-height offset for the camera. This preserves relative heights and the site's street slope without
mixing GPS ellipsoidal altitude into NAVD88. Concave footprint polygons and vertical/sloped faces are triangulated
in their dominant plane. Geometry is batched by display group with depth testing.

The download is limited to a 220 m radius around the site's origin, 250,000 vector vertices and a ground grid of at
most 1,000 × 1,000 cells. Every requested layer must send its completion flag. Conflicting nonempty `model_id`
values reject the scene so geometry from two site-model versions is not shown together. Reload after a rejection.

## Verification

`make test` covers the wire envelope, public-layer selection, empty/partial/mixed streams, elevation preservation,
concave polygon triangulation, the box-wall double-extrusion regression and navigation with no configured server.
The two live tests opt in with a reachable server:

```sh
CANOPY_GERARDUS_URL=http://HOST:50061 swift test --package-path Packages/CanopyReference --filter VectorReferenceTests
TEST_RUNNER_CANOPY_GERARDUS_URL=http://HOST:50061 scripts/test.sh -only-testing:CanopyUITests/VectorMapUITests
```

The live UI test loads Kirkham–9th, verifies nonzero box walls, orbits, toggles the ground, resets the camera and
keeps a screenshot in the `.xcresult`. It is skipped when no live server was provided.
