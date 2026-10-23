# S2 reference vectors

`S2Vectors.swift` holds reference values for `S2CellIDTests`, generated with Google's Go port of S2
([github.com/golang/geo](https://github.com/golang/geo), Apache-2.0) by the small tool in
[`scripts/s2-reference`](../../../../scripts/s2-reference). Go is only needed to regenerate the vectors; it is
not part of the build.

For each point the tool records the face, the leaf cell id, the canonical tokens of its L16 tile and L19 chunk
(`l16Token`, `l19Token`), and the L16 tile's centre and four corners. Family displays are Canopy's own
presentation and are tested separately, in `S2FamilyDisplayTests`, against the examples in velocity.report's
S2 style guide. To regenerate:

```sh
cd scripts/s2-reference
go run . vectors > ../../Packages/CanopyModel/Tests/CanopyModelTests/S2Vectors.swift
```
