# Viewing Gerardus buildings in 3D

Set the server in **Me → Settings**, then **Map → Layers → Kirkham & 9th in 3D**. The action reads the prepared
Kirkham–9th site, `8085875ef`, without having to navigate Apple's map or run tree detection first.
**3D vectors in view** reads the prepared site at the current map centre. A missing prepared site is reported;
the viewer does not silently substitute sample buildings.

Drag to orbit, pinch to zoom, and drag with two fingers to pan. **3D layers** toggles buildings (footprints and box
walls), roofs and wall surfaces (the LoD2 `BUILDINGS` layer), measured facades, streets/kerbs and ground. **Reset view** restores the initial camera. **Reload vectors** downloads the current
model. **Sources and model** shows attribution, bundle identity and the model identity returned by the server.
The phone needs access to the configured server (including Tailscale when that is how it is reached).

## On the main map

The same vectors can be drawn flat over Apple's map (or the Gerardus-only map): **Map → Layers → Load vectors in
view**, or the **Load vectors here** button that appears when the site at the map centre is not loaded yet. Each load
adds a site, so panning and loading builds up an area. **Show vectors** turns them off. Outlines, box walls and
measured facades, streets, kerbs and street surfaces are drawn from above. Ground and trees are left out, since the
census has its own trees. See ARCHITECTURE.md, *Map*.

## Available building layers

The implementation follows Gerardus's `gerardus.align.v1alpha1` contract as of Gerardus commit `5f565a9`
(`FEATURE_KIND_WALL_SURFACE = 22`, banshee-data/gerardus#35, `docs/plans/ROOFLINE-WALLS.md`), after the W4–W7 enum
additions in `596fc63`. `GetServerInfo.available_layers` determines which layers are requested.

| Layer | What the viewer draws |
| --- | --- |
| `FOOTPRINTS` (3) | DataSF outlines, with their supplied extrusion heights as a fallback when there are no box walls/building parts. The server sends them already moved by their box's shift (tags `shift_east_m`, `shift_north_m`); the viewer does not shift them again. |
| `GROUND_MESH` (7) | The site's actual ground elevation grid, displayed at roughly 4 m spacing; missing heights remain holes. |
| `BOXES` (8) | Explicit closed vertical wall polygons, with the server's shifted positions. Where the building has LoD2 roof planes their top follows the roofline (tag `top=roofline`: more than four vertices, concave where a step meets a gable); elsewhere it stands at the measured/fallback box height (`top=box`). Their `height_m` metadata is **not** applied again to the already elevated vertices. |
| `OBSERVED` (6) | Measured `WALL_PLANE` polygons, including bays/recesses, facade traces and poles from the registered site model. Sensor/correction arrows are omitted. These are derived proposals, not player-confirmed census objects. |
| `CITY_STREETS`, `KERBS`, `STREET_USE` (9, 11, 12) | Public street lines, kerbs/islands and operator-marked surfaces. |
| `BUILDINGS` (13) | LoD2 buildings, **if advertised and populated**: `ROOF_PLANE` faces (including `role=lid`, the level top of a part without faces) and `WALL_SURFACE` walls, each a closed vertical polygon from the ground up to the roofline, drawn from its own vertices. Nothing is extruded: when any wall surface arrives, a `BUILDING_PART` is drawn only as its base outline. An older server sends no wall surfaces, and then its parts are extruded to their `height` tag as before. |
| `LANE_MARKINGS`, `STREET_FURNITURE`, `TREES` (14–16) | Forward-compatible vector lines/polygons when the server advertises and supplies them. |

The summary reports the actual box-wall, measured-plane, roof-plane and wall-surface counts. No roof geometry is
invented. Box walls and wall surfaces both stop at the roofline and can stand nearly on top of each other; toggle
either group to see the other alone.
Height provenance for boxes is the server's choice: 3DEP p95, the DataSF 2010 height, or its default when neither
is available. A box wall is not proof of a measured roof or a confirmed facade.

No OSM layers, registered scan point clouds or aerial point clouds are requested. The site's source list is
filtered to the displayed layers and their 3DEP/DataSF inputs; contributed scans are credited for observed geometry.
Vector viewing is independent of the tree census and does not write server data.

## Coordinates and consistency

The scene uses the server's site ENU coordinates directly: east → SceneKit x, north → −z, and NAVD88 elevation → y,
with a local ground-height offset for the camera. This preserves relative heights and the site's street slope without
mixing GPS ellipsoidal altitude into NAVD88. Concave footprint polygons and vertical/sloped faces are triangulated
in their own plane (about their centroid, in true metres), so a concave roofline wall is never projected onto the
ground. Geometry is batched by display group with depth testing.

The download is limited to a 220 m radius around the site's origin, 250,000 vector vertices and a ground grid of at
most 1,000 × 1,000 cells. Every requested layer must send its completion flag. Conflicting nonempty `model_id`
values reject the scene so geometry from two site-model versions is not shown together. Reload after a rejection.

## Verification

`make test` covers the wire envelope, public-layer selection, empty/partial/mixed streams, elevation preservation,
concave polygon triangulation (including a concave roofline box wall in its own plane), the box-wall
double-extrusion regression, wall surfaces drawn as single faces with parts left unextruded (and the older-server
extrusion fallback), and navigation with no configured server.
The two live tests opt in with a reachable server:

```sh
CANOPY_GERARDUS_URL=http://HOST:50061 swift test --package-path Packages/CanopyReference --filter VectorReferenceTests
TEST_RUNNER_CANOPY_GERARDUS_URL=http://HOST:50061 scripts/test.sh -only-testing:CanopyUITests/VectorMapUITests
```

The live UI test loads Kirkham–9th, verifies nonzero box walls, orbits, toggles the ground, resets the camera and
keeps a screenshot in the `.xcresult`. It is skipped when no live server was provided.
