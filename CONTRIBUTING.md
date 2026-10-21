# Contributing to Canopy

Thanks for helping count the trees of Golden Gate Park. This guide covers how to set up, what we expect
from a change, and the few rules that are not negotiable.

## Setup

```sh
scripts/bootstrap.sh
open Canopy.xcodeproj
```

You need Xcode 26.3 or later. `bootstrap.sh` installs XcodeGen with Homebrew if it is missing and
generates `Canopy.xcodeproj` from `project.yml`. Never edit the `.xcodeproj` by hand; edit `project.yml`
and run the script again.

## Hard rules

These come from the project's goals. A pull request that breaks one will not be merged.

1. **No photos.** The app never stores or uploads camera images. Evidence is colourless mesh geometry,
   cropped to the subject. Do not read `ARFrame.capturedImage` into anything that outlives the frame.
2. **No identity beyond Game Center.** The only player identity in the data is the Game Center player id
   and alias. No device identifiers, no analytics, no advertising SDKs.
3. **Minimum dependencies.** Use Apple frameworks first. A new third-party dependency (runtime code,
   bundled asset, or tool) needs a written justification in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)
   in the same pull request.
4. **Metric units.** SI units everywhere, in code and in the UI. Use `CanopyDesign`'s formatters so a value
   and its unit are separated by a narrow no-break space ("0.42 m").
5. **Status is never colour alone.** Every status shows an icon, a word and a colour.
6. **Observations are append-only.** Never update or delete a row in the observation log. Current state is
   derived from it.

## Code style

- Swift 6 language mode with complete strict concurrency. Fix warnings; do not silence them.
- Format with the toolchain's `swift-format` and the repo's [`.swift-format`](.swift-format):

  ```sh
  swift format --in-place --recursive App Packages
  swift format lint --strict --recursive App Packages
  ```

  CI runs the lint step.
- Put logic in the packages and keep it testable without a device. Views in `App/` should be thin.
- Prefer value types. Types that cross concurrency domains must be `Sendable`.

## Tests

```sh
xcodebuild test -project Canopy.xcodeproj -scheme Canopy \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

The `Canopy` scheme runs the app's unit and UI tests and every package's tests. Unit tests use Swift
Testing (`import Testing`); UI tests use XCTest. New logic needs tests. Anything that needs a LiDAR device
should keep its maths in a pure function that can be tested on the simulator.

## Pull requests

- Keep each pull request small and focused, with a description of what changed and how you tested it.
- If you changed what is stored or synced, update [PRIVACY.md](PRIVACY.md) and
  [docs/DATA-MODEL.md](docs/DATA-MODEL.md).
- CI must pass.

## Licence

By contributing you agree that your contribution is licensed under the Apache License 2.0, the same licence
as the project (see [LICENSE](LICENSE)).
