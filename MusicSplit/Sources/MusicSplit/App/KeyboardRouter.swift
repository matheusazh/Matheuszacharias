import AppKit

/// Atalhos de uma tecla (espaço, setas, I/O, L, K, [ ], B). Ficam fora do menu para não
/// roubarem teclas de campos de texto: se há texto sendo editado, o evento segue normal.
@MainActor
final class KeyboardRouter {
    private var monitor: Any?

    func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model else { return event }
            // monitores locais rodam na main thread
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { Self.handle(e, model: model) }
            return handled ? nil : event
        }
    }

    private static func handle(_ event: NSEvent, model: AppModel) -> Bool {
        guard let window = NSApp.keyWindow, window === model.mainWindow,
              !(window.firstResponder is NSText), window.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let project = model.currentProject else { return false }
        let music = project.kind == .music
        switch event.keyCode {
        case 49: model.player.togglePlay(); return true                                   // espaço
        case 123: model.player.skip(event.modifierFlags.contains(.shift) ? -1 : -5); return true  // ←
        case 124: model.player.skip(event.modifierFlags.contains(.shift) ? 1 : 5); return true    // →
        case 115: model.player.seek(to: 0); return true                                   // home
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "i" where music: model.setLoopPoint(start: true)
        case "o" where music: model.setLoopPoint(start: false)
        case "l" where music: model.updateMix { $0.loopOn.toggle() }
        case "k" where music && project.analysis != nil: model.updateMix { $0.metronome.toggle() }
        case "]" where music: model.nudgeSpeed(0.05)
        case "[" where music: model.nudgeSpeed(-0.05)
        case "b" where !music: model.updateSpeech { $0.compareOriginal.toggle() }
        default: return false
        }
        return true
    }
}

extension AppModel {
    func setLoopPoint(start: Bool) {
        let t = player.position()
        updateMix { m in
            if start {
                m.loopStart = t
                if let e = m.loopEnd, e <= t + 0.2 { m.loopEnd = nil }
            } else {
                m.loopEnd = t
                if let s = m.loopStart, s >= t - 0.2 { m.loopStart = nil }
                if m.loopStart == nil { m.loopStart = max(0, t - 8) }
                m.loopOn = true
            }
        }
    }

    func nudgeSpeed(_ delta: Double) {
        updateMix { $0.speed = min(1.5, max(0.5, (($0.speed + delta) * 20).rounded() / 20)) }
    }
}
