# Testing on a device

LiDAR capture (the Census AR view, Scan trunk, 3D limb points) only works on an iPhone or iPad Pro with
LiDAR; no simulator can reconstruct a mesh. Everything else is covered by `scripts/test.sh` on the simulator.

There are three ways to get Canopy onto a phone:

- **Straight from a Mac** (`scripts/device.sh`): the fastest loop while developing. The phone is paired with the
  Mac.
- **TestFlight** (`make testflight`): for testers in the park. They install from the TestFlight app; no Mac
  needed.
- **The App Store** (`make appstore`, then App Review): for everyone.

All of them need a paid Apple Developer Program team. `make` on its own lists the shortcuts.

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
2. **Set the version** when a release needs a new one. The version lives in `Configs/Version.xcconfig`;
   `make bump-version` moves it on by one (`0.1.0` → `0.1.1`, `0.2.13` → `0.2.14`, and a pre-release
   `0.1.1-pre2` → `0.1.1-pre3`), and `make version` prints it. App Store Connect accepts only numbers, so a
   pre-release uploads under its release number (`0.1.1-pre3` as `0.1.1`); the Me tab shows the full version.
3. **Upload a build:**

   ```sh
   make testflight
   ```

   It runs `scripts/testflight.sh`, which archives a Release build numbered from the current UTC time (for example `20261021.1507`, so every upload
   is newer than the last) and uploads it. `UPLOAD=0` stops after exporting an `.ipa`.
4. **Add testers.** After processing (usually 5 to 30 minutes), the build appears under TestFlight. Internal
   testers (people on your App Store Connect team) can install it straight away; external testers need a short
   beta review first.

TestFlight builds keep the **testing tools**: Share GLB and Preview in Quick Look after a measurement, and
Simulate trusted approval and Reset local data on the Me tab. Build with `TESTING_TOOLS=0` to leave them out,
as an App Store build would.

Game Center works in TestFlight once the app record exists (testers sign in with their normal Game Center
account, against the sandbox). Before that, the app falls back to a local player id.

To upload without an Xcode account (for example from CI), create an App Store Connect API key (Users and Access
→ Integrations) and set `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID`.

## The App Store

A build for the App Store is the same upload as a TestFlight one, without the testing tools. App Review then
checks it before it goes on sale.

1. **Merge what you want to ship to `main`** and let CI pass. The version in `Configs/Version.xcconfig` must be a
   release (`0.2.0`, not `0.2.0-pre3`) and newer than the last version on the App Store. App Store Connect takes
   no new builds for a version it has already released, so run `make bump-version` after each release.
2. **Upload the build** from an up-to-date `main`:

   ```sh
   git switch main && git pull
   make appstore
   ```

   `scripts/appstore.sh` refuses a pre-release version, local changes, or a commit that is not on `origin/main`,
   so the build is exactly what CI tested. Then it runs `scripts/testflight.sh` with `TESTING_TOOLS=0`. The build
   also shows up under TestFlight, so you can try it before submitting. `UPLOAD=0 make appstore` stops after
   exporting the `.ipa`.
3. **Fill in the listing** (the first time, and when it changes). In App Store Connect → Canopy:
   - **App Information:** category (Education), age rating questionnaire, content rights.
   - **Pricing and Availability:** free, and which countries.
   - **App Privacy:** the privacy policy URL (`PRIVACY.md` on GitHub works). Answer the data questions the same
     way as `App/Resources/PrivacyInfo.xcprivacy`: precise location and other data types, used for app
     functionality, not linked to the player, and no tracking.
   - **The version page:** screenshots for a 6.9-inch iPhone and a 13-inch iPad (the app is universal),
     description, keywords, support URL, and *What's New* for updates.
   - **App Review Information:** a contact, and notes for the reviewer: LiDAR features need a Pro device, the map
     and tagging work on any device, and no Gerardus server or sign-in is needed to try the app.

   Export compliance is already answered in the build (`ITSAppUsesNonExemptEncryption` is `NO`).
4. **Submit.** On the version page, under Build, choose the build `make appstore` uploaded (after processing,
   usually 5 to 30 minutes), then **Add for Review** and **Submit for Review**. Review usually takes a day or two.
5. **Release.** Choose on the version page whether an approved version goes on sale automatically or when you
   press Release.

Submitting is done by hand in App Store Connect for now. The App Store Connect API could automate it later with
the same API key, once the listing exists.

## What to check on the phone

The Milestone 0 walkthrough:

| Tab | Check |
|---|---|
| Map | The park outline and 200 synthetic candidates show; the summary bar reads 0 · 200 · 0 %. Tap a tree: the sheet shows its height and its S2 L16 tile and L19 chunk in family display (`80858-745b`). |
| Census | The camera view shows the LiDAR mesh overlay. Near a candidate (in the park), Confirm tree makes it Proposed. Aim the reticle at a trunk about 1.37 m up and tap **Scan trunk**, then walk slowly round it: the captured mesh fills in lime and the card shows how much of the circumference is covered. At “Good coverage”, tap **Finish scan**: the sheet shows the diameter 1.37 m above the ground with ± and the lean. Save, then Share GLB and Preview in Quick Look (close it with Done). Away from the park there is no candidate within 60 m, so Save adds the measurement as a new tree. |
| Tag | From a tree's sheet, Tag a limb hazard. Place limb point in 3D on a branch within 5 m, pick the hazard details and Save: the tag shows as Proposed. |
| Me | The pending changes are listed. Sync now submits them; Simulate trusted approval puts them on the map. |

Location needs to be allowed for the Census and Tag tabs; the camera permission is only for ARKit (no photos are
taken).

## Pointing the app at a Gerardus server

Set the server in **Me → Settings** (the gear, or the Gerardus server row under Sync): a host and port such as
`gerardus.local:50061`, or a full `http://` or `https://` address without a path. Without a scheme the app uses
`http://` and, without a port, Gerardus's 50061. **Test connection** reads the server's status page (`GET /`)
and shows its version, commit, API version, uptime, start time, round trip, whether it accepts scans and its
reference layers.

App Transport Security (`App/Info.plist`) allows plain `http://` only to local names (`.local`, unqualified),
IP addresses and Tailscale hosts (`*.ts.net`); any other host needs HTTPS. For a server on a tailnet, the phone
needs the Tailscale app signed in to the same tailnet; a name it can't find usually means Tailscale is off.
The first connection to a server on the local network asks for Local Network access.
