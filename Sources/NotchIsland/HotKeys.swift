import AppKit
import Carbon
import IslandCore

/// Registers the ask card's `keys` caption with the system, and only while that card is showing.
/// `RegisterEventHotKey` is the same path Electron's globalShortcut uses. It is not an event tap,
/// and it is not an Allow key that stays armed after the card closes.
final class AskHotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: (action: String, ask: String)] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    var onFire: ((String, String) -> Void)?

    func install() {
        guard handler == nil else { return }
        hotKeyTarget = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), notchHotKeyProc, 1, &spec, nil, &handler)
    }

    func sync(chords: [KeyChord], ask: String, enabled: Bool) {
        clear()
        guard enabled, !ask.isEmpty else { return }
        install()
        for chord in chords {
            guard let code = virtualKey(chord.key) else { continue }
            var mods: UInt32 = 0
            if chord.control { mods |= UInt32(controlKey) }
            if chord.option { mods |= UInt32(optionKey) }
            if chord.shift { mods |= UInt32(shiftKey) }
            if chord.command { mods |= UInt32(cmdKey) }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hotID = EventHotKeyID(signature: OSType(0x4E544348), id: id) // 'NTCH'
            let status = RegisterEventHotKey(UInt32(code), mods, hotID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = (chord.action, ask)
            }
        }
    }

    func clear() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fired(_ id: UInt32) {
        guard let hit = actions[id] else { return }
        onFire?(hit.action, hit.ask)
    }
}

private weak var hotKeyTarget: AskHotKeys?

private func notchHotKeyProc(_ next: EventHandlerCallRef?, _ event: EventRef?, _ user: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return noErr }
    var hid = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hid)
    if err == noErr { hotKeyTarget?.fired(hid.id) }
    return noErr
}

private func virtualKey(_ letter: String) -> Int? {
    switch letter.lowercased() {
    case "a": return 0x00
    case "s": return 0x01
    case "d": return 0x02
    case "f": return 0x03
    case "h": return 0x04
    case "g": return 0x05
    case "z": return 0x06
    case "x": return 0x07
    case "c": return 0x08
    case "v": return 0x09
    case "b": return 0x0B
    case "q": return 0x0C
    case "w": return 0x0D
    case "e": return 0x0E
    case "r": return 0x0F
    case "y": return 0x10
    case "t": return 0x11
    case "o": return 0x1F
    case "u": return 0x20
    case "i": return 0x22
    case "p": return 0x23
    case "l": return 0x25
    case "j": return 0x26
    case "k": return 0x28
    case "n": return 0x2D
    case "m": return 0x2E
    case "1": return 0x12
    case "2": return 0x13
    case "3": return 0x14
    case "4": return 0x15
    case "5": return 0x17
    case "6": return 0x16
    case "7": return 0x1A
    case "8": return 0x1C
    case "9": return 0x19
    case "0": return 0x1D
    default: return nil
    }
}
