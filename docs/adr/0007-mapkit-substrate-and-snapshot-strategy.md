# ADR 0007 — MapKit substrate + Canvas trace overlay (snapshot strategy)

- Status: accepted
- Date: 2026-06-20

## Context
The Phase 6 visualization animates packet traces on an abstract `Canvas`
(`GeoProjection` maps lat/lon into a rect). The product requires a **real MapKit
map** — geographic tiles, pan/zoom, clustering — as the substrate. But the project's
GUI fitness function is a headless `ImageRenderer` snapshot run (`MeshtrackSnapshot`),
and `MKMapView` needs tiles/GPU and **does not render** under `ImageRenderer` (cf.
the broader "stock controls render badly headless" finding). We cannot let the map
requirement break the deterministic snapshot gate.

## Decision
Split substrate from overlay:
- **Live app:** `MeshMapView` wraps `MKMapView` via `NSViewRepresentable` (dark
  style, clustering, fit-to-fleet, real `MKAnnotation` nodes). Packet traces, node
  glows, hop badges, and latency tooltips render in a **transparent SwiftUI `Canvas`
  overlay** positioned by a `MapProjection` adapter that calls
  `MKMapView.convert(_:toPointTo:)` — mirroring the existing `GeoProjection`
  interface so the drawing code is shared.
- **Snapshot / CI:** the Network section renders the existing Canvas-only map
  (`DashboardView`, `live: false`) — deterministic, already snapshot-clean.
- The trace geometry (edge progress, hop-normalised timing, relay guessing,
  per-id colour) is **pure and unit-tested** independent of MapKit. The `MKMapView`
  substrate is excluded from the coverage metric like other I/O adapters and is
  verified live (env-gated smoke / manual).

## Consequences
- The map requirement and the snapshot gate coexist: one drawing implementation, two
  coordinate sources.
- Animation correctness is provable in CI without a GPU; the geographic substrate is
  validated against a running app.
- Slight duplication risk between `GeoProjection` and `MapProjection` is contained by
  giving them the same `point(for:)` shape and testing the shared consumer.
