# Performance: loading real trees

How long loading real trees takes, where the time goes, and how to measure it again without a Gerardus server or a
walk in the park. Everything here comes from `Packages/CanopyHarness`.

## Measuring

**The stand-in server.** `StandInServer` listens on loopback and speaks gRPC over HTTP/1.1, as the Rust server does
for URLSession: chunked replies, failures in the headers ("trailers-only"), the status page at `GET /`. `StandInAlign`
answers the align service as `gerardus serve` does (the same messages, layers in the order asked, 65,536 points a
message, intensity included, `NOT_FOUND`, `FAILED_PRECONDITION` and `PERMISSION_DENIED` where it sends them), and
`StandInMap` keeps just enough of the map service in memory for the app to sync. Each link is shaped to a
`NetworkProfile`: a round trip before every answer (two for a new connection) and a download rate shared by every
connection. Calls and bytes are counted per method.

| Profile | Round trip | Download | Meant as |
|---|---|---|---|
| `loopback` | 0 | unlimited | the phone's own work |
| `lan` | 4 ms | 96 Mbit/s | a server on the same Wi-Fi |
| `cellular` | 120 ms | 8 Mbit/s | Tailscale over LTE in the park |
| `poor` | 300 ms | 2 Mbit/s | one bar under the trees |

**The synthetic park.** `SyntheticSite` is a prepared site made from known trees: undulating ground, a lake round an
island, 48 groves and scattered single trees (2,131 in all, broadleaf and conifer crowns with returns through them),
and buildings with half their roofs unclassified, as 3DEP leaves San Francisco's. It is in a site frame offset from
local east-north-up by a datum shift, so the client has to fit its georeference, and the same seed always gives the
same site. Its 1 m voxels have 785,000 points; a 150 m area is 270,000 points and 4.5 MB, close to the 4.0 MB measured
on the real server. Any tile gets a synthetic site of its own when `canopy-harness serve` is asked about it.
`DetectionScore` matches what a load found to the true trunks.

**Tools.**

```sh
make bench                      # every profile, and the work on the phone; writes bench.json
make bench BASE=old.json        # the same, with a table of what changed since old.json
make serve PROFILE=cellular     # the stand-in on port 50099 for the app in the simulator
```

`canopy-harness bench --gzip` serves compressed answers, as the server would with compression on, and
`canopy-harness volume` prices the other ways a load could be smaller (below). To measure a real server over a real
link (from a Mac on the tailnet, say), `canopy-harness measure --server http://host:50061 [--token 8085876c1]` runs
the app's load against it, first from the server and then from the cache, with each step's time and the bytes and
calls counted on the client.

In the app, debug and TestFlight builds show how long each step of a load took under its result, and every build
logs it (`log stream --predicate 'subsystem == "io.github.ddol.canopy"'`). To profile a load with Instruments without
UI automation, which keeps the map's accessibility busy and skews the profile, launch a debug build with
`-canopy.gerardusURL http://127.0.0.1:50099 -canopy.loadTreesAtLaunch YES` and attach Time Profiler.

**Against the real server.** With `CANOPY_GERARDUS_URL` set, `LiveCacheTests` checks on real 3DEP points at Stow Lake
that kept, nudged and pieced-together loads find the same trees as a download (positions to a millimetre: the
server's datum transformation uses today's date, so two georeference fits differ by nanometres). It reads only.
Measured from the Mac mini over the tailnet, a 150 m load there took 0.4 to 1.1 s from the server and 0.10 s from the
cache.

**What the tests hold.** `swift test` in `Packages/CanopyHarness` (and the `Canopy` scheme) runs the real client
against the stand-in:

- a load finds the trees (recall and precision over 0.7 in dense groves; 0.89 and 0.99 in practice);
- a load from kept points, after a nudge, or pieced together after a pan finds exactly the trees a download does,
  and the circles planned for a pan leave no gap, for any radius;
- a stream the server cuts short fails the load and is not kept, a cancelled load keeps nothing, and kept ground
  is downloaded again once the server accepts a scan (its site model changes);
- the calls and bytes of each kind of load: a kept area costs one small `GetSite`, a pan asks only for what is new,
  a far move is one request, a new bundle is downloaded again, the oldest streams are evicted first;
- a kept area loads with no server;
- gzip answers are a third smaller and give the same trees;
- whole-site detection is pinned to a fingerprint of every tree.

`CanopyStoreTests` checks that after a mix of writes the store's state and every row match a store opened afresh on
the same file, and that a tap writes one tree row. `StandInUITests` loads trees through the app twice, from the
Layers menu, and clears the saved data in Settings; `scripts/test.sh` starts the stand-in for it.

## Results

Measured on a 2018 Mac mini (Intel i7-8700B), before (b680650) and after this work. A phone's CPU differs; the
bytes and calls do not. A 150 m area, its 20 m margin and, after, 10 m of padding:

| Over `cellular` | Before | After |
|---|---|---|
| First load | 6.9 s, 4.5 MB, 8 calls in a row | 6.7 s, 5.0 MB, 8 calls (6 at once) |
| The same area again | 6.9 s, 4.5 MB | **0.32 s**, 2 small calls |
| Moved 8 m | (a full load) | **0.32 s**, 2 small calls |
| Panned 40 m | 6.5 s, 4.2 MB | **2.1 s, 1.5 MB** |
| Zoomed in | 3.1 s, 1.6 MB | **0.29 s**, 2 small calls |
| After a relaunch | 7.1 s, 4.5 MB | **0.45 s**, 2 small calls |
| The whole site | 14.3 s, 10.2 MB | 12.7 s, 10.2 MB, 2 calls |
| A kept area, no server | fails | loads |

