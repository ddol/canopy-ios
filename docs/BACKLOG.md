# Backlog

Work we know we want but have not scheduled. Issues are turned off on this repository, so this file is the list;
a pull request that picks an item up should remove it here.

## Aerial data volume

Loading real trees over a slow link (Tailscale from the park, on a phone) stalled with a spinner. The app now loads
only the map in view, at most 150 m from its centre, and every Gerardus call has a time limit (see
[ARCHITECTURE.md](ARCHITECTURE.md), *Aerial data and registration*). That cuts the download, but it is still
megabytes per load. Measured against a server on the same LAN, streaming the canopy classes at 1 m voxels:

| Request | Bytes | Of which aerial points | Ground grid | OSM | Time on the LAN |
|---|---|---|---|---|---|
| Whole site (9 L16 tiles) | 15.2 MB | 14.2 MB | 0.81 MB | 0.13 MB | 1.2 s |
| 150 m radius | 4.0 MB | 3.5 MB | 0.36 MB | 0.06 MB | 1.1 s |

Preparing a new park site took 15 s on the server; its OSM step took 0.1 s, so the "Preparing the osm data" label
seen on the phone was a stale progress update (since fixed), not OSM being slow.

Since then the phone keeps what it loads (an area again, a nudge, a zoom-in or a relaunch costs one small call, a
pan only what is new, and kept areas load offline), fits the georeference in a round trip or two, and accepts gzip.
[PERFORMANCE.md](PERFORMANCE.md) has the measurements and a stand-in server to repeat them. Still open:

- **Compression on the server.** The client accepts gzip; tonic's `send_compressed(Gzip)` on the site service would
  make every load about 20 % smaller (measured on the real Stow Lake stream).
- **Leaving out intensity.** 14 % of every real load, unused by Canopy: a request flag on `StreamReferenceRequest`.
  With compression, the two save a third.
- **Encoding.** Centimetre int16 offsets per block would halve the points (two thirds with gzip); needs a new message.
- **Downsampling.** Measured on the synthetic park: 2 m voxels are 38 % of the bytes but most trees found are false
  (the 0.5 m canopy model is speckled); 1.5 m keeps recall but loses some precision. Only with the detector retuned,
  and checked on real 3DEP.
- **What the phone needs at all.** Detection could run on the server, so the phone gets trees rather than points.
  That needs a server API.
- **Measuring the real link.** Throughput and latency over Tailscale on cellular in the park, and which step the time
  goes on: TestFlight builds now show each step's time under a load's result.
- **The park for offline use.** About 300 MB as sent today; worth it only once the server sends less.

## Map and store with many trees

- **Detected trees as one layer on Apple's map.** Each tree is a hosted SwiftUI view: MapKit takes a second or more
  of main thread to add a few hundred, and detected trees are capped at 250 to 400. Overlays, or a canvas in step
  with the camera, with a tap that finds the nearest tree, would lift both (detected trees would lose their
  accessibility elements).
- **Incremental derivation.** A tap re-derives the whole census: about 0.1 s with a park's worth of candidates on a
  2018 Mac. Keeping the base state between writes would make a tap cost only the trees it touches.
- **The result banner** (result, timings in test builds, Load vectors here, credits) covers a third of a phone's map.

## The shared census

Sync pushes changesets, pulls the shared map for the tiles in view and those followed before, and fills the
review queue. Loaded trees are saved to the server's trees layer. Still to do:

- **Evidence offline.** Another device's scan is downloaded only when previewed; nothing prefetches it for offline use.
- **Forgetting tiles.** Followed tiles are never dropped, so a sync grows with every area looked at.
- **Verified identity.** The server trusts the player id header. It should check Game Center's identity signature
  (a server follow-up), and the app should send it.
- **Changesets from before sign-in** carry the `local:` id. A server takes changesets only from their author, so
  after a Game Center sign-in sync leaves them on the phone. Offer to propose them again under the new id.

## Tree names and occupancy

- **One tree per L22 cell.** Names assume it, but aerial detection can still put two candidates in one cell in dense
  groves. Merge or nudge them when the occupancy primitive lands.
- **Growing the naming region.** Tiles can be appended to `TreeName.regionTokens` (up to 512) without renaming
  anything, for example for street trees around the park.

## Gerardus map

- Shade the ground model (hillshade) under the canopy, and show the player's position.
- Keep the loaded area's canopy grid and outlines across launches; they are in memory only.

## Limb tagging

Hidden for now (`Features.limbTagging`). To bring it back as an extension:
- Turn the switch on, and look again at the Tag flow on the LiDAR mesh.
- Bring hazard tags into the review queue and the proposals list.
- Decide how tag evidence (limb scans) is shared and previewed.

## Vectors

- Loaded vectors and canopy grids live in memory; keep them across launches.
- Show which areas are loaded on the map, and let a player drop one.
