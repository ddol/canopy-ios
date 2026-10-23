# Data model

All types live in `CanopyModel` and are plain `Sendable`, `Codable` values. Units are SI: lengths in metres,
angles in degrees (accepted for use with the SI), times as UTC instants.

## Common fields

Every record carries a `RecordMeta`:

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | Generated on the device that created the record |
| `createdAt` | Date | Stored as whole milliseconds since 1970 |
| `playerID` | `PlayerID` | Game Center `teamPlayerID`, `local:<uuid>` before sign-in, or `gerardus:aerial` for the aerial base layer |
| `cell` | `S2CellID` | The level-19 chunk the record belongs to |
| `version` | Int | Entity version for trees, tags and routes (starts at 1, +1 per change, used as `baseVersion`); always 1 for immutable records |

## S2 cells

`S2CellID` is a minimal port of Google's S2 cell ids: lat/lng → leaf cell, parent at any level, tokens, and
cell centre and corners. Gerardus uses **level 16 for tiles** (about 150 m across in San Francisco) and
**level 19 for chunks** (about 20 m). Tokens are lower-case hex without trailing zeros, for example
`80858745b` (tile) and `80858745afc` (chunk) at the Conservatory of Flowers. The tests check the port against
Google's Go implementation.

## Positions

`Position` holds a point three ways:

- `geo`: WGS 84 latitude and longitude in degrees, plus `altitude` (ellipsoidal height) when known;
- `enu`: east, north and up in metres from the **centre of the point's level-16 tile**;
- `covariance`: a symmetric 3 × 3 covariance of the ENU offsets, in m².

In Milestone 0 a position comes from Core Location at the moment of the observation (σ is the reported
horizontal accuracy, typically 5 to 15 m under canopy), with the AR session's offset to the subject added.
Registering to aerial crowns, which should bring σ down to well under a metre, is a Milestone 1 issue.

## Trees

| Field | Type | Notes |
|---|---|---|
| `meta` | `RecordMeta` | |
| `position` | `Position` | Trunk centre at ground level |
| `countStatus` | `CountStatus` | The agreed status on the shared map |
| `proposedStatus` | `CountStatus?` | **Local only.** The status this device has proposed and is waiting for agreement on |
| `species`, `localName` | String? | |
| `dbh` | `DBH?` | `diameter` (`Quantity`, m), `method` (`lidarCircleFit`, `tape`, `estimate`), `height` (1.37 m) |
| `lean` | `Lean?` | `angle` from vertical (`Quantity`, °), `azimuth` from true north (`Quantity?`, °) |
| `height` | `TreeHeight?` | `height` (`Quantity`, m), `source` (`aerialLidar`, `groundLidar`, `estimate`) |
| `evidenceRefs` | [`BlobRef`] | SHA-256 of evidence meshes |
| `candidateID` | String? | The aerial candidate the tree came from |

A `Quantity` is a value and its standard uncertainty (one standard deviation): `0.42 ± 0.01 m`.

### Count status

| Status | Meaning | Map symbol |
|---|---|---|
| `detected` | Found by aerial LiDAR; no one has looked yet | faint dot |
| `proposed` | Added by a player, or a change proposed by this device, not yet agreed | dashed ring |
| `confirmed` | Two players agree it is a tree, at least one trusted | ring |
| `verified` | Confirmed, and its trunk measurement is agreed too | solid dot |
| `removed` | Agreed not to be a tree, or gone | hidden |

The UI shows `displayStatus`, which is `proposed` while this device waits for agreement and the agreed
status otherwise.

## Tags

A limb hazard on a tree.

| Field | Type | Notes |
|---|---|---|
| `meta` | `RecordMeta` | |
| `treeID` | UUID | |
| `point` | `Tag.Point` | `position` (`Position`) and `heightAboveGround` (`Quantity`, m) |
| `issue` | `deadwood`, `hanger`, `crack`, `decay`, `weakUnion`, `other` | |
| `couldHit` | `path`, `road`, `seating`, `playArea`, `structure`, `nothing` | |
| `sizeClass` | `small` (< 0.10 m), `medium` (0.10 to 0.30 m), `large` (> 0.30 m) | Limb diameter |
| `urgency` | `low`, `moderate`, `high`, `immediate` | |
| `evidenceRef` | `BlobRef?` | Optional limb mesh |
| `status` | `proposed`, `confirmed`, `resolved` | `proposed` until agreed |

## Routes

`Route` has a `name`, a `kind` (`path`, `trail`, `road`, `bridleway`, `cycleway`), a list of `GeoPoint`s and a
`status` (`proposed`, `confirmed`). Route labelling is a Milestone 1 feature; the type exists so the store and
map have a place for it.

## Evidence

Evidence is immutable: a cropped, colourless mesh stored as a GLB blob and named by its SHA-256.

