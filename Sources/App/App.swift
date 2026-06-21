// App — the SwiftUI viewer/controller over the shared GRDB store (SPEC §3).
//
// Presentation logic lives in `@Observable` view models (testable, no SwiftUI);
// the SwiftUI views are thin renderings. The map (MapKit), charts (Swift Charts),
// and observability dashboard build out on this pattern.
//
//   • NodeListViewModel / NodeListView — the node list (this commit).
