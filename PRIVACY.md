# Privacy

Canopy is a tree census, not a camera app. This page lists everything the app keeps and everything it will
send, so you can check it against the code.

## The short version

- **No photos, ever.** The app never stores or uploads camera images or video.
- **Evidence is colourless geometry.** When you measure a trunk or tag a limb, the app keeps a 3D mesh
  (vertex positions and triangles only, no colour or texture), cropped to a small radius around the
  subject. Geometry has no faces or colours, but someone standing right next to the tree would still show up as
  a shape, so scan when nobody is within a couple of metres of it.
- **One identity.** Your Game Center player id and alias are the only identity in the data. No email, no
  name, no device identifiers, no advertising ids, no analytics.
- **Census sync is still local.** Changesets go to a simulated server on your device. The only data that leaves
  the device is described under *Gerardus align server* below, and only when you ask for it.

## Permissions

| Permission | Why | What happens to the data |
|---|---|---|
| Camera | ARKit needs the camera to track the device and reconstruct a mesh with LiDAR. | Camera frames are processed in memory by ARKit and discarded. The app never reads a frame into storage. |
| Location (when in use) | To place trees and tags on the map and to know which S2 cell an observation belongs to. | Stored as the position of the tree or tag you record, with its uncertainty. The app does not keep a track of where you walked. |
| Game Center | To give your records an author, so two players can agree on a change. | Your Game Center player id and alias are stored with each record you create. |

## What is stored on your device

| Data | Contents | Where |
|---|---|---|
| Observations | What you did (confirmed a tree, measured a trunk, tagged a limb), when, where (S2 cell and position), and your player id. Append-only. | SQLite database in the app's Application Support folder |
| Current state | Trees and tags derived from the observations. | Same database |
| Changesets | The changes you propose for the shared map, with their state (pending, approved, applied, rejected, conflicted). | Same database |
| Evidence | Cropped, colourless meshes as GLB files, named by their SHA-256 hash: trunk scans (the trunk plus 0.6 m around it, at most 2 m from its centre) and limb scans (1 m around the limb point). | `blobs/` folder in Application Support |
| Local player id | A random `local:<uuid>` used for records made before (or without) Game Center sign-in. | User defaults |
| Gerardus server address | The address you typed in **Me → Settings** (`canopy.gerardusURL`). | User defaults |

The data is protected by iOS file protection. **Me → Reset local data** (debug builds) deletes all of it.
Debug builds can also share a scan's GLB file or preview it; that only happens when you tap Share or Preview.
Deleting the app deletes all of it too.

## Gerardus align server

Canopy can use a Gerardus align server on your network (Map → Layers → **Load real trees in view**, and Census →
**Register with 3DEP**). You set its address in **Me → Settings**; until you do, the app contacts no server. iOS
asks for Local Network permission the first time.

- **Testing the connection** (Me → Settings → **Test connection**) sends one `GET /` and shows what the server
  answers (its version, commit, uptime and reference layers). The request carries no player id, alias, location
  or record, and the app keeps only the address, not the answer.
- **Loading real trees** sends the S2 tile you are looking at and the circle of the map in view (its centre and
  radius) and downloads public data for it (USGS 3DEP aerial LiDAR and DataSF footprints, plus OpenStreetMap for an
  admin who turned it on). The map
  position is where you are looking, not where you are, and nothing about you is sent.
- **Registering a scan** happens only when you tap Register and confirm. It uploads the colourless mesh the AR
  session has reconstructed within 60 m of where the session started, thinned to one point per 10 cm, with the
  session's approximate GPS position. It is geometry only (no photos, colours or textures), it is not cropped to a
  tree, and anyone nearby is in it as a shape, so register when nobody is close. The scan is stored on that server
  under a random sensor id and capture reference, with no player id. The server keeps the scan and the registration
  run.

In every case the server also sees the network address the request comes from. Plain `http://` is allowed only to
`.local` names, IP addresses and tailnet (`*.ts.net`) hosts; Tailscale encrypts tailnet traffic between devices.
Any other server must use HTTPS.

## What will be synced (not yet)

When the Gerardus server exists, Canopy will upload:

- your changesets (the changes you propose, with their S2 cells and your player id and alias);
- the evidence meshes those changesets reference;

and download other players' approved changes for the cells you are in. Nothing else.

## Fixture data

The sample data in `Fixtures/ggp/` is synthetic and does not describe real people.

## Questions

Open an issue, or for anything sensitive follow [SECURITY.md](SECURITY.md).
