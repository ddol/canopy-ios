# Viewing Gerardus buildings in 3D

Set the server in **Me → Settings**, load a site with **Map → Layers → Load vectors in view** (or the **Load vectors
here** button), and pick **Map → Layers → Gerardus 3D**: the map's one 3D view (the AR view in Census is the other).
A site the server has not prepared is prepared first; nothing stands in for it.

**Buildings** are the ones Gerardus reconstructed from 3DEP inside DataSF's footprints, the `BUILDINGS` layer: each
part's outline, its roof planes (drawn in a roof colour) and its wall surfaces. DataSF's boxes (`BOXES`, the footprints
raised to a measured roof height with flat tops) are never drawn: they stood where the reconstructed walls do, so the
two overlapped. Nor are the measured facade planes. A site sent without reconstructed buildings shows DataSF's
footprints as outlines on the ground. AR draws the same buildings (`SiteBuildings`). The phone needs access to the
configured server (including Tailscale when that is how it is reached).

## On the main map

The same vectors can be drawn flat over Apple's map: **Map → Layers → Load vectors in view**, or the **Load vectors here** button that appears when the site at the map centre is not loaded yet. Each load
adds a site, so panning and loading builds up an area. **Show vectors** turns them off. Outlines, box walls and
measured facades, streets, kerbs and street surfaces are drawn from above, and Gerardus's trees as their crowns (a
ring of `crown_radius_m`, 2 m when the server gives none). Ground is left out. See ARCHITECTURE.md, *Map*.

## The 3D map

**Map → Layers → Gerardus 3D** replaces Apple's map with the loaded sites drawn in 3D the way the Mac visualiser draws
them (ground grid, reconstructed buildings with their roofs, streets and kerbs, trees as trunk and crown rings), with
the census's trees as the same figure in their status colour, from their DBH and height when measured. It moves as
Apple's map does: one finger drags it, and the ground under the finger stays under it, gliding on when let go; two
fingers pinch to zoom and twist to turn about the point between them; two fingers moving up or down together tilt it;
double-tap zooms in where tapped and a two-finger tap zooms out; tapping a tree opens its sheet. The ground grid is on
until **Ground** (in the same menu) turns it off; it is tinted by height, dull green low to pale high over the range of
the loaded sites, so slopes read without lighting. **Show vectors** hides the buildings, streets and Gerardus's trees.
It shows only what has been loaded: use **Load vectors in view** (or the **Load vectors here** button) to add the site
at the map centre. Sites loaded in AR are on this map too, and a tree reshaped or fitted ring by ring in AR is drawn
here in that shape. **S2 cells (L13 and L16)** draws the level-16 tiles with trees (green when surveyed) and their
level-13 cells, with posts at the corners.

## Surveyed cells

Confirming or rejecting each detection is slow where a big crown makes several of them. **Map → Layers → Surveyed
cells (L16)** lists the level-16 cells under the map with what the census holds in each (confirmed, not trees,
detections left); **Mark surveyed** says the cell has been walked and looked over, so the detections left in it count
as looked at and are drawn faint. The same mark is in AR under **Wireframes → This cell**, where the cell the player
stands in is named under the target card. Marks stay on the phone for now (`surveyed_cells` in the store).

## Server cells

**Map → Layers → Server cells (L13)** lists the S2 level-13 cells under the map (about 1.2 km across, 64 level-16
sites each), nearest the centre first, with how many of each cell's sites the server has prepared (`ListSites`).
**Prepare the rest** asks the server for the missing sites one after another; **Rebuild all** asks for every site
again with `refresh`, so each source is fetched afresh. A site takes the server a minute or two, so a cell takes an
hour or more; the work carries on in the background with progress and a Cancel on the screen, and a site that is
still building is asked for again every 15 s for up to ten minutes before it counts as failed.

## In AR

On a LiDAR phone the Census view draws the loaded sites round the player as wireframes, the way the Mac visualiser
draws them: trees as a brown trunk to the crown's base with green rings of the crown's radius at its base and top
(plus rings of `dbh_m` on the trunk), buildings as the outlines of their box walls, wall surfaces, roof planes and
measured facades, streets and kerbs as lines. The census's own trees are drawn the same way in a darker green, from
their DBH and height when measured. The layers are toggled from the **Wireframes** menu in the target card.

The site under the player is asked for on arrival (prepared first when the server has not seen it, which can take a
minute or two), and again for each new tile walked into, so an area builds up as the player moves; **Load vectors
here** asks again. Neighbouring sites overlap, and a feature is drawn once.

Where the site lands in the AR world comes from the 3DEP registration when there is one (**Register with 3DEP**),
exact to its sigma. Before that it comes from the GPS fix: the session origin's position from the best fix so far
and the camera's offset then, the site's georeference for the horizontal, and the ground under the origin (the
LiDAR mesh's floor against the site's ground grid) for the vertical. That is GPS metres out, which is what
eyeballing a wireframe against the real tree is for; **Re-place overlay from GPS** takes the current fix again.

Tapping a tree selects it: its panel shows what is known (DBH, height, the Street Tree List or an observed crown),
with sliders for trunk diameter, height, foliage height and width that reshape its wireframe on the spot. A census
tree picked this way becomes the target for Confirm, Not a tree and Scan trunk. Adjustments live in the view for the
session; nothing is written to Gerardus. The trunk scan's own fitted tree starts from the selected tree's shape.

After a trunk scan the fitted tree is a stack of rings (cross-sections) from the ground up, not two cylinders.
**Shape** moves them all with the four sliders; **Rings** picks one ring (orange in AR) to move up or down, widen or
narrow, **Snap to scan** (a circle fitted to the scan's depth points, or its mesh, at that height: the breast-height
ring and a ring every metre up, as far as the depth points reach, start snapped), **Looks right** to confirm it
against the tree, add a ring above or take one out.

**Align steps** adds the rest of the steps up to the crown's base, predicted from the axis and taper of the fitted
rings below. As the player walks round with the phone pointed up the trunk, each step moves to the trunk's edges in
the camera image. Rings are drawn by how they were set: lime fitted to the scan, blue aligned to the camera, green
confirmed, brown by eye. Uprights join each ring to the next, so a trunk tapers and a crown bulges. Snapped, aligned
and confirmed rings stay put when the Shape sliders move the rest. Saving the measurement keeps the fitted shape for that tree for the session, in AR and on the
wireframe map.

The **Wireframes** menu's **S2 cells** layer draws the level-16 tiles round the player on the ground with short
posts at their corners (green when surveyed) and their level-13 cells with tall blue posts.

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
| `TREES` (16) | `TREE` segments from the trunk's base to the crown's base, with `dbh_m`, `height_m`, `crown_base_m`, `crown_radius_m`, `species` and `common_name` tags when known (`GerardusTree`). The 3D viewer and AR draw the Mac visualiser's figure: trunk line, crown rings at `crown_base_m` (else the segment's top) and `height_m` (else a crown as tall as it is wide), radius `crown_radius_m` (else 2 m). The map draws the crown ring. |
| `LANE_MARKINGS`, `STREET_FURNITURE` (14–15) | Forward-compatible vector lines/polygons when the server advertises and supplies them; AR draws them with the streets. |

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
The live test opts in with a reachable server:

```sh
CANOPY_GERARDUS_URL=http://HOST:50061 swift test --package-path Packages/CanopyReference --filter VectorReferenceTests
```

The live test loads Kirkham–9th (`VectorReference.kirkham9th`, `8085875ef`) and checks its layers. It is skipped when
no live server was provided.
