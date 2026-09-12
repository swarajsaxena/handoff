import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey that works without asking the user for anything.
///
/// The alternative, `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`,
/// needs an Input Monitoring grant in System Settings — and when it isn't
/// granted it fails *silently*: you get a monitor object back and simply never
/// receive a callback. Routing this app's only keyboard entry point through a
/// permission wall would strand exactly the people who need it. Carbon's
/// hotkey table needs no permission, fires under `LSUIElement`, works over
/// full-screen apps, and consumes the chord so the frontmost app never sees it.
///
/// `MouseTracker` gets away with a global monitor because pointer movement
/// isn't privacy-gated; keyboard event types are.
final class HotKey {
  /// ⌃⌥N. Deliberately no ⌘ — a global hotkey steals its chord from whatever
  /// app is frontmost, and nearly every app menu shortcut uses Command.
  /// ponytail: one constant, not a preferences pane. Make it configurable
  /// when someone actually reports a collision.
  static let defaultKeyCode = UInt32(kVK_ANSI_N)
  static let defaultModifiers = UInt32(controlKey | optionKey)

  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private let handler: () -> Void
  private let id: UInt32

  /// Carbon hands the callback a C function pointer, which captures nothing,
  /// so instances are found again through this table by their hotkey id.
  private static var registry: [UInt32: HotKey] = [:]
  private static var nextID: UInt32 = 1

  /// Returns nil if the chord is already claimed by another app.
  init?(keyCode: UInt32 = HotKey.defaultKeyCode,
        modifiers: UInt32 = HotKey.defaultModifiers,
        handler: @escaping () -> Void) {
    self.handler = handler
    self.id = Self.nextID
    Self.nextID += 1

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ -> OSStatus in
        var pressedID = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &pressedID
        )
        guard status == noErr else { return status }
        HotKey.registry[pressedID.id]?.handler()
        return noErr
      },
      1,
      &eventType,
      nil,
      &handlerRef
    )
    guard installStatus == noErr else {
      NSLog("Handoff: could not install the hotkey handler (status \(installStatus))")
      return nil
    }

    let hotKeyID = EventHotKeyID(signature: OSType(0x48_41_4E_44), id: id)  // 'HAND'
    let registerStatus = RegisterEventHotKey(
      keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
    )
    guard registerStatus == noErr, hotKeyRef != nil else {
      // Almost always means another app already owns this chord. Logged so a
      // collision is diagnosable rather than just a dead key.
      NSLog("Handoff: could not register the hotkey (status \(registerStatus)) — already taken?")
      if let handlerRef { RemoveEventHandler(handlerRef) }
      return nil
    }

    Self.registry[id] = self
  }

  deinit {
    // Both refs must be held for the lifetime; dropping either silently
    // stops delivery.
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let handlerRef { RemoveEventHandler(handlerRef) }
    Self.registry[id] = nil
  }
}
