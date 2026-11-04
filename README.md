# notch-island

A tiny, dependency-free macOS helper that draws a "dynamic island" around the MacBook notch and is driven by
another process over JSON lines on stdin/stdout. It is meant to be embedded in a host app (for example an Electron
app) that wants a native-feeling notch surface without writing AppKit itself.

- A borderless, non-activating `NSPanel` at `mainMenu + 3`, on every Space and over full-screen apps, stationary in
  Mission Control, out of the window cycle. It stays out of the key window, except while the capture field is open,
  and then it gives focus back.
- Anchored to the real notch (`safeAreaInsets`, `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`); re-anchored on
  display, Space and wake changes. No notch: a slim pill at the top centre.
- One black `CAShapeLayer` that morphs between states with `CASpringAnimation` at the display's refresh rate.
  Content is SwiftUI, masked by the same animated shape.
- Hover: rest about 0.3 s on the notch to open; a fast fly-by never opens it. Clicks outside the shape pass through.
- States: compact pill (glyph + elapsed time), two-line activity view, Allow / Deny / Always, upcoming meeting with
  Join, morning moves, a one-line capture field, a file shelf, transfer progress, and a tray edge for a host panel.
- v0.2.0: `{"t":"tray","open":true,"w":…,"h":…}` makes the black shape the host's tray itself. Hovering a resting
  notch peeks. `ready` reports `caps` and `version`.
- v0.3.2: at rest the island is the bare notch. Wings (56 pt each, was 64) appear only for something live: a transfer
  (and its 6 s done), Brain working or asking, a meeting countdown, the moves while the host holds them `open` (the
  daily intro). A `badge`, parked files, and the moves outside their intro no longer widen it; the moves show in the
  hovered body. Every drawn piece takes clicks (the strip across the top of a sized tray, its wings, the shelf band);
  only the host's tray body passes clicks to the host's window. The shelf band ("Shelf · N files", Show in Finder,
  thumbnails with the name under, × on hover, drag out) sits at the top of the open rest / moves / deck body, and
  under a sized tray. A drop opens it for 2.5 s. The canvas is 580 pt tall (was 480); `trayMaxH` stays 400.
- v0.3.1: only a file that grows after the helper starts is a transfer (files already there, and Finder moves or
  renames, are a silent baseline). The wing shows a finished transfer for 6 s; the open tray keeps it 2 minutes. The list is
  published only when it changes, and the 1 s tick stops when nothing is active. Shelf chips are thumbnails (Quick Look).
  A finished transfer opens the body for 4 s at most; a drop holds it open 2.5 s. The moves body shows only the moves.
- v0.3.0: three morning moves with a count, a meeting countdown (`startsAt`) whose Join action carries the meeting id,
  a file shelf (drag in, drag a copy back out), quick capture, and live progress for exports, downloads, Drive copies,
  and incoming AirDrop with Reveal in Finder. A repeated view with the same shape does not restart the spring.
  `ready` and `screen` include the panel frame. An opening spring emits `settled`. Currency amounts are stripped from
  the wings, the peek, move rows, and the meeting brief. The open approve question is left as the host wrote it.
  See `BRAIN.md` for what the host has to wire.

## Protocol

Host → helper, one JSON object per line:

```json
{"t":"view","view":{"mode":"deck","glyph":"read","last":"Read data.csv","now":"Writing the summary","startedAt":1730550000000}}
{"t":"view","view":{"mode":"ask","open":true,"ask":{"id":"42","question":"Send the one-pager to Forest?","allow":"Send","deny":"Not now","preview":"Here is the one-pager."}}}
{"t":"view","view":{"mode":"meeting","open":true,"meeting":{"id":"cal:1","title":"Buyer call","when":"Soon","startsAt":1730550000000,"brief":"You owe the one-pager.","join":true}}}
{"t":"view","view":{"mode":"moves","open":true,"badge":3,"peek":"3 moves","moves":[{"id":"m1","title":"Send the one-pager","sub":"LabTested","kind":"email"}]}}
{"t":"view","view":{"mode":"capture","open":true,"capture":{"id":"c1","prompt":"Note, to-do, or reminder","text":"","shelf":null}}}
{"t":"captureText","id":"c1","text":"remind me to send Forest","partial":true}
{"t":"shelfDir","path":"/Users/arnie/Library/Application Support/Brain/shelf"}
{"t":"shelf","items":[{"id":"s1","name":"PO.pdf","path":"/Users/arnie/Library/Application Support/Brain/shelf/PO.pdf","bytes":180000}]}
{"t":"watch","dirs":["/Users/arnie/Downloads","/Users/arnie/Movies/Exports"]}
{"t":"view","view":{"mode":"rest"}}
{"t":"tray","open":true}
{"t":"tray","open":true,"w":520,"h":236}
{"t":"tray","open":false}
{"t":"ping"}
{"t":"quit"}
```

Helper → host:

| Event | When |
| --- | --- |
| `ready` | Once. `v` is 1. `version` is `0.3.2`. `caps` lists what this build can do. `frame`, `display`, `scale`, `displayFrame`, and `origin` (`appkit-bottom-left`) locate the panel. |
| `screen` | The panel moved. Same frame fields as `ready`. |
| `settled` | An opening spring finished. `w` and `h` are the island size in points. Fade a host tray in on this, not on a timer. |
| `hover` / `leave` / `click` | The cursor rested, left, or clicked the body (not a button). |
| `action` | `allow`, `deny`, `always`, `join`, `open` (a morning move), `reveal`. `ask` is the card, meeting, move, or transfer id. |
| `shelf` | `op` is `add`, `remove`, `dragged`, or `missing`. A drag out copies. The chip stays. |
| `capture` | `op` is `open`, `submit`, `speech`, or `cancel`. `speech` carries `on`. `submit` carries `text` and, for a parked file, `shelf`. |
| `progress` | `state` is `active`, `done`, or `missing`. `kind` is `export`, `download`, `drive`, or `airdrop`. `total` is JSON null when the size is unknown. The bar ticks locally. These lines are the transitions. |
| `pong` | Answer to `ping`. |

`ready.caps` for 0.3.0: `traySize`, `peek`, `peekText`, `countdown`, `screenFrame`, `settled`, `moves`, `shelf`, `capture`, `progress`.

An unknown `mode` is drawn as a deck that says it cannot show that mode. It does not pretend nothing is running.

Closing stdin makes the helper exit. Field list: `Sources/IslandCore/Protocol.swift`. What Brain still has to do: `BRAIN.md`.

A sized tray draws the black body, and clicks in that body pass through this window so the host window stacked underneath can take them. Place that window with `frame` (AppKit points, bottom-left origin) and wait for `settled`.

The `keys` caption on an ask card is registered as a system hotkey only while that card is open, then released. Allow is still the button. A send, a booking, and a payment are the host's tap. This process does not perform them.

## Build

```sh
swift test
swift build -c release --arch arm64
```

Tagging `v*` builds on GitHub Actions (`macos-latest`) and attaches `NotchIsland-arm64` and its sha256 to a release.
The binary is unsigned; the host app signs it when bundling.

## License

MIT
