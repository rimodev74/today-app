import AppKit
import Carbon.HIToolbox

/// Le raccourci clavier GLOBAL de la saisie rapide : il agit même quand Today est en arrière-plan,
/// c'est tout son intérêt (noter une tâche sans quitter ce qu'on fait).
///
/// `RegisterEventHotKey` (Carbon) et PAS `NSEvent.addGlobalMonitorForEvents` : le moniteur global
/// exige l'autorisation « Accessibilité » (panneau système à ouvrir à la main, redemandée à chaque
/// changement de signature) ET ne consomme pas l'événement — la combinaison partirait aussi à l'app
/// de premier plan, qui la recevrait en double. L'API Carbon n'a ni l'un ni l'autre défaut, et reste
/// le seul chemin public pour un hot key global ; ce n'est pas un vestige déprécié.
final class GlobalHotKey {
  static let shared = GlobalHotKey()

  static let keyCodeStorageKey = "quickEntryHotKeyCode"
  static let modifiersStorageKey = "quickEntryHotKeyModifiers"
  static let labelStorageKey = "quickEntryHotKeyLabel"

  /// ⌃Espace au départ, comme la saisie rapide de Things.
  static let defaultKeyCode = kVK_Space
  static let defaultModifiers = Int(NSEvent.ModifierFlags.control.rawValue)
  static let defaultLabel = "⌃Espace"

  /// Ce que la combinaison déclenche. Posé au lancement par `TodayApp` — la classe ne connaît pas
  /// le panneau, elle ne fait que router une frappe.
  var action: () -> Void = {}

  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?

  private init() {}

  // MARK: Réglage

  /// La combinaison enregistrée, ou le défaut si l'utilisateur n'y a jamais touché.
  /// `keyCode < 0` ⇒ raccourci désactivé.
  static var current: (keyCode: Int, modifiers: NSEvent.ModifierFlags, label: String) {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: keyCodeStorageKey) != nil else {
      return (defaultKeyCode, NSEvent.ModifierFlags(rawValue: UInt(defaultModifiers)), defaultLabel)
    }
    return (
      defaults.integer(forKey: keyCodeStorageKey),
      NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: modifiersStorageKey))),
      defaults.string(forKey: labelStorageKey) ?? ""
    )
  }

  static func store(keyCode: Int, modifiers: NSEvent.ModifierFlags, label: String) {
    let defaults = UserDefaults.standard
    defaults.set(keyCode, forKey: keyCodeStorageKey)
    defaults.set(Int(modifiers.rawValue), forKey: modifiersStorageKey)
    defaults.set(label, forKey: labelStorageKey)
    shared.reload()
  }

  /// Écriture lisible d'une combinaison (⌃⌘A). Les touches sans glyphe imprimable (Espace, Entrée,
  /// les flèches, les F…) sont nommées : `charactersIgnoringModifiers` n'en donne rien d'affichable.
  static func label(keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String?) -> String {
    var text = ""
    if modifiers.contains(.control) { text += "⌃" }
    if modifiers.contains(.option) { text += "⌥" }
    if modifiers.contains(.shift) { text += "⇧" }
    if modifiers.contains(.command) { text += "⌘" }
    let key =
      named[keyCode]
      ?? characters.map { $0.uppercased() }.flatMap { $0.isEmpty ? nil : $0 }
      ?? "Touche \(keyCode)"
    return text + key
  }

  private static let named: [Int: String] = {
    var map: [Int: String] = [
      kVK_Space: "Espace", kVK_Return: "Entrée", kVK_Tab: "Tab", kVK_Escape: "Échap",
      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]
    let functionKeys = [
      kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
      kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]
    for (index, code) in functionKeys.enumerated() { map[code] = "F\(index + 1)" }
    return map
  }()

  // MARK: Enregistrement système

  /// (Ré)enregistre la combinaison courante. Idempotent : appelée au lancement ET à chaque
  /// changement du réglage, elle désenregistre toujours la précédente d'abord.
  func reload() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = nil

    let (keyCode, modifiers, _) = Self.current
    guard keyCode >= 0 else { return }
    installHandler()

    var ref: EventHotKeyRef?
    // Signature arbitraire mais stable ("TDYQ") : elle n'identifie ce hot key qu'auprès de nous.
    let id = EventHotKeyID(signature: 0x5444_5951, id: 1)
    let status = RegisterEventHotKey(
      UInt32(keyCode), Self.carbonModifiers(modifiers), id,
      GetApplicationEventTarget(), 0, &ref)
    // Échec = combinaison déjà prise par une autre app (Spotlight, etc.). Rien à faire ici : le
    // réglage reste affiché tel quel, l'utilisateur en choisira une autre en voyant que rien ne vient.
    if status == noErr { hotKey = ref }
  }

  private func installHandler() {
    guard handler == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        // Le handler Carbon est appelé sur la boucle d'exécution PRINCIPALE : l'action peut toucher
        // l'UI directement, sans saut de file.
        Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
        return noErr
      },
      1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }

  /// Carbon a ses propres masques de modificateurs, sans rapport avec ceux d'AppKit.
  private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var value: UInt32 = 0
    if flags.contains(.command) { value |= UInt32(cmdKey) }
    if flags.contains(.shift) { value |= UInt32(shiftKey) }
    if flags.contains(.option) { value |= UInt32(optionKey) }
    if flags.contains(.control) { value |= UInt32(controlKey) }
    return value
  }
}
