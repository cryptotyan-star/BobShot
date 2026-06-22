import AppKit
import Carbon.HIToolbox

/// Комбинация клавиш в терминах Carbon (keyCode + маска модификаторов).
struct KeyCombo {
    let keyCode: UInt32
    let modifiers: UInt32

    /// Дефолтный хоткей BobShot — Ctrl+Option+S.
    static let controlOptionS = KeyCombo(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(controlKey | optionKey)
    )
}

/// Глобальный хоткей через Carbon `RegisterEventHotKey`.
/// Выбран Carbon, а не `NSEvent` global monitor: не требует разрешения Accessibility.
/// Хранит `EventHotKeyRef` и `EventHandlerRef`, умеет сниматься (без утечки при смене хоткея).
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: () -> Void

    // 'BBSH' — сигнатура нашего хоткея.
    private let signature: OSType = 0x4242_5348
    private let id: UInt32 = 1

    init?(combo: KeyCombo, action: @escaping () -> Void) {
        self.action = action
        guard install(combo: combo) else {
            NSLog("BobShot: не удалось зарегистрировать глобальный хоткей.")
            return nil
        }
    }

    private func install(combo: KeyCombo) -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                me.action()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let registerStatus = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registerStatus == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}
