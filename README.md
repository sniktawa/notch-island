# notch-island

A tiny, dependency-free macOS helper that draws a "dynamic island" around the MacBook notch and is driven by
another process over JSON lines on stdin/stdout. It is meant to be embedded in a host app (for example an Electron
app) that wants a native-feeling notch surface without writing AppKit itself.

- A borderless, non-activating `NSPanel` at `mainMenu + 3`, on every Space and over full-screen apps, stationary in
  Mission Control, out of the window cycle. It never becomes key, so the user's app keeps focus.
- Anchored to the real notch (`safeAreaInsets`, `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`); re-anchored on
  display, Space and wake changes. No notch: a slim pill at the top centre.
- One black `CAShapeLayer` that morphs between states with `CASpringAnimation` at the display's refresh rate.
  Content is SwiftUI, masked by the same animated shape.
- Hover: rest about 0.3 s on the notch to open; a fast fly-by never opens it. Clicks outside the shape pass through.
- States: compact pill (glyph + elapsed time), two-line activity view, Allow / Deny / Always, upcoming meeting with
  Join, and a flat "tray" edge for a host panel that opens below.

## Protocol

Host → helper, one JSON object per line:

```json
{"t":"view","view":{"mode":"deck","glyph":"read","last":"Read data.csv","now":"Writing the summary","startedAt":1730550000000}}
{"t":"view","view":{"mode":"ask","open":true,"ask":{"id":"42","question":"Move 3 files to the Trash?","allow":"Move to Trash","deny":"Cancel","always":"Always"}}}
{"t":"view","view":{"mode":"meeting","meeting":{"title":"Design review","when":"Starts in 4 min","join":true}}}
{"t":"view","view":{"mode":"rest"}}
{"t":"tray","open":true}
{"t":"ping"}
{"t":"quit"}
```

Helper → host: `ready`, `screen`, `hover`, `leave`, `click`, `action` (`allow` / `deny` / `always` / `join`),
`pong`. Closing stdin makes the helper exit. Full field list: `Sources/IslandCore/Protocol.swift`.

## Build

```sh
swift test
swift build -c release --arch arm64
```

Tagging `v*` builds on GitHub Actions (`macos-latest`) and attaches `NotchIsland-arm64` and its sha256 to a release.
The binary is unsigned; the host app signs it when bundling.

## License

MIT
