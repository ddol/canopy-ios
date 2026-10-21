# Design tokens

The Canopy design system's tokens live in `Packages/CanopyDesign`. Use them instead of literal colours, fonts
or sizes.

## Colour

Every colour has a light and a dark value. `ColorToken.uiColor` resolves the right one from the trait
collection, and `ColorToken.color` wraps it for SwiftUI. The common ones are also on `Color`, for example
`Color.canopyBrand`.

| Token | Light | Dark | Use |
|---|---|---|---|
| `surface-100` | `#f4f6f1` | `#0f1512` | App background (`Color.canopySurface`) |
| `surface-000` | `#ffffff` | `#18211c` | Cards and sheets (`Color.canopyCard`) |
| `surface-200` | `#e6ebe2` | `#222d27` | Sunken areas, wells (`Color.canopySunken`) |
| `ink` | `#14201a` | `#eef3ec` | Text and icons |
| `ink-muted` | `#4d5a51` | `#a9b6ad` | Secondary text |
| `line` | `#d3dacd` | `#2a352f` | Hairlines and borders |
| `line-strong` | `#7d8a76` | `#6b7a70` | Strong borders, secondary button outline |
| `brand` | `#1e5d1b` | `#6fbf7f` | Brand green, primary buttons |
| `on-brand` | `#ffffff` | `#0f1512` | Text on `brand` |
| `canopy` | `#9bd14b` | `#b6e36a` | Lime accent, **only with `ink` text on it** |
| `survey` | `#f08a24` | `#ff9d4d` | "Needs a person" and the record button, with `ink` text |

### Status

A status is **always an icon, a word and a colour**, never colour alone. `StatusBadge` enforces this: it takes
all three.

| Tone | Foreground (light / dark) | Tint (light / dark) | Used for |
|---|---|---|---|
| `ok` | brand `#1e5d1b` / `#6fbf7f` | `#e1efe3` / `#1a3322` | Confirmed, verified, synced |
| `proposed` | `#a34a00` / `#ff9d4d` | `#fde9d6` / `#3a2512` | Waiting for agreement |
| `moved` | `#1f5fbf` / `#7fb2ff` | `#e2ecfb` / `#172a45` | Position changed, detected (information) |
| `watch` | `#7d5800` / `#e6b84a` | `#f7eccc` / `#33290f` | Moderate urgency, conflicts |
| `hazard` | `#b3261e` / `#ff8a7f` | `#fbe4e1` / `#3a1b18` | High urgency, rejected, removed |

## Type

| Role | Font | API |
|---|---|---|
| Titles | **DM Sans** (bundled, SIL OFL 1.1), scaled with Dynamic Type | `CanopyFont.largeTitle`, `.title1`, `.title2`, `.title3`, `CanopyFont.title(_:relativeTo:weight:)` |
| Body | System (SF Pro) with Dynamic Type | `.font(.body)` and the other text styles |
| Numbers, measurements, ids | SF Mono with tabular figures | `CanopyFont.mono(_:weight:)` |

DM Sans is a variable font. `CanopyFont.register()` registers it with Core Text for the process; the app calls
it at launch, and the title helpers call it too. Core Text names the font's weight instances
`DMSans-9ptRegular_<Weight>` (after the default optical size), and the tests check that these resolve.

## Spacing and radius

| Spacing | `xxs` | `xs` | `s` | `m` | `l` | `xl` | `xxl` |
|---|---|---|---|---|---|---|---|
| Points | 4 | 8 | 12 | 16 | 24 | 32 | 48 |

| Radius | `small` | `medium` | `large` | pill |
|---|---|---|---|---|
| Points | 6 | 10 | 16 | `Capsule()` |

## Units

`QuantityFormat` formats SI quantities. A value and its unit are joined by U+202F NARROW NO-BREAK SPACE, so they
never wrap apart, and the same space surrounds `±`:

| Call | Output |
|---|---|
| `length(0.42)` | `0.42 m` |
| `length(0.4213, uncertainty: 0.012)` | `0.42 ± 0.02 m` (uncertainty rounded up, never shown as zero) |
| `length(0.4213, uncertainty: 0.004)` | `0.421 ± 0.004 m` (one more decimal to show the uncertainty) |
| `angle(4.52, uncertainty: 0.5)` | `4.5 ± 0.5°` (no space before the degree sign) |
| `percent(0.083)` | `8 %` |
| `count(12345)` | `12 345` (groups of three from five digits) |

The decimal separator follows the user's locale.

## Components

- `StatusBadge(_:systemImage:tone:)`: icon, word and tone in a tinted capsule.
- `SummaryBar([Item])`: a row of labelled numbers in SF Mono, such as the map's Confirmed · Estimated · Coverage.
- `CanopyButtonStyle`: `.canopyPrimary` (brand), `.canopySecondary` (outlined card), `.canopySurvey` (orange,
  ink text, for the record button and "needs a person" actions). Minimum height 44 pt.
- `.canopyCard()`: the card surface with hairline border and large radius.
