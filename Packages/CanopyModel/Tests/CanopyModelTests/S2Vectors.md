# S2 reference vectors

`S2Vectors.swift` holds reference values for `S2CellIDTests`, generated with Google's Go port of S2
([github.com/golang/geo](https://github.com/golang/geo), Apache-2.0), module version
`v0.0.0-20260928092222-7d12f68cfadb`. Go and golang/geo are only needed to regenerate the vectors; they are
not part of the build.

For each point the generator records the face, the leaf cell id, the level-16 and level-19 tokens, and the
level-16 cell's centre and four corners.

To regenerate:

```sh
mkdir s2gen && cd s2gen
go mod init s2gen
go get github.com/golang/geo/s2@v0.0.0-20260928092222-7d12f68cfadb
# save the program below as main.go
go run . > S2Vectors.swift
```

Then copy `S2Vectors.swift` here, keeping the header comment.

```go
// Generates S2 reference vectors for Canopy's CanopyModel tests using github.com/golang/geo/s2.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/golang/geo/s2"
)

type point struct {
	name     string
	lat, lng float64
}

var points = []point{
	{"Conservatory of Flowers", 37.7720, -122.4602},
	{"de Young Museum", 37.7715, -122.4687},
	{"Stow Lake", 37.7699, -122.4757},
	{"Spreckels Lake", 37.7706, -122.4945},
	{"Dutch Windmill", 37.7704, -122.5090},
	{"Panhandle at Masonic", 37.7718, -122.4462},
	{"Polo Field", 37.7680, -122.4930},
	{"McLaren Lodge", 37.7718, -122.4545},
	{"San Francisco City Hall", 37.7793, -122.4193},
	{"Origin", 0, 0},
	{"Equator 90E", 0, 90},
	{"Equator 180", 0, 180},
	{"Equator 90W", 0, -90},
	{"North Pole", 90, 0},
	{"South Pole", -90, 0},
	{"45N 45E", 45, 45},
	{"Greenwich", 51.4779, -0.0015},
	{"Sydney", -33.8688, 151.2093},
	{"Tokyo", 35.6762, 139.6503},
	{"Ushuaia", -54.8019, -68.3030},
	{"Reykjavik", 64.1466, -21.9426},
	{"New York", 40.7128, -74.0060},
	{"Antimeridian south", -16.5, -179.99},
}

func ll(p s2.Point) string {
	l := s2.LatLngFromPoint(p)
	return fmt.Sprintf("(%.15f, %.15f)", l.Lat.Degrees(), l.Lng.Degrees())
}

func main() {
	out := os.Stdout
	fmt.Fprintln(out, "// Generated from github.com/golang/geo/s2 as described in S2Vectors.md. Do not edit by hand.")
	fmt.Fprintln(out, "// swift-format-ignore-file")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "struct S2Vector {")
	fmt.Fprintln(out, "    let name: String")
	fmt.Fprintln(out, "    let lat: Double")
	fmt.Fprintln(out, "    let lng: Double")
	fmt.Fprintln(out, "    let face: Int")
	fmt.Fprintln(out, "    let leafID: UInt64")
	fmt.Fprintln(out, "    let token16: String")
	fmt.Fprintln(out, "    let token19: String")
	fmt.Fprintln(out, "    let center16: (lat: Double, lng: Double)")
	fmt.Fprintln(out, "    let vertices16: [(lat: Double, lng: Double)]")
	fmt.Fprintln(out, "}")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "let s2Vectors: [S2Vector] = [")
	for _, p := range points {
		id := s2.CellIDFromLatLng(s2.LatLngFromDegrees(p.lat, p.lng))
		c16 := s2.CellFromCellID(id.Parent(16))
		fmt.Fprintf(out, "    S2Vector(\n")
		fmt.Fprintf(out, "        name: %q, lat: %v, lng: %v, face: %d,\n", p.name, jsonNum(p.lat), jsonNum(p.lng), id.Face())
		fmt.Fprintf(out, "        leafID: 0x%016x, token16: %q, token19: %q,\n", uint64(id), id.Parent(16).ToToken(), id.Parent(19).ToToken())
		fmt.Fprintf(out, "        center16: %s,\n", ll(c16.Center()))
		fmt.Fprintf(out, "        vertices16: [%s, %s, %s, %s]\n", ll(c16.Vertex(0)), ll(c16.Vertex(1)), ll(c16.Vertex(2)), ll(c16.Vertex(3)))
		fmt.Fprintf(out, "    ),\n")
	}
	fmt.Fprintln(out, "]")
}

func jsonNum(f float64) string {
	b, _ := json.Marshal(f)
	s := string(b)
	return s
}
```
