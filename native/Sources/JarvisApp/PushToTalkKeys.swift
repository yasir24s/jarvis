import AppKit
import Carbon.HIToolbox
import JarvisChat

/// M9a: holding ⌥Space in the chat window talks. The decision for one key event, kept apart from
/// AppKit so it can be tested.
enum OptionSpace {
    enum Action: Equatable {
        /// Not ours: the event goes on as usual.
        case pass
        /// Swallowed (a key repeat while held: it would type a non-breaking space).
        case swallow
        case began
        case ended
    }

    /// - held: ⌥Space is down from an earlier key-down this monitor took.
    /// - inKeyChatWindow: the event is for the chat window, and that window is key.
    static func action(keyDown: Bool, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool,
                       inKeyChatWindow: Bool, held: Bool) -> Action {
        guard keyCode == UInt16(kVK_Space) else { return .pass }
        if !keyDown { return held ? .ended : .pass }
        if held { return .swallow }
        let mods = modifiers.intersection([.command, .control, .option, .shift])
        guard mods == .option, inKeyChatWindow else { return .pass }
        return isRepeat ? .swallow : .began
    }
}

/// Installs the ⌥Space monitor for the chat window. The window giving up key while ⌥Space is
/// held counts as letting go, since its key-up would go elsewhere.
@MainActor
final class PushToTalkKeys {
    private let talk: PushToTalkModel
    private let chatWindow: () -> NSWindow?
    private var monitor: Any?
    private var resign: NSObjectProtocol?
    private var held = false

    init(talk: PushToTalkModel, chatWindow: @escaping () -> NSWindow?) {
        self.talk = talk
        self.chatWindow = chatWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            let ours = MainActor.assumeIsolated { self.handle(event) }
            return ours ? nil : event
        }
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                        queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, self.held, window === self.chatWindow() else { return }
                self.held = false
                self.talk.holdEnded()
            }
        }
    }

    /// True when the event was ours.
    private func handle(_ event: NSEvent) -> Bool {
        let window = chatWindow()
        let inKey = window != nil && event.window === window && window?.isKeyWindow == true
        let action = OptionSpace.action(keyDown: event.type == .keyDown, keyCode: event.keyCode,
                                        modifiers: event.modifierFlags, isRepeat: event.isARepeat,
                                        inKeyChatWindow: inKey, held: held)
        switch action {
        case .pass:
            return false
        case .swallow:
            return true
        case .began:
            held = true
            talk.holdBegan()
            return true
        case .ended:
            held = false
            talk.holdEnded()
            return true
        }
    }
}

/// M9a: ⌃⌥J from anywhere, through Carbon's `RegisterEventHotKey`, which needs no Accessibility
/// or Input Monitoring permission (an event tap or a global key monitor would). The handler runs
/// on the main thread.
@MainActor
final class GlobalHotKey {
    /// 'JRVS'.
    nonisolated static let signature: OSType = 0x4A52_5653
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    fileprivate let action: () -> Void

    /// nil when the shortcut cannot be registered (another app holds it); the log says so.
    init?(keyCode: UInt32 = UInt32(kVK_ANSI_J), modifiers: UInt32 = UInt32(controlKey | optionKey),
          action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard got == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(user).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handler)
        guard installed == noErr else { return nil }
        let registered = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                             GetApplicationEventTarget(), 0, &ref)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    isolated deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
