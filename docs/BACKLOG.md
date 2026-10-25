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

To investigate:

- **Downsampling.** A coarser voxel (2 m) for detection, or only the top return per cell (a canopy height model built
  on the server); how much detection quality each costs.
- **What the phone needs at all.** Detection could run on the server, so the phone gets trees rather than points.
  That needs a server API.
- **Encoding.** Points are float32 x, y, z in the site frame; quantised int16 offsets per block, or compression
  (the server would have to offer it; the client refuses compressed messages today).
- **Caching.** Keep the last loaded area's trees, or the points, keyed by the site's `bundle_id`, so reloading the
  same area costs nothing.
- **Measuring the real link.** Throughput and latency over Tailscale on cellular in the park, and which step the time
  goes on, before choosing among the above.

## Trees on the server

The phone keeps the trees it finds to itself: sync still goes to the in-memory fake. The Gerardus server needs a
changeset API and a tree layer (work in progress in the gerardus repository), and then:

- **A real `GerardusClient`** over the same hand-written gRPC transport, replacing the fake in sync.
- **Uploading detected trees** for the loaded area, idempotently by their stable ids, but never ones found with
  OpenStreetMap (their source says "for checking only").
- **OpenStreetMap only for admins on the server too.** The app now asks for OSM only behind the admin flag. Once the
  server gates the layer, the app has to identify the admin to it.

## Tree names and occupancy

- **One tree per L22 cell.** Names assume it, but aerial detection can still put two candidates in one cell in dense
  groves. Merge or nudge them when the occupancy primitive lands.
- **Growing the naming region.** Tiles can be appended to `TreeName.regionTokens` (up to 512) without renaming
  anything, for example for street trees around the park.

## Gerardus map

- Shade the ground model (hillshade) under the canopy, and show the player's position.
- Keep the loaded area's canopy grid and outlines across launches; they are in memory only.
