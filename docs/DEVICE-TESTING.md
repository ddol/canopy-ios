# Testing on a device

LiDAR capture (the Census AR view, Scan trunk, 3D limb points) only works on an iPhone or iPad Pro with
LiDAR; no simulator can reconstruct a mesh. Everything else is covered by `scripts/test.sh` on the simulator.

There are two ways to get Canopy onto a phone:

- **Straight from a Mac** (`scripts/device.sh`): the fastest loop while developing. The phone is paired with the
  Mac.
- **TestFlight** (`scripts/testflight.sh`): for testers in the park. They install from the TestFlight app; no Mac
  needed.

Both need a paid Apple Developer Program team.

## One-time setup

1. **Sign Xcode in to your team.** Xcode → Settings → Accounts → + → Apple ID. Your team appears under the
   account; its id is the 10-character code shown on [developer.apple.com → Membership
   details](https://developer.apple.com/account#MembershipDetailsCard).
2. **Point the project at your team.** Copy `Configs/Local.xcconfig.example` to `Configs/Local.xcconfig`
   (git-ignored) and set `DEVELOPMENT_TEAM`. Leave `CANOPY_BUNDLE_ID` alone unless `io.github.ddol.canopy` is
   registered to a different team.

The first signed build registers the bundle id with the Game Center capability and creates the signing
certificate and profiles automatically (`-allowProvisioningUpdates`).

## Straight from a Mac

1. Connect the iPhone with a cable, unlock it and tap **Trust**.
2. On the iPhone: Settings → Privacy & Security → **Developer Mode** → on, and restart when asked. (The switch
   only appears after the phone has been connected to Xcode once.)
3. Run:

   ```sh
   scripts/device.sh
   ```

   It builds a Debug build for the first paired iOS device, installs it and launches it. `DEVICE_ID=<udid>`
   picks a device (`xcrun devicectl list devices`); `CONFIGURATION=Release` builds Release. After the first
   time the phone can stay on the same Wi-Fi network instead of the cable.

### Reading what the app saved

The app's data lives in its container. Copy it to the Mac to inspect the database and the evidence GLBs:

```sh
xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
  --domain-identifier io.github.ddol.canopy --source "Library/Application Support/Canopy" --destination build/device-data
```

Blobs are named by their SHA-256 under `blobs/`; add `.glb` to open one in a glTF viewer.

## TestFlight

1. **Create the app record** (once). In [App Store Connect](https://appstoreconnect.apple.com) → Apps → + → New
   App: platform iOS, a name (it must be unique on the App Store, for example "Canopy Tree Census"; the name
   under the icon stays "Canopy"), bundle id `io.github.ddol.canopy` (it is in the list after the first signed
   build, or register it under Certificates, Identifiers & Profiles), and any SKU such as `canopy-ios`.
2. **Upload a build:**

   ```sh
   scripts/testflight.sh
   ```

   It archives a Release build numbered from the current UTC time (for example `20261021.1507`, so every upload
   is newer than the last) and uploads it. `UPLOAD=0` stops after exporting an `.ipa`.
3. **Add testers.** After processing (usually 5 to 30 minutes), the build appears under TestFlight. Internal
   testers (people on your App Store Connect team) can install it straight away; external testers need a short
   beta review first.

TestFlight builds keep the **testing tools**: Share GLB and Preview in Quick Look after a measurement, and
Simulate trusted approval and Reset local data on the Me tab. Build with `TESTING_TOOLS=0` to leave them out,
as an App Store build would.

Game Center works in TestFlight once the app record exists (testers sign in with their normal Game Center
account, against the sandbox). Before that, the app falls back to a local player id.

To upload without an Xcode account (for example from CI), create an App Store Connect API key (Users and Access
→ Integrations) and set `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID`.

## What to check on the phone

The Milestone 0 walkthrough:

| Tab | Check |
|---|---|
| Map | The park outline and 200 synthetic candidates show; the summary bar reads 0 · 200 · 0 %. Tap a tree: the sheet shows its height and S2 ids. |
| Census | The camera view shows the LiDAR mesh overlay. Near a candidate (in the park), Confirm tree makes it Proposed. Aim the reticle at a trunk about 1.37 m up and tap **Scan trunk**, then walk slowly round it: the captured mesh fills in lime and the card shows how much of the circumference is covered. At “Good coverage”, tap **Finish scan**: the sheet shows the diameter 1.37 m above the ground with ± and the lean. Save, then Share GLB and Preview in Quick Look (close it with Done). Away from the park there is no candidate within 60 m, so Save adds the measurement as a new tree. |
| Tag | From a tree's sheet, Tag a limb hazard. Place limb point in 3D on a branch within 5 m, pick the hazard details and Save: the tag shows as Proposed. |
| Me | The pending changes are listed. Sync now submits them; Simulate trusted approval puts them on the map. |

Location needs to be allowed for the Census and Tag tabs; the camera permission is only for ARKit (no photos are
taken).

## Reaching services on a tailnet

If a test build talks to a server on a Tailscale tailnet (for example a LiDAR data service), the phone needs the
Tailscale app signed in to the same tailnet. iOS blocks plain `http://` to non-local hosts, so serve it over
HTTPS (`tailscale serve` on the server gives it a valid `*.ts.net` certificate) rather than adding an App
Transport Security exception.
