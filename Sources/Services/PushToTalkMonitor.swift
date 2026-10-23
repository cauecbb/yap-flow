import AppKit
import Carbon.HIToolbox

/// Wispr Flow-style push-to-talk on the fn (globe) key:
/// - hold fn to talk, release to finish and paste;
/// - tap fn, or press space while holding it, to lock into hands-free mode,
///   then press fn again to finish;
/// - fn combined with any other key (fn+arrows, fn+delete, fn+F-keys) is the
///   user's own shortcut, so the dictation that started is thrown away;
/// - escape during a dictation cancels it and is swallowed, so it doesn't also
///   interrupt the app underneath (a coding agent in a terminal, say).
///
/// A CGEvent tap rather than NSEvent monitors: swallowing space and escape
/// means deciding synchronously, before the event reaches the focused app.
@MainActor
final class PushToTalkMonitor {
    var enabled = false {
        didSet { sync() }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onLock: (() -> Void)?
    var onStopHandsFree: (() -> Void)?
    var onCombo: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Whether a dictation is running right now, from whichever trigger started it.
    var isDictating: () -> Bool = { false }

    private enum Mode { case idle, holding, handsFree }

    private var mode: Mode = .idle
    private var fnDown = false
    /// Whether the system was kept from seeing the current fn press, so the
    /// release is hidden too and its idea of fn never gets stuck down.
    private var fnHidden = false
    private var pressedAt: Date?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The built-in keyboard reports fn as kVK_Function; some globe-key
    /// keyboards use 179.
    private static let fnKeyCodes: Set<Int64> = [Int64(kVK_Function), 179]
    private static let otherModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    /// Released sooner than this, fn was tapped rather than held: hands-free.
    private static let tapThreshold: TimeInterval = 0.3

    func start() { sync() }

    func stop() { uninstall() }

    private func sync() {
        if enabled {
            install()
        } else {
            uninstall()
            mode = .idle
            fnDown = false
            fnHidden = false
        }
    }

    private func install() {
        guard tap == nil else { return }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<PushToTalkMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Yap: could not create push-to-talk event tap; is Accessibility granted?")
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func uninstall() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
    }

    /// Same threading story as FunctionKeyMonitor: the tap source runs on the
    /// main run loop, so the decision is made synchronously on the main thread
    /// and the actions hop back onto the actor.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                guard let self, let tap = self.tap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        let swallow = MainActor.assumeIsolated {
            switch type {
            case .flagsChanged: return handleFlags(keyCode: keyCode, flags: flags)
            case .keyDown: return handleKeyDown(keyCode: keyCode, isRepeat: isRepeat)
            default: return false
            }
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// fn itself is swallowed, as Wispr does: a bare fn press and release is what
    /// opens Emoji & Symbols (or switches the input source), so the system must
    /// not see it. Down and up are hidden as a pair. Other modifiers always pass.
    /// fn+arrows, fn+delete and the F-keys are translated by the keyboard driver
    /// before this tap, so they keep working.
    private func handleFlags(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard Self.fnKeyCodes.contains(keyCode) else {
            // Another modifier joined while fn is held: a shortcut, not dictation.
            if fnDown, mode == .holding, flags.intersection(Self.otherModifiers).isEmpty == false {
                mode = .idle
                fire(onCombo)
            }
            return false
        }

        let isDown = flags.contains(.maskSecondaryFn)
        guard isDown != fnDown else { return fnHidden }
        fnDown = isDown

        if isDown {
            guard flags.intersection(Self.otherModifiers).isEmpty else {
                fnHidden = false
                return false
            }
            fnHidden = true
            if mode == .handsFree, isDictating() {
                mode = .idle
                fire(onStopHandsFree)
            } else {
                mode = .holding
                pressedAt = Date()
                fire(onPress)
            }
            return true
        }

        if mode == .holding {
            let heldFor = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
            pressedAt = nil
            if heldFor < Self.tapThreshold {
                mode = .handsFree
                fire(onLock)
            } else {
                mode = .idle
                fire(onRelease)
            }
        }
        let hidden = fnHidden
        fnHidden = false
        return hidden
    }

    private func handleKeyDown(keyCode: Int64, isRepeat: Bool) -> Bool {
        if keyCode == Int64(kVK_Escape), isDictating() {
            if !isRepeat {
                mode = .idle
                fire(onEscape)
            }
            return true
        }

        guard fnDown else { return false }

        if keyCode == Int64(kVK_Space) {
            switch mode {
            case .holding:
                mode = .handsFree
                fire(onLock)
                return true
            case .handsFree:
                // Space auto-repeating while fn is still down after the lock.
                return true
            case .idle:
                return false
            }
        }

        if mode == .holding {
            mode = .idle
            fire(onCombo)
        }
        return false
    }

    private func fire(_ action: (() -> Void)?) {
        guard let action else { return }
        DispatchQueue.main.async { action() }
    }
}
