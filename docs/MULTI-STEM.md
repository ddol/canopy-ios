# Trees with many trunks

Status: plan, not built. Written after the Golden Gate Park survey on 16 November 2026. That day we met trees with
many trunks or branches less than 4 m apart. Canopy fits them badly today.

## What Canopy does today

- A tree has one trunk. `TreeProfile` can fork once: rings below the fork have no `stem`, and each ring above it
  belongs to a numbered stem (`TreeSection.stem`). The stems funnel into the main trunk's top ring. So a profile can
  describe a "Y". It can't describe a clump of five stems that come out of the ground separately, or a trunk that
  forks and forks again.
- A scan measures one trunk. `TrunkStems.pieces` and `TrunkStems.rings` split a slice into the trunks it crosses.
  Then `TrunkAnalysis.trunk(in:touching:)` keeps only the piece nearest where the scan started. The other stems are
  found and then thrown away.
- The shared map allows one tree per L22 cell (about 2.1 m square, `docs/DATA-MODEL.md`). A clump whose stems stand
  less than 2 m apart can't be recorded as separate trees, and the move check in the census refuses a move into an
  occupied cell. That rule is right: a multi-stem tree is one tree. The model needs to say so.
- The 3D map and the AR overlay draw each tree as one figure (`WireframeTree.figure`). Gerardus's TREES layer is one
  segment per tree.

## What a forester needs

1. Record a clump as one tree, with every stem's DBH and where each stem stands. Report the tree's equivalent DBH,
   the square root of the sum of the squared stem DBHs, as urban forest inventories do. Also report the stem count.
2. Check each stem against the scan and the aerial points, the way rings are checked now.
3. Split a clump that turns out to be two trees, or merge two records that turn out to be one tree.

## Plan

### 1. Model: stems as a tree of branches (CanopyModel, CanopyCapture)

- Give `TreeProfile` stems with parents: `Stem { id, parent: Stem.ID?, base: offset from the tree's base, rings }`.
  A stem with no parent grows from the ground. A stem with a parent forks off it at the parent's ring height. Today's
  single fork becomes a one-level case, and today's numbered stems become stems whose parent is the main trunk. Old
  profiles load without loss.
- Keep `Tree.dbh` as the equivalent DBH, and add `Tree.stems: [StemMeasure]` (DBH, offset from the tree's position,
  lean). Make the changeset field additive, so older clients ignore it. Proposals then show "5 stems, equivalent DBH
  0.62 m".
- `WireframeTree.figure` draws every stem. A batch of trees costs more vertices, so the 3D map's detail budget
  (`WireframeRenderer.detail`) counts stems.

### 2. Scan: keep every stem the slice crosses (CanopyCapture)

- At breast height (1.37 m), fit a ring to every piece `TrunkStems.rings` returns that has enough arc. Don't keep
  only the one nearest the start. A stem forking below 1.37 m is measured above the fork, as the standard says.
- Group the rings into stems up the scan. Rings at successive heights belong to the same stem when their centres are
  within a radius of each other. When one stem's ring turns into two above it, that's a fork, and it becomes a child
  stem. Do this at the 1 m steps `TrunkSteps` already uses. That gives the stem graph from the mesh alone.
- One scan can't see every stem of a clump 4 m across. Let a second scan of the same tree add stems
  (`saveTrunkMeasurement` already ties a scan to its tree). Match a new stem to an old one by base position within
  15 cm, and add it otherwise.

### 3. Census: bisect the clump (App, Census)

- In Rings mode, add a "Stems" mode beside Shape and Rings. It shows the stems found, one chip each, with its DBH.
  The player can:
  - **Split here**: draw a vertical cut plane through the reticle, the "bisect" from the field notes. Stems on one
    side stay with this tree, and the ones on the other side become a new tree when it's really two trees. The cut is
    a line on the ground through the reticle, along the camera's facing, so it is quick to aim between two stems.
  - **Not a stem**: drop a post or shrub the slice picked up.
  - **Add a stem**: aim at a stem the scan missed and snap a ring to it, as Snap to scan does now.
- The new tree from a split is a normal create proposal. Its L22 cell must differ from the original's, or the split
  is refused with the same message moving gives today.

### 4. Vector view: line every stem up (App, Align; CanopyMap)

- In `ScanAlignmentScene`, draw every stem's rings. The two-finger turn and the pole already work about the scan's
  centre. Add a stem picker so one stem can be nudged against the aerial points (3DEP points now draw on the 3D map)
  without moving the others.
- On the 3D map, draw a clump as its stems. Tapping a stem selects the tree. The move guide moves the whole clump,
  keeping its stems' offsets.
- Gerardus: ask the server to send stems in the TREES layer, as several segments sharing a `tree_id` tag, so
  registered clumps come back from the server whole. Until it does, Canopy keeps the stems on its own records only.

### 5. Order of work

1. The stem graph in `TreeProfile`, with migration and tests (macOS `swift test`, no simulator).
2. Keeping every stem at breast height, and the equivalent DBH. Field-test on the clumps from this survey: the scans
   are saved, so `CanopyHarness` can replay them.
3. The census Stems mode with Split here.
4. Drawing stems on the 3D map and in the alignment scene.
5. The Gerardus stems field, with the server.

## Questions for the field

- Is a stem that forks below 1.37 m one stem or two for the inventory? The standard says measure each one above the
  fork. Check that the park's own inventory does the same.
- How far apart can two stems be and still be one tree? This plan leaves that to the player: Split here is their
  call, not a threshold.
