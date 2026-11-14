# Scan history across devices

What it would take for a player to see every scan their account has taken, on any device, and how much of it Gerardus
already does. Written 12 November 2026, for the iPad (no LiDAR) showing the scans taken on a phone.

## What works today

- **Meshes are already on the server.** Sync uploads every blob a changeset names (`evidenceRefs` on a tree,
  `evidenceRef` on a tag) before submitting it (`SyncCoordinator`), and Gerardus keeps them content-addressed under
  `<data>/blobs/sha256/` (`UploadBlob`, `GetBlob`, and `GET /api/v1/blobs/<sha256>`). Any device can fetch one by its
  hash (`AppModel.evidenceFile`).
- **Me → Your scans lists the scans from your other devices** (this PR). The device finds them in two places:
  - your open changesets in the tiles it follows (`ListOpenChangesets`, already asked for at each sync for the review
    queue), which are scans still waiting for a second player;
  - the change history of the tiles whose trees and tags hold scans it does not have (`PullChanges` from sequence 0),
    which names the author of each change. A scan belongs to the player whose change first added it to the entity.
- Each listed scan downloads when it is opened. Preview, Share, Show on map and Align rings all work from the
  downloaded blob, so an iPad without LiDAR can align a phone's scan.

## What today's approach misses

1. **Scans outside the followed tiles.** The device only looks in tiles it pulls. A scan taken somewhere this device has
   never had on its map (Muir Woods, for an iPad that has only opened San Francisco) is not found.
2. **Scans that never reached a changeset.** A scan saved on the phone and not yet synced, or a changeset the server
   rejected, exists only on that phone. So do the rings and crown aligned against a scan (`ScanAlignment`, kept in the
   phone's store and never synced).
3. **The scan's own record.** `Evidence` (kind, crop radius, vertex and triangle counts, size, taken at) is not
   synced; the other device sees only the hash and the tree. Its list shows the change's date, not the moment the scan
   was taken, and no triangle count until the mesh is downloaded.
4. **Cost.** Pulling a tile's whole history is a few round trips a tile, which is fine for the handful of tiles holding
   scans, but grows with the map.
5. **Identity.** Gerardus believes the `x-gerardus-player-id` header. Anyone can list anyone's scans by naming their id.
   That is acceptable while the history is assembled from public map data, but not for private data such as unsynced
   scans or alignments.

## What a proper scan history on Gerardus would entail

**A scans table, written at upload.** `UploadBlob` would take the scan's metadata with the bytes: the `Evidence`
record (kind, subject, crop radius, counts, taken at), plus the uploading player and a device label. Gerardus would
keep them in a `scans` table beside the blob store, one row per (hash, player). Uploading the same bytes again would add
no blob, only a row if another player uploaded them.

**One call to list them.** A `ListPlayerScans(player, page_token)` RPC would return the caller's scans, newest first,
with their subject and tile, and the state of the changeset carrying each (none yet, waiting, applied, rejected). It
would page and work anywhere, without following tiles. The iPad's list would then come from one call, and the history
pulls above would go.

**Upload before the changeset.** For the history to hold scans not yet submitted, sync would upload a scan as soon as
it is saved, not when its changeset goes. That costs upload data on cellular: upload on Wi-Fi only, or when the user
asks.

**Alignments too, optionally.** A `ScanAlignment` is small JSON keyed by (scan, tree). A `PutScanAlignment` /
`ListScanAlignments` pair would let rings aligned on the iPad show on the phone, and the other way round. The last write
would win per (scan, tree, player).

**Real identity before anything private is served.** The device would send Game Center's identity-verification
signature (`fetchItems(forIdentityVerificationSignature:)`), and Gerardus would check it against Apple's public key
once per session and hand back a token. Until then, the server would list only what the shared map already makes
public.

**Limits and housekeeping.**
- The blob cap is 16 MiB (`max_blob_bytes`). The 230k–300k-triangle redwood scans from Muir Woods are near it. Either
  raise the cap for `model/gltf-binary` or compress the GLB (meshopt or Draco).
- Add a per-player quota and a way to delete your own scans. Deleting a scan a changeset still names would only hide
  it, since the map's evidence must stay readable.
- The nightly snapshots already copy `<data>/blobs`. The scans table goes in the same SQLite file as the map, so it is
  backed up with it.

**Rough size.** On the Gerardus side: a table, two or three RPCs, identity verification, and tests, about a week. On
the app side: send `Evidence` with each upload, a `ListPlayerScans` client, an early-upload setting, and the Scans
screen switched to the new call, a few days. The identity work can come last if the first version lists only public
scans.