| Field | Notes |
|---|---|
| `blob` | `BlobRef`, the lower-case hex SHA-256 of the GLB bytes |
| `byteCount`, `mediaType` | `model/gltf-binary` |
| `kind` | `trunkScan` or `limbScan` |
| `subjectID` | The tree or tag |
| `cropRadius` | Radius of the crop around the subject, in metres |
| `vertexCount`, `triangleCount` | |

The GLB holds vertex positions and triangle indices only: no normals, colours, textures or images.

## Observations

A `FieldObservation` is something a player saw or did. (It is not called `Observation` because that name
belongs to Apple's Observation framework, which `@Observable` expands into.) Observations are
**append-only**: the store never updates or deletes one. Each has a `RecordMeta`, the id of the changeset that
shares it, and a `kind`:

| Kind | From |
|---|---|
| `treeConfirmed(treeID)` | Census → Confirm tree |
| `treeAdded(Tree)` | Census → New tree here |
| `treeRejected(treeID)` | Census → Not a tree |
| `trunkMeasured(treeID, dbh, lean, evidence)` | Census → Scan trunk |
| `tagPlaced(Tag)` | Tag |

## Deriving the current state

`CensusState.derive` builds the current trees and tags from the aerial base layer (candidates as `detected`
trees) and the observation log. It folds the observations twice:

- the **shared** fold uses observations whose changesets are `applied`;
- the **local** fold uses observations whose changesets are `pending`, `approved` or `applied`.

Each tree's `countStatus` comes from the shared fold (`proposed` if the tree exists only locally) and its
`proposedStatus` is the local fold's status where they differ. Everything else, such as a new DBH, comes from the
local fold, so players see their own work straight away. Observations in `rejected` or `conflicted` changesets
drop out of both folds, which is how a rejected change disappears.

Folding an observation sets the status it argues for: confirm → `confirmed`, add → `confirmed`, not a tree →
`removed`, measure → `verified`; a placed tag → `confirmed`.

## Changesets

A `Changeset` proposes changes to the shared map.

| Field | Notes |
|---|---|
| `meta` | `id` is the client-generated changeset UUID; `cell` is the chunk of the first op |
| `ops` | [`ChangeOp`]: `{op, entity, id, baseVersion, fields}` |
| `cells` | The level-16 tiles the changeset touches, sorted |
| `state` | `pending`, `approved`, `applied`, `rejected`, `conflicted` |
| `approvals` | [`{playerID, isTrusted, at}`] |

`ChangesetBuilder` makes the ops by applying each observation to a copy of the current state and diffing the
entity's shared fields before and after:

- a new entity becomes `create` with every shared field and `baseVersion` 0;
- an existing one becomes `update` with only the changed fields, against its current version;
- several observations about one entity chain their base versions.

Shared fields are the entity's JSON without `meta` and without local-only fields (`proposedStatus`), plus `cell`.

**Policy.** A changeset reaches the shared map only when at least two distinct players agree, and at least one
of them is trusted. The author's submission counts as one agreement (`Changeset.meetsPolicy`).

## Summary bar

`CensusSummary` gives the Map tab's numbers:

- **Confirmed**: trees whose agreed status is `confirmed` or `verified`;
- **Estimated**: trees this device believes are not `removed` (agreed status, or this device's proposal);
- **Coverage**: the share of Estimated that someone has looked at, meaning anything past `detected`.

## JSON

`CanopyJSON` encodes with sorted keys and dates as integer milliseconds since 1970, so encodings are stable
enough to hash and compare.

## Storage

`CanopyStore.LocalStore` is an actor over one connection to the system SQLite library (`import SQLite3`,
a thin wrapper, no ORM). The database is `Application Support/Canopy/canopy.sqlite` (WAL mode); blobs are in
`Application Support/Canopy/blobs/`. Both use iOS file protection
(`completeUntilFirstUserAuthentication`). The schema is versioned with `PRAGMA user_version`.

| Table | Contents | Mutability |
|---|---|---|
| `observations` | `seq` (log order), id, created_at (ms), player_id, cell, version, kind, subject_id, changeset_id, `payload` (JSON) | **Append-only**: triggers abort any `UPDATE` or `DELETE` |
| `evidence` | id, created_at, player_id, cell, blob (SHA-256), subject_id, kind, `payload` | **Immutable**: same triggers |
| `changesets` | id, created_at, player_id, cell, state, cells, `payload`, updated_at | State and approvals change with sync |
| `candidates` | The aerial base layer, one JSON `TreeCandidate` per row | Replaced on import |
| `trees`, `tags` | Current state: id, cell, tile, status columns, version, `payload` | **Derived**: rewritten on every write |

Every write runs in one transaction that also re-derives the state (`CensusState.derive`) and rewrites
`trees` and `tags`, so the derived tables always match the log; opening the store re-derives too.
`LocalStore.record(_:by:)` appends an observation and the changeset built from it atomically.

The blob store names each file by its SHA-256 (`blobs/ab/cdef…`), checks the hash on write
(`put(_:expecting:)`) and on read, and never overwrites.

The debug **Reset local data** action deletes the database files and the blob folder, then recreates an empty
store.
