# What Brain wires for Notch Island 0.3.0

The helper is a display. Brain keeps the mail, the ledger, the money, and the microphone. Nothing in this process sends, books, or pays. A tap comes back as an `action` line. Brain runs that through the same approve path as a tap in the window (`lib/actions.ts`, `lib/trust.ts`).

Spawn the re-signed `NotchIsland` binary, write one JSON object per line to its stdin, and read one JSON object per line from its stdout. On `ready`, check `caps` before using a 0.3.0 field. Ping on an interval and restart the child if `pong` is late, then send the current view again.

The binary in a GitHub release is unsigned. Brain checks the sha256, signs it with the Brain certificate, and spawns that copy. This repo does not tag or publish the release. Tagging `v0.3.0` on `main` is what attaches `NotchIsland-arm64` and `NotchIsland-arm64.sha256`.

Coordinates on `ready` and `screen` are AppKit points. The origin is the bottom left of the global desktop (`origin` is `appkit-bottom-left`). Electron's origin is the top left of a display. Convert with that display's `displayFrame`:

```
electronX = frame.x - displayFrame.x
electronY = displayFrame.h - (frame.y - displayFrame.y) - frame.h
```

`scale` is the backing scale. `display` is the `NSScreen` number.

## Morning

On `ready`, push the three moves:

```json
{"t":"view","view":{"mode":"moves","open":true,"badge":3,"peek":"3 moves","glyph":"plan","moves":[
  {"id":"m1","title":"Send the one-pager","sub":"LabTested","kind":"email"},
  {"id":"m2","title":"Confirm the Zelle","sub":"Pacific Interlude","kind":"money"},
  {"id":"m3","title":"Buyer call","sub":"in 40 min","kind":"meet"}
]}}
```

Leave `peek` as `Clear` and omit `badge` when the list is empty. A dollar amount in a title, subtitle, peek, or wing `word` is stripped before it is drawn. Do not put a revenue total in those fields anyway.

A tap on a row is `{"ev":"action","id":"open","ask":"m1"}`. Open that card. Do not send because the row was tapped.

## Approve, join, confirm

Send, text, and Zelle confirm are the existing ask card. Set `open` to true. Omit `always` when the tap sends, books, or marks money.

```json
{"t":"view","view":{"mode":"ask","open":true,"glyph":"money","word":"Paid?","ask":{"id":"zelle:184","question":"Zelle matches invoice 184. Mark it paid?","allow":"Mark paid","deny":"Not this one"}}}
```

The question may contain the one invoice figure. The wing word should not. `{"ev":"action","id":"allow","ask":"zelle:184"}` is the tap. Brain marks the invoice. Brain does not send a payment.

```json
{"t":"view","view":{"mode":"meeting","open":true,"glyph":"meet","meeting":{"id":"cal:9","title":"Buyer call","when":"Soon","startsAt":1730550000000,"brief":"Austin's deal. You owe the one-pager.","join":true}}}
```

The wing counts down from `startsAt`. Join is `{"ev":"action","id":"join","ask":"cal:9"}`. Brain opens that meeting. Brain does not create one. Keep revenue figures out of `brief`. The helper also strips `$` amounts from the brief.

If `keys` is set (`⌃⌥Y · ⌃⌥N`), the helper registers those chords only while the card is showing and releases them when it closes. The button is still the approve path.

## Shelf

```json
{"t":"shelfDir","path":"/Users/arnie/Library/Application Support/Brain/shelf"}
```

Until that line arrives, the helper uses the same default path. On `ready`, send `shelf` with the chips you still know about. Paths outside the directory are ignored, so a linked chip (a big file or a folder) is not restored after a restart.

The folder must be a dedicated one. The disk root, `/Users`, the home folder, and any folder directly inside it (Desktop, Documents, Downloads, Library) are refused and the previous folder stays. A copy always gets a fresh name (`PO 2.pdf`), so nothing already in the folder is replaced. Deleting a chip deletes only the shelf's own copy, never a linked original. Copies run off the main thread. A drag out never replaces a file at the drop target either.

A drop emits `shelf` `op` `add`. Since 0.3.1 a drop shows the file's thumbnail and no longer opens capture by itself; a click on the thumbnail does (and emits `capture` `op` `open` with `shelf`). Dragging a chip out emits `dragged` and leaves the chip. `remove` means he deleted the chip. A file over about 2 GB, or a folder, is linked (`linked: true`) instead of copied.

He can type or speak a sentence about the file. That is a `capture` `submit` with `shelf` set to the chip id. Prepare the action and answer with an ask card. Do not send, and do not move the file into a business folder, until Allow.

## Capture

The shortcut Brain registers with Electron `globalShortcut` sends a capture view with `open: true`. That focuses the field. Hover does not.

```json
{"t":"view","view":{"mode":"capture","open":true,"capture":{"id":"c1","prompt":"Note, to-do, or reminder","shelf":null}}}
```

Speech stays in Brain. On `{"ev":"capture","op":"speech","on":true}` start the on-device recognizer. Stream partials with `captureText`. On `on: false`, stop. The helper has no microphone permission and should not get one.

`submit` is the sentence. A reminder, note, or promise is written to the ledger and the to-dos. An outbound act becomes an ask card. `cancel` writes nothing. Do not put the sentence into an outbound prompt unless he is approving that reply, and keep revenue figures out of those prompts.

While the field is first responder, a new view is held and shown after submit or cancel.

## Progress

```json
{"t":"watch","dirs":["/Users/arnie/Downloads","/Users/arnie/Movies/Exports","/Users/arnie/Library/CloudStorage/GoogleDrive/My Drive"]}
```

An empty list watches Downloads. The helper does not watch Mail or Messages. It does not read file contents.

`progress` lines are transitions. `total` is null when the length is unknown, and the bar is then indeterminate. Final Cut and Premiere usually do not publish a fraction. `kind` `drive` with `state` `done` means the local copy settled, not that Google has the file.

`{"ev":"action","id":"reveal","ask":"p1","path":"..."}` means he asked Finder to show the file. The helper also calls `NSWorkspace.activateFileViewerSelecting`. Reveal does not upload or send.

A done ping waits until an open approve card or the capture field closes.

## Rules that stay in Brain

- Map `allow` / `deny` / `join` / `open` through the existing approve gate. Do not add a path that sends because the notch said so.
- Omit `always` on send, book, and pay.
- Re-sign the pinned binary. Do not grant the helper Accessibility, Full Disk Access, the microphone, or App Sandbox.
- The panel is above the menu bar. For a sized tray, put Brain's window under the helper, in the body rect from `frame`, and fade it in on `settled`. Clicks in that body pass through the helper.
