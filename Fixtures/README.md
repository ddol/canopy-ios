# Fixtures

Sample data for development and tests. The app bundles `ggp/` and loads it on first launch.

| File | What it is | Made by |
|---|---|---|
| `ggp/park-boundary.geojson` | An **approximate** outline of Golden Gate Park, hand-traced from the bounding streets (Fulton, Stanyan, Lincoln, the Great Highway) and the Panhandle (Fell, Oak, Baker). Good to about 50 m; not an official boundary. | `scripts/make-fixtures.swift` |
| `ggp/tree-candidates.geojson` | 200 **synthetic** aerial tree candidates. Made-up data, not real trees: points scattered in groves inside the outline, avoiding a few open areas, with random heights, crown radii and confidences. Every feature has `"synthetic": true`. | `scripts/make-fixtures.swift` (seeded, so the output is always the same) |
| `ggp/s2-cells.geojson` | Six Gerardus tiles (S2 level 16) and one chunk (level 19) around park landmarks, with corners computed by Google's S2 library. The app's unit tests check `S2CellID` against them. | `scripts/s2-reference` (Go, `go run . cells`) |

Regenerate from the repository root:

```sh
swift scripts/make-fixtures.swift
(cd scripts/s2-reference && go run . cells > ../../Fixtures/ggp/s2-cells.geojson)
```

All files are GeoJSON (RFC 7946): WGS 84, longitude before latitude, exterior rings counter-clockwise.
