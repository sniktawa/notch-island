# Notch Island for Brain

Analysis and design only. No application code was changed.

Notch Island at this commit is **v0.2.0** (`helperVersion` in `Sources/IslandCore/Protocol.swift`, tags `v0.1.0` and `v0.2.0`). It is a small macOS process that draws one black island under the camera housing and speaks JSON lines on stdin and stdout. Brain is the host that is supposed to spawn it.

`https://github.com/sniktawa/brain` was not readable from this environment (the API returns 404, and it is not among the public `sniktawa` repositories), so pull request 14’s diff was not opened. The host contract below is what this helper actually implements. Brain’s behavior is the 1.10.0 app as previously read at `09b475d`, plus the 1.11 surface you described: a ledger of people, deals, and promises; a money desk that matches Zelle; a three-move morning brief; voice learning; and an operator for jobs such as “chase every unpaid invoice,” “rebook Adam,” and “prep me for tomorrow,” each of them waiting for an approve tap.

Where a Brain path is named (`lib/actions.ts`, `lib/trust.ts`, `lib/polish/chief.ts`, and the others), it is that 1.10 surface. It is the place the notch should call. It is not a line checked out from PR 14.

---

## 1. How Notch Island works

### Stack

| Piece | What it is |
| --- | --- |
| Language | Swift 5.9, macOS 13 and later. `Package.swift` has no dependencies. |
| Pure core | `Sources/IslandCore`. Foundation only: the line protocol, notch geometry, the hover gate, elapsed-time text. This is what `swift test` covers. |
| App | `Sources/NotchIsland`. AppKit window, Core Animation shape, SwiftUI content. Not unit-tested. |
| UI | One `CAShapeLayer` filled black, masked SwiftUI on top. Springs via `CASpringAnimation` at the display’s refresh rate. |
| Distribution | A single arm64 executable, `NotchIsland-arm64`. No app bundle, no `Info.plist`, no entitlements file, no Dock icon. |

The process is an accessory app (`NSApplication` activation policy `.accessory` in `main.swift`). It ignores `SIGPIPE`, builds one panel, and runs the AppKit loop. Closing stdin, or a `{"t":"quit"}` line, terminates it.

### Architecture

One window, one model, one shape.

`IslandController` owns an `NSPanel` subclass that cannot become key or main, so a click never pulls focus out of the app Arnie is in. The panel is borderless and non-activating, floating, opaque-clear, without a shadow, and stuck out of the window cycle. Its level is the menu-bar level plus 3 (`NSWindow.Level.mainMenu + 3`). Its collection behavior is join-all-spaces, stationary in Mission Control, full-screen auxiliary, and ignore-cycle. The same panel is shown on every Space and over full-screen apps, and it is ordered front again whenever the screen configuration changes.

The panel’s frame is a fixed canvas, 580 by 480 points, centered on the notch and flush with the top of the screen. The black island is a path inside that canvas. The path always has the same nine elements (move, shoulder curve, side, bottom curve, bottom edge, bottom curve, side, shoulder curve, close), which is what lets Core Animation morph any state into any other. `Sources/IslandCore/Geometry.swift` builds that path with the bottom-left origin AppKit uses. The top edge sits on the top of the canvas, with concave 12-point shoulders into the menu bar.

