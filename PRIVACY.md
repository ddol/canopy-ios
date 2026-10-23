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
- **Sync sends nothing yet.** Sync is a local fake. The only network request the app makes is the connection
  test in **Me → Settings**, and only when you tap it (see below).

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

## The connection test

**Me → Settings → Test connection** sends one `GET /` to the Gerardus server address you entered, and shows
what the server answers (its version, commit, uptime and reference layers). The request carries no player id,
alias, location or record; the server sees only the request itself and the network address it comes from. The
app makes no request until you tap the button, and it keeps only the address, not the answer.

Plain `http://` is allowed only to `.local` names, IP addresses and tailnet (`*.ts.net`) hosts; Tailscale
encrypts tailnet traffic between devices. Any other server must use HTTPS.

## What will be synced (not yet)

When the Gerardus server exists, Canopy will upload:

- your changesets (the changes you propose, with their S2 cells and your player id and alias);
- the evidence meshes those changesets reference;

and download other players' approved changes for the cells you are in. Nothing else.

## Fixture data

The sample data in `Fixtures/ggp/` is synthetic and does not describe real people.

## Questions

Open an issue, or for anything sensitive follow [SECURITY.md](SECURITY.md).
