# S2 reference vectors

`S2Vectors.swift` holds reference values for `S2CellIDTests`, generated with Google's Go port of S2
([github.com/golang/geo](https://github.com/golang/geo), Apache-2.0) by the small tool in
[`scripts/s2-reference`](../../../../scripts/s2-reference). Go is only needed to regenerate the vectors; it is
not part of the build.

For each point the tool records the face, the leaf cell id, the level-16 and level-19 tokens, and the level-16
cell's centre and four corners. To regenerate:

```sh
cd scripts/s2-reference
go run . vectors > ../../Packages/CanopyModel/Tests/CanopyModelTests/S2Vectors.swift
```