The two small calls of a kept load are `GetSite`, which says whether the bundle has changed, and a few cells of
ground, which say whether the site model (and so the ground) has. Over `poor` the same area again went from 22 s to
0.7 s, and a 40 m pan from 21 s to 7 s.

| Work on the phone | Before | After |
|---|---|---|
| Detect trees in a whole site (626,000 points) | 300 ms | 68 ms |
| …and build the canopy model to draw, as a load does | 325 ms | 68 ms |
| Load an area into the store, with 2,000 / 30,000 candidates | 0.7 s / 7.3 s | 17 ms / 156 ms |
| One Confirm tap, with 2,000 / 30,000 candidates | 0.5 s / 4.6 s | 12 ms / 99 ms |
| Read the candidates (each refresh did), 30,000 | 514 ms | none: kept decoded |
| Open the store at launch, with 2,000 / 30,000 candidates | 0.5 s / 8.2 s | 32 ms / 0.51 s |

In the simulator, a Release build loading 571 trees spent 8.0 s of main-thread time before and 2.6 s after: the map
no longer lays out every tree annotation again on each progress message (30 to 40 % of the main thread during the
download before, 1 to 2 % after).

### What changed

- **Kept data** (`ReferenceCache`): streams under the bundle and request, cut exactly as the server cuts; 10 m of
  padding so a nudge needs no download; pans pieced together from kept streams and up to six small requests; the site
  and georeference kept for offline loads. See [ARCHITECTURE.md](ARCHITECTURE.md), *Kept on the phone*.
- **Fewer round trips**: the georeference asks for six points at once and is kept per site; one client per server and
  player, so connections are reused (screens used to make a URLSession on every draw).
- **Detection**: the canopy model built once rather than twice, no allocation per cell, classes as a bitmask, ground
  read at cell centres (so the result does not depend on point order).
- **The store** keeps what derivation reads in memory and writes only the rows that change, and on opening rewrites
  the derived tables only when the schema or the derivation has changed (`Schema.derived`).
- **The map** draws again only when what it shows changes, and moves to the trees a zoomed-out load found.
- **gzip**: the client accepts it; the server does not send it yet.

## What could still shrink a load

`canopy-harness volume`, on the same 150 m area:

| Option | MB | Of today | Trees found (recall, precision) |
|---|---|---|---|
| 1 m voxels, as sent today | 4.51 | 100 % | 0.91, 0.99 |
| 1.5 m voxels | 2.69 | 60 % | 0.95, 0.88 |
| 2 m voxels | 1.71 | 38 % | 0.99, 0.43 |
| 1 m, without intensity | 3.97 | 88 % | the same trees |
| 1 m, gzip | 3.17 | 70 % | the same trees |
| 1 m, without intensity, gzip | 2.73 | 61 % | the same trees |
| 1 m, centimetre int16 per block, no intensity | 2.35 | 52 % | the same trees |
| 1 m, centimetre int16, gzip | 1.63 | 36 % | the same trees |

- **Coarser voxels are not free.** The 0.5 m canopy model grows false tops from sparse points: at 2 m most trees found
  are not trees. Coarser data would need the detector retuned (a coarser model), and checking on real 3DEP.
- **Compression is one line on the server.** Tonic's `send_compressed(CompressionEncoding::Gzip)` on the site service
  (with tonic's `gzip` feature) would make every load smaller now that the client accepts gzip (a fifth on real data,
  below). Tried with
  `gerardus serve` built that way: it answers in gzip and the client reads it (a test keeps its bytes). Measured with
  the stand-in compressing, a first load over `cellular` takes 5.1 s instead of 6.6 s.
- **Intensity** is 12 % of every load and Canopy never reads it: a request flag to leave it out would help, more so
  with compression.
- **Quantised coordinates** (centimetre offsets per block) would halve the points, two thirds with gzip, but need a
  new message.

Those are synthetic. On the real server, the same 150 m load at Stow Lake is 8.8 MB (483,000 points: real 3DEP there
is about twice as dense as the synthetic park), and `canopy-harness measure` prices it: gzip 80 % of that, without
intensity 86 %, both 67 %. So compression would save a fifth of a real load, and both changes a third.

## Still to do

- **The real link.** Load in the park over Tailscale on LTE with a TestFlight build and read the timing line: whether
  the time goes on the round trips, the download or the phone.
- **Many trees on Apple's map.** Each tree is a hosted SwiftUI view; MapKit still spends a second or two of main
  thread (in the simulator) adding a few hundred after a load, and that caps detected trees at 250 to 400. Drawing
  detected trees as one layer (overlays, or a canvas kept in step with the camera) with a tap that finds the nearest
  tree would lift both, at the cost of their accessibility elements.
- **Taps with the whole park loaded.** A tap re-derives the whole census (about 0.1 s with 30,000 trees on the Mac
  above). Keeping the base state between writes would make it cost only the trees the tap touches.
- **The park for offline use.** All of Golden Gate Park at 1 m voxels is roughly 300 MB as sent today, and about
  100 MB quantised and compressed: too much for the default 250 MB cache, unless the server sends less.