Which screen: the first `NSScreen` whose `safeAreaInsets.top` is greater than zero, otherwise the main screen. Notch size comes from the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` when the top inset is positive and the computed width is between 60 and 400 points. Otherwise the helper pretends there is a 190-point pill whose height is the menu bar. A real notch is about 32 points tall on current MacBooks; the code allows a 38-point inset. Display changes, Space changes, and wake (`didChangeScreenParameters`, `activeSpaceDidChange`, `didWake`, `screensDidWake`) re-anchor the canvas and emit a `screen` event.

Hit testing is geometric, not based on a transparent window that swallows the desktop. `updateMouse` maps the cursor into the canvas and decides whether it is inside the notch or the current island rectangle. Outside that rectangle the panel sets `ignoresMouseEvents`, so the click falls through to whatever is underneath. Inside it, the panel takes the click. `acceptsFirstMouse` is true on the hosting view, so the first click counts even though the helper is not the active app. A `CAShapeLayer` subclass returns nil from `hitTest` so the black fill itself is never the click target; the SwiftUI layer above it is.

Hover is a pure gate in `Sources/IslandCore/Hover.swift`, sampled from a global mouse monitor and a local one, plus a tracking area. Rest about 0.3 seconds on the hot zone to open. Motion faster than 800 points per second restarts that rest, so a flick toward the menu bar does not open the island. Leaving the shape for about 0.35 seconds closes it. A mouse button that is already down does not count as hover. The controller arms a short timer for the rest and leave deadlines so they fire without another mouse event.

There is one `IslandView` at a time. Modes the renderer understands are `rest`, `deck`, `ask`, and `meeting`. Any other mode is treated as rest (`IslandView.isRest`). Expanded layout is on when the cursor is resting on the island or the host set `open: true`. A sized tray suppresses the SwiftUI detail and becomes the black shape itself.

### What it shows today

Compact, the island is the notch plus two wings of 64 points. The left wing is an SF Symbol. The right wing is a live elapsed clock when the host sent `startedAt` (epoch milliseconds), or a short `word` such as “Allow?” or “4 min”. The clock stops when `endedAt` is set. Deck glyphs pulse while the work has not ended.

| Glyph name | Symbol | Used for |
| --- | --- | --- |
| `read` | doc | reading something |
| `edit` | pencil | writing |
| `run` | terminal | a command |
| `search` | magnifying glass | search |
| `web` | globe | a page |
| `plan` | list | a plan |
| `done` | check | finished |
| `error` | triangle | a failure |
| `ask` | raised hand | a question |
| `meet` | video | a meeting |
| anything else, including the documented name `think` | sparkle | fallback |

Expanded:

- **Deck.** A grey `last` line and a white `now` line, one line each, under the wings. Width up to 380, about 54 points taller than the notch.
- **Ask.** The question, two lines, then Allow / Deny and an optional Always, plus an optional `keys` caption. Width up to 420, about 92 points taller. The buttons emit `action`.
- **Meeting.** Title, a `when` string, and a Join button when `join` is true. Width up to 360, about 58 points taller. Join emits `action` with id `join` and no meeting id.
- **Rest, hovered.** The wings plus the literal text “Nothing running”. About 24 points taller. This string is not configurable.
- **Rest, not hovered, real notch.** The shape matches the housing. No wings, no text.
- **Rest, not hovered, no notch.** The shape is drawn at alpha 0. The top center of the screen is still a hot zone, so a deliberate hover peeks “Nothing running”.
- **Tray, v0.1.** `{"t":"tray","open":true}` widens the black shape to 520 points and keeps it only as tall as the notch, with a flat bottom (`r` is 0). It is the top edge of a panel the host draws underneath.
- **Tray, v0.2.** `{"t":"tray","open":true,"w":520,"h":236}` makes the black shape the tray: width clamped into the canvas, height equal to the notch plus `h`, up to 400 points of body, bottom radius 24, shoulders kept. The host is expected to draw transparent content on top and fade it in after the spring. The helper’s own detail text hides while a tray is open.

Open springs are a little under-damped (stiffness 230, damping 24, on the order of 2 percent overshoot, response around 0.4 seconds). Close springs are stiffer and critically damped. SwiftUI fades the text on its own 0.36-second spring, separate from the mask.

Clicks on the body emit `{"ev":"click"}`. There is no text field, no keyboard handler, no drag destination, no queue of activities, no badge, and no second island.

### How it talks to Brain

The helper has no socket, no shared file, no Electron IPC, and no Brain-specific code. The entire integration is a child process.

Brain starts `NotchIsland`, writes one JSON object per line to the child’s stdin, and reads one JSON object per line from the child’s stdout. When Brain exits, the pipe closes and the helper exits. A second copy of the helper is a second island; nothing takes a lock.

Host to helper (`decodeInbound` in `Protocol.swift`):

```json
{"t":"view","view":{"mode":"deck","glyph":"read","last":"Read data.csv","now":"Writing the summary","startedAt":1730550000000}}
{"t":"view","view":{"mode":"ask","open":true,"ask":{"id":"42","question":"Move 3 files to the Trash?","allow":"Move to Trash","deny":"Cancel","always":"Always","keys":"⌃⌥Y · ⌃⌥N"}}}
{"t":"view","view":{"mode":"meeting","meeting":{"title":"Design review","when":"Starts in 4 min","join":true}}}
{"t":"view","view":{"mode":"rest"}}
{"t":"tray","open":true}
{"t":"tray","open":true,"w":520,"h":236}
{"t":"tray","open":false}
{"t":"ping"}
{"t":"quit"}
```

A line that is empty, not JSON, or not one of those types is ignored. Unknown JSON fields are ignored. A `view` without a `view` object is ignored. A tray with `open: true` and `h` greater than zero is the sized tray; `w` defaults to 520. A tray line that is not explicitly open closes, even if it still carries an `h`.

Helper to host (`encodeEvent`, keys sorted):

| Event | When |
| --- | --- |
| `ready` | Once, after the panel is ordered front. `v` is protocol `1`. `notch` is `w`, `h`, `has`. `hz` is the display refresh. `caps` is `["traySize","peek"]`. `version` is `"0.2.0"`. |
| `screen` | After a re-anchor that was not the first one. Same notch object, plus `hz`. |
| `hover` / `leave` | The rest timer opened, or the leave timer closed. |
| `click` | A click on the island that was not a button. |
| `action` | `id` is `allow`, `deny`, `always`, or `join`. Ask buttons also send `ask` with the ask id. Join does not. |
| `pong` | Answer to `ping`. |
| `log` | Documented. Nothing in the app emits it. |

`ready` is the feature test. A host that wants the sized tray checks `caps` for `traySize` before sending `w` and `h`. An older helper still accepts a bare `tray` and draws the flat edge.

What Brain does with that pipe today, from the 1.10 read: the notch is one of four doors into the same chat, next to the window, Telegram, and the Tailscale phone page. Approve on the notch is supposed to call the same action runner as Approve in the window (`lib/actions.ts`), and `decideAction` in `lib/trust.ts` still forces email and iMessage to wait for a tap. The helper does not know any of that. It will render whatever question Brain sends, and it will emit `always` if Brain included an Always label.

A practical division of the two processes:

- **The helper draws and reports pointers.** It is good at morphing, hovering, and one tap.
- **Brain decides.** Mail, texts, the ledger, Zelle, the three moves, the operator, and voice all stay in Brain. The morning brief Brain already composes (`lib/polish/chief.ts`, `lib/proactive/`, `lib/autopilot/`) becomes a `view` line. A tap comes back as `action`, and Brain runs it through `lib/trust.ts` and `lib/actions.ts` the same way a tap in the window does.

The v0.2 tray is how a richer Brain surface appears without teaching SwiftUI about deals. Brain asks for a size, waits out the spring, and fades its own transparent window in on top. The helper never tells Brain when the spring has settled, and `screen` never includes the panel’s frame, the display id, or the scale factor. Brain has to compute the same notch a second time in Electron’s coordinate space (origin at the top left, not the bottom left) and hope both processes picked the same screen.

### Permissions and entitlements

The helper ships with no entitlements and no usage strings, because it is not a bundle.

What it actually uses:

| Need | Status |
| --- | --- |
| Draw over the menu bar and full-screen spaces | Works for a non-sandboxed app at menu-bar level. No entitlement. |
| See the notch | Public AppKit: `safeAreaInsets`, `auxiliaryTopLeftArea`, `auxiliaryTopRightArea`. No permission prompt. |
| Hover while click-through | A global `NSEvent` monitor for move, drag, mouse-down, and mouse-up, plus `NSEvent.mouseLocation`. Apple’s documented Accessibility requirement is for key events. This monitor does not ask for a key. |
| Keyboard | Not read. The `keys` caption is paint. The panel cannot become key, so it cannot host a text field without giving up the “never steal focus” rule. |
| Microphone, speech, camera, contacts, calendar, photos, location, screen recording, Apple Events | None. Those stay on the Brain app, which already holds Full Disk Access for `chat.db`, Automation for Messages, and Google OAuth. |
| Network | None. |

The unsigned binary is the permission story that matters. The release workflow does not sign. The README says the host signs the binary when bundling. A notarized Brain with the hardened runtime will refuse an unsigned child unless Brain re-signs `NotchIsland` with the Brain certificate before spawn. TCC grants stick to a code signature. A helper that is re-signed on every Brain update keeps the grant only when the designated requirement stays stable. Putting a new prompt (screen recording, microphone, accessibility) on the helper means a second toggle in System Settings that breaks when the signature changes. New OS permissions belong on Brain. The helper should keep receiving paths, strings, and taps.

stdin is trusted completely. Anyone who can write to that pipe can put a fake “Send to Forest?” over the notch, at a level above normal windows. The pipe from parent to child is the right boundary. A world-readable Unix socket would throw that boundary away. If a socket is ever added, it needs the same per-launch secret Brain already uses for its local API, and it should bind to the user only.

The island is on top of screen shares. A dollar amount drawn in the compact wing is in the Zoom. Revenue and invoice totals stay off that wing. The open card can show the figure he needs in order to confirm a match, and that string stays out of any outbound model prompt. That matches the 1.10 rule: a draft turn does not receive the Stripe and Shopify paragraph (`hideMoney` on a draft).

### Build and release

Local:

```sh
swift test
swift build -c release --arch arm64
```

`.github/workflows/release.yml` runs on push to `main`, on a tag that matches `v*`, and on manual dispatch. One job, `macos-latest`, 20 minutes, `contents: write`. It prints the Swift version, runs `swift test`, builds a release arm64 binary, copies it to `out/NotchIsland-arm64`, writes a sha256, and smoke-tests that the binary emits `ready` and answers `ping`. On a tag it uploads the binary and the sha256 to a GitHub release, creating the release if needed. The note is the tag, the commit, and the hash. The binary is unsigned.

The version the host sees is the string `helperVersion`, edited by hand. The tag does not update it. `protocolVersion` stays `1` until a breaking change. Additive behavior is announced in `caps`.

House style for a release of this repo:

1. Land the behavior with IslandCore tests, and bump `helperVersion` in the same change.
2. Update the protocol section of `README.md`, including any new `caps` name.
3. Merge to `main` (the workflow builds and uploads an artifact; it does not make a release).
4. Tag `v0.x.y`. The tag workflow attaches `NotchIsland-arm64` and `NotchIsland-arm64.sha256`.
5. Brain pins that hash, re-signs the binary with the Brain certificate, and checks `caps` before using a new field.

No second workflow. The existing macOS job is the release machine.

---

## 2. Bugs, fragile spots, and gaps

These are in the helper as it stands, or in the seam with Brain. The Brain-side ones are gaps in the contract, not defects confirmed on the PR 14 branch.

**Unknown modes look idle.** `isRest` is “not deck, not ask, not meeting.” A host that sends `mode: "moves"` to a v0.2.0 binary gets a resting notch, and a hover says “Nothing running,” while the morning brief is sitting in Brain. Brain has to check `version` and `caps`, and until `moves` exists it has to express the morning with `deck`, `ask`, `meeting`, and the tray.

**“Nothing running” is a lie whenever Brain has work and has not pushed a view.** The peek string is hardcoded in `IslandContent.swift`. There is no badge on the bare notch. If the helper restarts, it sits at rest until Brain sends a view. Brain should push the current view on `ready`, not only when something changes.

**`setView` always restarts the spring.** Equal views are not compared. A host that rewrites `when` every second to keep a meeting countdown honest will re-morph the island every second. The elapsed clock avoids this because `startedAt` is ticked inside the helper. Meeting text does not have that. A duplicate view should be ignored, and the countdown should be a timestamp.

**Join has no id.** Allow, Deny, and Always send `ask`. Join sends `{"ev":"action","id":"join"}` only. Two meetings in one morning, or a view that changes before Brain handles the line, and Brain can join the wrong call. The meeting needs an id, and the event needs to carry it.

**`keys` does nothing.** The caption can show `⌃⌥Y`. No monitor hears it. Brain must not assume the helper enforces those shortcuts. A real shortcut belongs in Brain (`globalShortcut` in Electron registers a Carbon hotkey and does not need Accessibility).

**The sized tray and the flat tray want opposite window order.**

- Flat tray (no `h`): the black shape is only the notch band. Clicks below it pass through the helper, so Brain’s panel has to sit *under* the helper, above ordinary windows.
- Sized tray (`h` set): the black shape includes the body, `ignoresMouseEvents` turns off for that whole rectangle, and the SwiftUI root eats the click (it emits `click`). Brain’s controls work only if Brain’s window is *above* the helper. A window above the helper also covers the notch, so hover dies unless that window forwards mouse events back down.

`ready` and `screen` do not include the panel frame, the display id, or the backing scale. Electron’s coordinates are top-left origin. AppKit’s are bottom-left. Brain can easily place the tray on the wrong display or a few points off the housing, which shows up as a grey seam at the notch. There is also no `settled` event. The README tells the host to fade in once the shape is mostly open. The host has to guess at ~0.4 seconds, and a second view update interrupts the spring.

**One slot.** A meeting starting in four minutes replaces the approve card, or the other way around. Nothing has a priority. Brain has to be the scheduler: a send card beats a deck status, a meeting inside a few minutes beats a quiet deck, and the thing that was covered comes back when the card is tapped or dismissed. The helper will not stack them.

**Ask buttons exist only while expanded.** Expansion is hover or `open: true`. A morning card that forgets `open` is a pair of wings until he notices and rests on it. Brain should set `open: true` for anything that needs a tap, and clear it after the tap.

**Always is a trust escalation the helper will gladly show.** For a file move, Always is a fair button. For send, book, or pay, Always would mean “do this kind of thing without me.” `lib/trust.ts` already refuses to let email and iMessage leave without a tap, and that rule has to win even if a notch card says Always. The safe encoding is to omit `always` on those cards. The helper does not know the difference.

**Voice cannot approve, and the helper cannot hear “send it.”** There is no microphone. When a mic is added, it should live in Brain, and a transcript should become a draft or an operator plan. The approve action stays a click on Allow.

**Silent drops.** Lines over 1 MB are discarded by `LineBuffer` (the cap is `1 << 20`). A bad type (a `startedAt` sent as a string) fails the whole decode and the previous view stays up, with no error event. A screenshot or a mail body stuffed into one JSON line will vanish. Pixels and long bodies should be files Brain already has; the line carries an id and a short label.

**`think` has no glyph.** The protocol comment lists it. `glyphStyle` does not. It draws a sparkle.

**The mask and the text are on different springs.** SwiftUI starts showing the question immediately. The shape is still opening. For one frame the words sit in a shape too small for them. Noticeable, not a logic bug.

**Screen choice is “first notch.”** An external display that reports a top inset would steal the island from the MacBook. Unusual, and the 60-to-400-point width check is the only guard. A future Mac with a wider housing would be classified as “no notch” and hidden until hover.

**No heartbeat of its own.** `pong` answers `ping`. A wedged main thread stops reading stdin and stops answering. Brain should ping on an interval and restart the child if `pong` does not come back, then send the current view again on the new `ready`. The smoke test in CI starts the binary, checks for `ready` and `pong`, and kills it. It does not prove a view was drawn.

**Signing and quarantine.** A binary downloaded by a browser gets `com.apple.quarantine`. Brain should fetch the release asset itself, check the sha256, re-sign, and spawn that copy. Spawning the unsigned release asset out of `~/Downloads` will fail under the hardened runtime or Gatekeeper.

**Z-order versus full screen.** `fullScreenAuxiliary` plus a level above the menu bar is the usual recipe, and it is what the code does. Some full-screen Spaces still hide auxiliary windows after a macOS update. Worth a manual check on his machine after each macOS point release. There is no automated test for it.

**What v0.2.0 can already carry for Brain, with no helper change.** One live job (`deck` with `glyph`, `last`, `now`, `startedAt`). One approve card (`ask` with `open: true`, and no `always` when the tap sends, books, or marks money). One meeting (`meeting` with a `when` string and `join`). A Brain-drawn panel (the tray), which is the right place for the three moves and a command line until the helper grows a `moves` mode. Hover and click are enough to open that panel.

---

## 3. Features

Three rules apply to every bucket.

1. **A send, a booking, and a payment wait for a tap on Allow.** The operator may draft, look up, and line the cards up. Join opens a meeting he already has. Mark-paid records a match he confirmed. None of these fire on hover, on a timer, on Always, or on a spoken “yes.”
2. **Revenue stays off the wire and off the compact pill.** Company totals, Stripe, Shopify, and “what did we make this month” are for the Brain window when he asks. They are not written into an outbound prompt, and they are not drawn in the wings, which sit in every screen share. An open confirm card may show the single invoice figure he is matching.
3. **Local first, and the helper stays a display.** New network calls do not get added to this process. Speech, screen capture, clipboard reads, and window control run in Brain, which already has the signing identity and the data. The line protocol carries short strings, ids, and file paths.

Effort is the size of the change. **S** is a field or a card on the existing modes. **M** crosses a few files in this repo and a real Brain wiring change. **L** is a new interaction model or a new OS permission.

Voice learning and a voice command are different things. Voice learning in 1.11 is how drafts sound like him, per person, from mail he actually sent. The notch shows those drafts. It does not train them. A voice command is speech in, and it shows up in the useful bucket as a way to start an operator job.

### Useful

Running the computer and the work. This is the bucket the first release should finish.

**Three moves, live.**

The morning is the three cards the brief already chose: the deal or invoice where a reply changes money, the promise that comes due, and the meeting that needs him. Each line is a short title and a business name (LabTested, ERDA, Pacific Interlude). Tapping a line opens that card. The bare notch grows a small count when the list is non-empty, so a hover cannot say “Nothing running” while Forest is waiting.

*Tuesday, before he opens the laptop lid all the way.* He rests on the notch. It says “3”. The body shows: send Forest the one-pager, confirm the Zelle on the Friday shoot, buyer call at 11. The newsletter is not there.

*Fit.* Today, Brain sends three `ask` or `deck` views one after another, or draws the list in the tray. A `moves` mode (up to three rows, ids, a `peek` string, a count) belongs in `Protocol.swift`, `Geometry.swift`, and `IslandContent.swift`, with a test next to `testTraySizedAndPeek`. Brain’s source is the brief ranker (`lib/polish/chief.ts`) fed by the ledger, the money desk, and the calendar, pushed again whenever `ready` arrives. A new cap name: `moves`.

*Effort.* M.

*Risk.* Ranking by money can hide a text from someone on today’s shoot. The brief keeps one slot for “blocking today,” the same way the 1.11 design reserved a personal slot. The compact count is a number of cards, never a dollar total.

**Approve and send cards.**

The card names the act and the person: “Send the one-pager to Forest?” Allow and Not now. Allow calls the existing action runner. Not now dismisses. There is no Always on a send.

*On set, a reply is ready and he does not want the Brain window over the frame.* The island opens with the question. He taps Send. The wings show “Sent” for a moment and collapse. The same card, with Allow labeled “Approve & send”, is an iMessage. Brain’s ten-second undo on texts still applies inside Brain; the notch just shows that it went.

*Fit.* The `ask` mode already emits `allow` and `deny` with the ask id. Brain maps that id to a pending action in `lib/actions.ts` and passes it through `lib/trust.ts`. Email send and iMessage send stay pending until that tap. The helper change is a documented rule plus, if the caption must wrap a third line, a slightly taller ask. Omit `always`.

*Effort.* S on the helper, M in Brain to point the existing cards at the pipe.

*Risk.* A vague question (“OK to go ahead?”) on a window this prominent will get a tap he did not mean. The question string has to carry the verb and the recipient. Brain already has this card in the window and on Telegram; the notch should show the same record, not a second queue.

**Mail and iMessage peek, with the draft under it.**

Compact wing: an envelope or a bubble, and a word like “Forest” or “Adam”. Expanded: who, one line of what they said, one line of the drafted reply, Send and Not now.

*Between setups he feels the phone and ignores it.* The notch has already drafted Adam in the voice he uses with Adam. He reads one line, taps Not now, and the next move comes up.

*Fit.* Same `ask` shape, with `last` unused today in ask mode; either reuse `last` and `now` above the buttons or add `preview` on `AskInfo`. Drafts come from the morning drafter and from `lib/chat/text-turn.ts`. iMessage still needs Full Disk Access and Automation on **Brain**, which already asks for both. The helper never opens `chat.db`. Bodies stay in `brain.db`. The line gets a clipped preview, not the thread.

*Effort.* M.

*Risk.* A verification code or a family thread on the notch during a client call. One-to-one only, the same cap the text-draft design used (a handful, not every chat), and nothing that looks like a code. Preview text is short enough to be useless to someone across the table.

**Meeting countdown, one-tap join, the brief.**

The right wing counts down from a timestamp the helper holds, the way the job clock already runs from `startedAt`. Expanded: title, the brief (the deal, the open promise, the last thread), Join.

*Ten minutes before the buyer call Austin opened.* The island opens on its own (`open: true`). The brief says he still owes the one-pager. Join emits an id. Brain opens the link. Brain does not create the event.

*Fit.* Add `id` and `startsAt` to `MeetingInfo`. `ClockView` already ticks once a second; a countdown is the same view with the subtraction reversed. Include the id on the join `action`. The brief string is written by `lib/polish/prep.ts` from the ledger, and it stays free of revenue totals. Calendar permission stays inside Brain (EventKit or the JXA path Brain uses now). Cap: `countdown`.

*Effort.* S.

*Risk.* Join without an id is the current bug, fixed here. A brief that pastes the Stripe number into the notch is the privacy rule, enforced by the same money filter as drafts.

**Zelle arrived, confirm paid.**

The money desk proposes a match. The notch asks him to confirm it. Allow marks the invoice paid in the ledger. Deny leaves it open. The card never sends a payment, because Brain does not send Zelle.

*He feels the phone buzz, then sees the island.* “Zelle matches invoice 184. Mark it paid?” The wing says “Paid?”, not the amount. The open card shows the client and the figure so he can reject a near miss. He taps Mark paid. The chase draft for that invoice goes away.

*Fit.* An `ask` with a money glyph (add `money` next to the other names in `glyphStyle`). The id is the match id from the money desk. Brain closes the invoice on `allow` the same way the portal’s mark-paid already wants a tap. No new payment framework. No `PKPayment`. No Network in the helper.

*Effort.* S on the helper, M in Brain if the match object is not already a pending action.

*Risk.* A wrong match marked paid is worse than a late nudge. The card shows client, invoice number, and amount, and only while open. Near misses stay as Deny. Company revenue is not on the card.

**Operator command bar, and voice.**

He says or types a job. Brain runs the operator and stacks approve cards. The bar itself is Brain’s tray content, not a second chat invented in SwiftUI.

*Walking back from the cove.* He taps the notch, or hits the shortcut Brain registered. The tray opens. He says “rebook Adam for next Thursday.” The wings switch to a plan glyph: “Checking Thursday.” Two cards come back, a text and an email. He sends one and skips one. Saying “send it” does not send it.

*Fit.* Tray messages already exist (`traySize`). Brain focuses a field in its own window and runs the planner that 1.11 puts in front of search, `draftPrompt`, `lib/chat/text-turn.ts`, the portal’s draft invoice, and the calendar proposer. `decideAction` stays the gate. Voice uses Brain’s dictation pointed at the local model. If Apple’s speech recognizer is used, it is the on-device recognizer, with the microphone permission on the Brain app. The helper grows no text field in this release, which keeps the panel non-key. Shortcut: Electron `globalShortcut`, and Brain sends `tray`.

*Effort.* M for the tray wiring and the deck status of a running plan. L if on-device speech is new in Brain.

*Risk.* A misfired phrase must not approve. The planner’s step cap and “show the plan before the drafts” rule stay. Microphone copy has to say the audio stays on the Mac. A cloud speech API is a breach of local-first.

**Now playing.**

Artist and title in the wings while a job is not using them. Play and pause as buttons that emit `action`.

*Rendering a grade, music on.* He glances up to see the track. A move arriving preempts the track; the track comes back when the card closes.

*Fit.* Brain samples Now Playing and sends a `deck` or a small new mode. The public API is poor; the reliable one on macOS is the private MediaRemote framework. That call belongs in the signed Brain process, behind a setting, because it breaks across macOS updates. The helper only displays. Preempt rules live in Brain’s one-slot scheduler until the live-activity queue exists.

*Effort.* M, almost all of it in Brain.

*Risk.* Private API. Keep it out of the helper so a macOS break does not take the approve cards down with the visualizer.

**Timers and focus.**

A focus block from the brief, counted down locally from `endsAt`. Done, or a waiting approve card, ends it early.

*He asked for a 45-minute grade with the phone in the other room.* The wing counts down. At zero the island flashes done and gets out of the way. It does not send anything.

*Fit.* The tick in `ClockView` already runs once a second, but `endedAt` freezes the clock at a duration. A countdown needs its own `endsAt`, subtracted from now, the same idea as a meeting `startsAt`. Brain’s chief brief already has focus blocks. The duplicate-view fix from the bug list matters here so a once-a-minute refresh does not re-spring the shape.

*Effort.* S.

*Risk.* A timer that covers an approve card. Cards preempt timers.

**Clipboard.**

On demand, when he asks, the last text clip as a tray row he can drop into a draft. The helper does not watch the pasteboard.

*A rate got copied out of a thread.* He hits the shortcut, sees the clip, and taps to put it in the reply. The model does not receive the clipboard unless he taps.

*Fit.* Electron `clipboard.readText()` inside Brain, shown in the tray. No helper change. A continuous poll would eventually copy a password or a revenue export into the island. Skip that.

*Effort.* S.

*Risk.* Secrets. On demand, and never as model context by default.

**Screenshot into Brain.**

A shortcut captures the screen or the front window into Brain’s uploads directory and shows a card: “Save to the Forest deal?” Allow attaches it to that deal in the ledger. The pixels never travel on the JSON line.

*A call sheet is on screen and he wants it on the shoot.* One shortcut, one card, one tap. The file stays under `~/Library/Application Support/Brain`.

*Fit.* `desktopCapturer` or ScreenCaptureKit in Brain. Screen Recording permission on Brain, once. The helper shows an `ask` with a filename, not the bitmap. Cap the line protocol where it is.

*Effort.* M.

*Risk.* Screen recording is a wide grant. The card is the gate before anything is filed, and before any model sees the image. Capture does not include a silent watch.

**Windows and apps.**

“Switch to Capture One” as an operator step that uses `NSWorkspace` to activate an app. The notch shows the front app when he asks, which Brain can already see from the operating system.

*His hands are on the keyboard and the notch has the next move.* Activating an app is safe. Clicking a button inside Mail, Messages, or a bank is not an island feature.

*Fit.* Brain, `NSWorkspace.shared.open` or the Activation APIs, no Accessibility required for a plain activate. Driving another app’s buttons needs Accessibility or System Events, and it can press Send. Leave that out.

*Effort.* S for activate. L, and a poor trade, for UI scripting.

*Risk.* UI scripting can send and pay. Activate only.

**System stats.**

CPU, memory, and battery as a deck he can peek, useful while a local model is loaded.

*The 35B is hot and the fans are up.* He hovers and sees why. This never becomes a card that does something.

*Fit.* Brain samples `host_statistics` or a tiny helper call and sends a `deck`. `ProcessInfo` and IOKit need no special entitlement for the calling process’s own view of load. No helper work if Brain sends `now`.

*Effort.* S.

*Risk.* Low. Keep it off the default rest state so the notch stays quiet.

**Drop a file on the island.**

He drags a PDF onto the notch. The helper accepts the drop and emits the path. Brain files it on the deal or the invoice he confirms.

*A client just AirDropped a PO.* He drops it on the notch. A card says “Attach to the Forest deal?” He taps Allow.

*Fit.* `NSDraggingDestination` on the tracking view, in `IslandController.swift`. Emit `{"ev":"drop","paths":[...]}`. Brain reads the files locally. This is one of the few features that has to live in the helper, because the helper is the window under the cursor. Cap: `drop`. No network upload.

*Effort.* M.

*Risk.* A drop should not be processed by the model until he confirms which deal it belongs to. Paths only, and only files he dragged.

### Interactive

How his hands work. The island is already quiet on purpose (the fast-flick rule, the non-key panel, click-through). New gestures should keep that.

**Hover expansion.** Already there at 0.3 seconds in and 0.35 seconds out. The gap is what the hover reveals. A host-provided `peek` string replaces “Nothing running”. Hover never approves. *Effort S. Risk: a peek that contains a dollar amount.*

**A live-activity stack.** One compact activity in the wings, chosen by priority (approve, then a meeting inside 15 minutes, then a running operator job, then music or a timer). Hover or click shows the stack and he can switch. This is the real fix for the one-slot clobber. It is `IslandModel` growing a small list, `islandSize` growing a stack height, and Brain sending `{"t":"stack","items":[...]}` instead of replacing the only view. Asks still need `open: true` so a send card does not wait for hover. *Moment: the buyer call is in eight minutes and a Zelle card is waiting; the wing shows the call, the body shows both.* *Effort L. Risk: a stack that re-springs on every tick; updates to a row must not call the morph if the size did not change.*

**Keyboard shortcut.** One global shortcut, registered by Brain, toggles the tray. The helper stays non-key. A second shortcut is not required for Allow; Allow stays a click, because a hotkey is easy to hit while grading. *Effort S. Risk: the shortcut capturing keystrokes it should not. Register a chord, do not install an event tap, and do not request Input Monitoring.*

**Swipe between moves.** A horizontal scroll or a three-finger swipe over the open island cycles the three moves and emits `action` id `focus`. Implement with the local mouse monitor already in `watchMouse`, not a gesture recognizer that steals scroll from the window below. Swipes only count while the panel is accepting events, which is while the cursor is on the shape. *Moment: the three morning lines, and he flicks to the one he will do first.* *Effort M. Risk: a swipe that dismisses a send card. Dismiss stays a button.*

**Drag and drop.** Covered above as a useful feature. The interactive half is the hover target lighting up (a slightly wider path, same nine elements) so he can see the drop will land. *Effort folded into the drop.*

**Drag the tray taller.** He pulls the bottom edge and the helper emits `trayResize` so Brain can grow its content. Easy to get wrong with the spring, and the host already chooses `h`. Skip until the sized-tray z-order is solid. *Effort M. Risk: fighting the host’s own height.*

**Live Activity-style states.** Transient states with a lifetime: “Sent”, “Marked paid”, “Joined”, each shown for about two seconds and then the stack underneath returns. The host sends `{"t":"flash","glyph":"done","word":"Sent","ms":2000}`. The helper returns to the previous view by itself so Brain does not have to race the timer. *Moment: the tap lands and the island answers, then gets out of the shot.* *Effort M. Risk: a flash that covers a newer ask. A new ask cancels the flash.*

### Fun

These ship after the morning is trustworthy. An ask, a meeting inside 15 minutes, or a running operator job hides all of them.

**A better spring and a few glyphs.** `money`, `text`, `music`, and `focus` in `glyphStyle`, and a duplicate-view check so the spring stops restarting. This is the fun that also fixes a bug. *Effort S. Risk: none that touches send.*

**Celebration when money is confirmed.** After he taps Mark paid, a short check and a single spring, then collapse. The celebration runs on the `flash` above. It does not run when a Zelle merely matches, and it does not show the amount. *Moment: the Friday invoice clears and the island ticks once, while he is already walking to the next setup.* *Effort S. Risk: celebrating the wrong match. It is tied to his tap, not to the bank event.*

**A mood or a pet.** A tiny face in the rest state whose expression follows the day: asleep when the list is clear, attentive when a card is waiting, pleased after a confirmed payment. It yields the pixels the moment a real view arrives. Drawn in SwiftUI, driven by a `mood` field Brain sets from the brief, not from a model call. *Effort M. Risk: cute things that cover the count. The count wins.*

**Streaks.** “Replied before noon, four days” as a peek line on a quiet morning. The data is the ledger and the sent mail Brain already has. It is a string, not a new store in the helper. *Effort S. Risk: a nag. One line, and only when nothing is waiting.*

**Music visualizer.** A few bars beside the track name, fed by amplitudes Brain computes. Pretty, and it depends on the private Now Playing API. It sits in the same preempt slot as the track. *Effort M. Risk: the same private-API break as Now Playing. Keep the drawing dumb so a failure just omits the bars.*

**Weather.** Temperature and the next rain as a peek on the rest state, for a shoot day. Location and the lookup run in Brain. WeatherKit needs an Apple entitlement on the signed app; a local source he already trusts is a better fit than a new key in the helper. *Moment: leaving for a Pacific Interlude exterior, the notch says the marine layer burns off at 11.* *Effort M. Risk: location permission. Ask once in Brain, and never send the coordinate to an outbound prompt.*

**A tiny game.** Something one-thumb that exists only while the island is hovered and the stack is empty, and that vanishes on any `ask` or `meeting`. It does not get a scoreboard in the cloud. *Effort M. Risk: it becomes the thing the island is for. The preempt rule is the whole design.*

---

## 4. Three releases

The version numbers follow this repo, not Brain’s. Each one is a tag `v*` that produces an unsigned `NotchIsland-arm64` and a sha256. Brain re-signs that exact hash. `protocolVersion` stays `1`. New behavior is a capability checked on `ready`. The AppKit process stays free of mail, money, and new TCC prompts.

Brain’s own release train (the version bump in the Hark workspace, `scripts/release.mjs`, no new billed workflow) is separate. The helper tag is what Brain pins. The useful work is half helper and half “Brain writes the lines it already knows how to mean.”

### v0.3.0 — The morning, on the notch

Ship the smallest helper change that makes the 1.11 brief, the approve tap, the meeting, and the Zelle confirm feel native. Leave gestures, music, and the pet out.

Helper:

- Ignore a `view` equal to the one already shown, so a chatty host does not restart the spring.
- `peek` string and a numeric `badge` on the rest state, so the hover tells the truth.
- `MeetingInfo.id` and `MeetingInfo.startsAt`. The wing counts down locally. Join’s `action` includes the id.
- `money` and `text` glyphs.
- `screen` and `ready` include the panel frame in AppKit points, the display id, and the backing scale, so Brain can place the tray on the same housing.
- A `settled` event when the open spring finishes, so Brain fades the tray in on a fact.
- Cap list grows: `peekText`, `countdown`, `screenFrame`, `settled`. Version string `0.3.0`.
- Tests in `IslandCoreTests` for the new decode, the countdown text, the equal-view rule (pure function), and the frame fields. The CI smoke test stays a ping.

Brain, in the same week, against a helper that reports those caps. On an older helper, Brain keeps using bare `ask`, `deck`, `meeting`, and the flat tray.

- On `ready`, push the current three moves. If `peekText` is present, the rest peek is “3 moves” (or “Clear”). If it is absent, send a `deck` rather than leaving rest in place.
- Approve cards for the drafted email, the drafted text, and the Zelle match. `open: true`. No `always`. Questions name the verb and the person. Zelle’s wing says “Paid?”. The amount is only in the open question.
- The next meeting inside the lead time uses `startsAt` and a brief from the ledger with no revenue figures. Join carries the id Brain just sent.
- A running operator job is a `deck` with `glyph` `plan` and a `now` line. When it produces drafts, those become ask cards, one at a time, send card first.
- Ping every few seconds. Restart the child if `pong` is late. Re-sign the pinned hash.

He will feel this on a shoot morning without a new gesture language. The three moves are on the housing. Sending, joining, and marking paid are taps. Saying a job aloud can wait if speech is not ready; typing it in the tray is the same operator.

### v0.4.0 — Hands, and more than one thing at once

Helper:

- A stack of a few activities, with a priority, replacing the single view as the thing Brain updates. Size changes still morph. Text changes inside the same size do not.
- `flash` for Sent, Joined, and Marked paid, then the stack returns.
- File drop on the shape, `ev` `drop` with paths. Cap `drop`.
- A host `peek` is already in 0.3; 0.4 adds swipe-between-items while the shape is open, emitting `focus`.

Brain:

- The global shortcut toggles the tray. The command field and the voice capture live here, on-device, and a transcript starts the operator. The approve buttons stay on screen.
- Clipboard on demand inside that tray.
- Screenshot into uploads, then an ask card that names the deal, before a model sees the file.
- Now Playing as a low-priority stack item. A failure to read the private API removes the item and leaves the morning alone.
- Activate-an-app as an operator step with no UI scripting.

He will feel this when two things are true at once (the call and the Zelle card) and when he drops a PO on the housing.

### v0.5.0 — The room

Helper:

- `mood` on the rest state, and the flash celebration wired to a confirmed payment.
- Room for a one-line streak in `peek` when the badge is zero.
- A visualizer row that draws amplitudes Brain sends. No audio capture in this process.
- The tiny game, only on hover, only when the stack is empty, killed by any ask or meeting.

Brain:

- Weather for the shoot day, location granted on the Brain app, shown as a peek string.
- Streak and mood chosen from the ledger with rules, not a model call, so a quiet morning does not spend a local-model load.
- Music amplitudes if Now Playing from 0.4.0 has stayed up across one macOS update. If it has not, skip the bars.

He will feel this when the island is idle: a small sign of life, a cleared-invoice tick, the marine layer. The first time a real card arrives, all of it gets out of the way.

### Cutting a release

Same as 0.1.0 and 0.2.0.

- One change updates the code, `helperVersion`, `capabilities`, the README protocol, and the tests.
- `swift test` is the gate this repo has. Keep new rules in `IslandCore` so they run there.
- Merge to `main`. Tag `v0.3.0`, then `v0.4.0`, then `v0.5.0`.
- The tag job attaches the arm64 binary and the sha256. It does not sign.
- Brain records the hash, re-signs with the Brain certificate, and branches on `caps`.

---

## Top 5

1. **Put the three morning moves on the notch**, with a count so it stops saying “Nothing running” when Forest is waiting. Tapping one opens that card.
2. **Let him send, join, and mark a Zelle paid with a tap**, on the same Approve path the window already uses. No Always, and a spoken “send it” does not send.
3. **Count the next meeting down and put the brief next to Join.** The brief is the deal and the promise, without a revenue number.
4. **Keep dollars off the wings.** The open Zelle card can show the one invoice amount he is confirming. That amount never goes into an outbound prompt, and the compact pill stays a word.
5. **Treat the helper as a display Brain drives**, re-signed and pinned by hash. Brain keeps the mail, the money, the mic, and the screen recording. The helper’s job is to morph, hover, and report the tap.
