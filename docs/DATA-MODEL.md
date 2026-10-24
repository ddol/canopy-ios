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
| `chunk` | `S2CellID` | The S2 L19 chunk the record belongs to; serialised as its canonical token, `s2_l19_token` |
| `version` | Int | Entity version for trees, tags and routes (starts at 1, +1 per change, used as `baseVersion`); always 1 for immutable records |

## S2 cells

`S2CellID` is a minimal port of Google's S2 cell ids: lat/lng → leaf cell, parent at any level, tokens, and
cell centre and corners. The tests check the port against Google's Go implementation. Gerardus uses two levels,
both calculated from the WGS 84 position:

| Level | Noun | Size in San Francisco | Example (Conservatory of Flowers) | Family display | Machine field |
|---|---|---|---|---|---|
| L16 | tile | about 150 m | `80858745b` | `80858-745b` | `s2_l16_token` |
| L19 | chunk | about 20 m | `80858745afc` | `80858-745afc` | `s2_l19_token` |

Canopy follows the S2 style guide shared with velocity.report
([geographic-indexing.md](https://github.com/banshee-data/velocity.report/blob/main/docs/lidar/architecture/geographic-indexing.md)):

- **Canonical token** (`S2CellID.token`): the CellID as lower-case hex with trailing zeros removed. It is the only
  identifier, and the only form that is stored, used as a key, written to a file or sent. `init?(token:)` accepts
  canonical tokens only.
- **Family display** (`S2CellID.familyDisplay`): for people only, in the UI, logs and prose. One hyphen after the
  family prefix: for every level at or below L10, including Canopy's L16 tiles and L19 chunks, that prefix is the
  5 hex characters cells under one L10 ancestor always share, hence **5+n** (`80858-745b`). Coarser levels have
  shorter prefixes (`8085-9` at L8). Removing the hyphen gives the canonical token back. Text a person types
  goes through `init?(familyDisplay:)`, which accepts either form, checks the hyphen sits at the family boundary,
  and yields the canonical cell. A family display is never stored.
- **Scan cue**: the guide's small visual gap inside the family prefix is standardised only for its L10/L13
  displays, so Canopy shows its L16 and L19 cells without one (`S2CellLabel`).
- **Hierarchy**: parents come from `parent(level:)` on the CellID, never from cutting or editing token text
  (the L10 cell `80858-1` has the L8 parent `8085-9`, not `8085-8`).
- **Field names** say the level and the representation (`s2_l19_token`, `s2_l16_tokens`), never character counts.
- **Cells are not identities.** A tile or chunk is a geographic index: a tree, a tag or a player's session is
  identified by its own UUID, and the WGS 84 position stays the authoritative measurement.

Records written before these names (schema v1: `cell`, `cells`, `tile`) are still read.

## Positions

`Position` holds a point three ways:

- `geo`: WGS 84 latitude and longitude in degrees, plus `altitude` (ellipsoidal height) when known;
- `enu`: east, north and up in metres from the **centre of the point's L16 tile**;
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
status otherwise. The map can show or hide each status (the chips under the summary bar).

### Tree names

A tree is called by its `localName` when players have given it one. Otherwise it gets a generated name such as
*Steadfast Raelin Caelum* (`TreeName`, `Tree.name`). Generated names are deterministic and never repeat across Golden
Gate Park. The rubric:

1. **Occupancy key.** A name belongs to the S2 **L22** cell the trunk stands in, about 2.1 m × 2.1 m in the park. At
   most one tree per L22 cell is the occupancy rule; two candidates in one cell would share a name.
2. **Naming region.** A frozen list of **414 L16 tiles** covers the park boundary plus 60 m (`regionTokens`). A cell
   outside it has no generated name ("Unnamed tree").
3. **Index.** The cell's index is its tile's position in the list (9 bits, room for 512 tiles) followed by its place
   inside the tile: the six child positions from L17 to L22 (12 bits). Distinct cells in the region get distinct
   indices below 2²¹ = 2,097,152, and 414 × 4,096 = 1,695,744 cells can be named.
4. **Scramble.** A fixed bijection of the 21-bit indices (multiplications by odd numbers and right xor-shifts) gives
   neighbouring trees unrelated names. A bijection cannot create collisions; the test suite checks all 2²¹ inputs.
5. **Spell.** The scrambled index read as three base-128 digits picks **adjective + name + Latin word**: 128 × 128 ×
   128 = 2²¹ names. So any 20,000 trees, or all 1.7 million cells, have different names.
6. **Word lists.** Every list is exactly 128 words, with no word in two lists:
   - Adjectives are everyday dictionary words that are kind or neutral, mostly about nature, light and weather. No
     words for skin colour, bodies, illness or death, no slang with a second meaning (no *Shady*, no *Dusky*), and
     no negative traits.
   - Names are invented and sound mystical. None is a well-known character, deity, saint or brand (no Tolkien or
     Narnia names), and none matches a word in the other lists.
   - Latin words are botanical epithets (*Sempervirens*, *Sylvatica*) and words for sky, weather, seasons and
     landscape (*Caelum*, *Aurora*). There are no genus names, so a name never claims a species, and no word that
     reads badly in English (no *Nigra*, *Vulgaris* or *Semen*).
7. **Stability.** Names change if a list changes or the region is reordered, so both are frozen and a test pins one
   name. Tiles can be appended to the region, up to 512, without renaming anything.

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
trees), the shared map pulled from a Gerardus server (`SharedRecord`s, which win over candidates with the same id and
add other players' trees), and the observation log. It folds the observations twice:

- the **shared** fold uses observations whose changesets are `applied`;
- the **local** fold uses observations whose changesets are `pending`, `approved` or `applied`.

Each tree's `countStatus` comes from the shared fold (`proposed` if the tree exists only locally) and its
`proposedStatus` is the local fold's status where they differ. Everything else, such as a new DBH, comes from the
local fold, so players see their own work straight away. Observations in `rejected` or `conflicted` changesets
drop out of both folds, which is how a rejected change disappears. An applied observation about an entity the
shared map already has is skipped, since the server's copy (with its version) already includes it.

Folding an observation sets the status it argues for: confirm → `confirmed`, add → `confirmed`, not a tree →
`removed`, measure → `verified`; a placed tag → `confirmed`.

## Changesets

A `Changeset` proposes changes to the shared map.

| Field | Notes |
|---|---|
| `meta` | `id` is the client-generated changeset UUID; `chunk` is the L19 chunk of the first op |
| `ops` | [`ChangeOp`]: `{op, entity, id, baseVersion, fields}` |
| `tiles` | The L16 tiles the changeset touches, sorted; serialised as canonical tokens, `s2_l16_tokens` |
| `state` | `pending`, `approved`, `applied`, `rejected`, `conflicted` |
| `approvals` | [`{playerID, isTrusted, at}`] |

`ChangesetBuilder` makes the ops by applying each observation to a copy of the current state and diffing the
entity's shared fields before and after:

- a new entity becomes `create` with every shared field and `baseVersion` 0;
- an existing one becomes `update` with only the changed fields, against its current version;
- several observations about one entity chain their base versions.

Shared fields are the entity's JSON without `meta` and without local-only fields (`proposedStatus`), plus the
canonical token of its L19 chunk as `s2_l19_token`.

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

## Aerial candidates

The base layer is a set of `TreeCandidate`s: position, height and crown radius from the aerial survey, a detection
confidence, `isSynthetic` for the bundled sample, and `source` (for example `USGS 3DEP lidar point cloud, sf-b23
(public-domain)`) for real ones. A candidate found with an admin's OpenStreetMap flag on says so in its source
("buildings masked with OpenStreetMap, for checking only"); those must never go into the shared, CC0 tree layer. Real candidates come from a Gerardus align server, for the part of the map in view (at
most 150 m from its centre) within one site (an L16 tile and its 8 neighbours); their ids are derived from the
position rounded to 1e-5 degrees, so reloading gives the same ids. Loading replaces the candidates in that area,
except those a player has observed (see docs/ARCHITECTURE.md, *Aerial data and registration*).

## Storage

`CanopyStore.LocalStore` is an actor over one connection to the system SQLite library (`import SQLite3`,
a thin wrapper, no ORM). The database is `Application Support/Canopy/canopy.sqlite` (WAL mode); blobs are in
`Application Support/Canopy/blobs/`. Both use iOS file protection
(`completeUntilFirstUserAuthentication`). The schema is versioned with `PRAGMA user_version`. v2 renamed the v1 S2
columns (`cell`, `cells`, `tile`) to level-named ones, and v3 added the shared map.

| Table | Contents | Mutability |
|---|---|---|
| `observations` | `seq` (log order), id, created_at (ms), player_id, s2_l19_token, version, kind, subject_id, changeset_id, `payload` (JSON) | **Append-only**: triggers abort any `UPDATE` or `DELETE` |
| `evidence` | id, created_at, player_id, s2_l19_token, blob (SHA-256), subject_id, kind, `payload` | **Immutable**: same triggers |
| `changesets` | id, created_at, player_id, s2_l19_token, state, s2_l16_tokens (space-separated), `payload`, updated_at | State and approvals change with sync |
| `candidates` | The aerial base layer, one JSON `TreeCandidate` per row | Replaced on import |
| `shared` | The shared map as last pulled: id, kind, version, s2_l16_token (indexed), created_by, created_at, `fields` (the entity's shared fields as JSON) | Rewritten by pulls |
| `shared_tiles` | Each pulled tile's s2_l16_token, the sequence to pull from next, and when it was pulled | Moved on by pulls |
| `trees`, `tags` | Current state: id, s2_l19_token, s2_l16_token (indexed), status columns, version, `payload` | **Derived**: rewritten on every write |

Every write runs in one transaction that also re-derives the state (`CensusState.derive`) and rewrites
`trees` and `tags`, so the derived tables always match the log; opening the store re-derives too.
`LocalStore.record(_:by:)` appends an observation and the changeset built from it atomically.

The blob store names each file by its SHA-256 (`blobs/ab/cdef…`), checks the hash on write
(`put(_:expecting:)`) and on read, and never overwrites.

The debug **Reset local data** action deletes the database files and the blob folder, then recreates an empty
store.
