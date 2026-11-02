import AppKit

// A tiny accessory process (no Dock icon, no menu bar) that draws a notch island and talks JSON lines on
// stdin / stdout. See Sources/IslandCore/Protocol.swift for the messages.
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = IslandController()
controller.start()
app.run()
