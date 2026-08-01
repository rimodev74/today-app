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
/// Isolé au fil principal. Ce n'est pas une précaution ajoutée après coup : le gestionnaire Carbon
/// est appelé PAR la boucle d'exécution principale (cf. `installHandler`), et c'est précisément ce
/// qui autorise ses actions à toucher l'UI sans saut de file. L'annotation rend cette hypothèse
/// vérifiable au lieu de la laisser en commentaire.
@MainActor
final class GlobalHotKey {
  static let shared = GlobalHotKey()

  static let keyCodeStorageKey = "quickEntryHotKeyCode"
  static let modifiersStorageKey = "quickEntryHotKeyModifiers"
  static let labelStorageKey = "quickEntryHotKeyLabel"

  /// ⌃Espace au départ, comme la saisie rapide de Things.
  static let quickEntryDefault = KeyCombo(
    keyCode: kVK_Space, modifiers: NSEvent.ModifierFlags.control.rawValue, label: "⌃Espace")

  /// Ce qu'ouvre la combinaison de la saisie rapide. Posé au lancement par `TodayApp` — la classe ne
  /// connaît pas le panneau, elle ne fait que router une frappe.
  var action: () -> Void = {}

  /// Ce que déclenche la combinaison d'une action (cf. `KeyShortcut`), par son jeton. Même raison
  /// d'être : la routine de routage ne sait pas ce qu'est une date ni une fenêtre.
  var perform: (String) -> Void = { _ in }

  private var hotKeys: [EventHotKeyRef] = []
  /// Ce que chaque identifiant enregistré déclenche. Reconstruit à chaque `reload` : c'est lui qui
  /// permet à UN seul handler Carbon de servir toutes les combinaisons.
  private var actions: [UInt32: () -> Void] = [:]
  private var handler: EventHandlerRef?

  private init() {}

  // MARK: Réglage

  /// La combinaison de la saisie rapide, ou le défaut si l'utilisateur n'y a jamais touché.
  /// `nil` ⇒ raccourci retiré (`keyCode < 0` en base, écrit par `store(nil)`).
  static var current: KeyCombo? {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: keyCodeStorageKey) != nil else { return quickEntryDefault }
    let keyCode = defaults.integer(forKey: keyCodeStorageKey)
    guard keyCode >= 0 else { return nil }
    return KeyCombo(
      keyCode: keyCode,
      modifiers: UInt(defaults.integer(forKey: modifiersStorageKey)),
      label: defaults.string(forKey: labelStorageKey) ?? "")
  }

  static func store(_ combo: KeyCombo?) {
    let defaults = UserDefaults.standard
    defaults.set(combo?.keyCode ?? -1, forKey: keyCodeStorageKey)
    defaults.set(Int(combo?.modifiers ?? 0), forKey: modifiersStorageKey)
    defaults.set(combo?.label ?? "", forKey: labelStorageKey)
    shared.reload()
  }

  /// La combinaison frappée dans un enregistreur, ou `nil` si elle n'a pas de modificateur : un
  /// raccourci GLOBAL sans modificateur volerait la touche à toutes les autres apps.
  static func combo(capturing event: NSEvent) -> KeyCombo? {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard !modifiers.isEmpty else { return nil }
    let keyCode = Int(event.keyCode)
    return KeyCombo(
      keyCode: keyCode,
      modifiers: modifiers.rawValue,
      label: label(
        keyCode: keyCode, modifiers: modifiers,
        characters: event.charactersIgnoringModifiers))
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

  /// (Ré)enregistre TOUTES les combinaisons : celle de la saisie rapide et celle de chaque raccourci
  /// qui en porte une. Idempotent — appelée au lancement et à chaque changement de réglage, elle
  /// désenregistre toujours les précédentes d'abord.
  ///
  /// Elle relit les combinaisons depuis les défauts plutôt que de se les faire pousser : les
  /// réglages vivent dans leur propre fenêtre, et un simple `reload()` suffit alors à
  /// resynchroniser, d'où que vienne la modification.
  func reload() {
    hotKeys.forEach { UnregisterEventHotKey($0) }
    hotKeys.removeAll()
    actions.removeAll()
    installHandler()

    if let combo = Self.current {
      register(combo, id: 1) { [weak self] in self?.action() }
    }
    // ponytail: pas de détection de conflit entre deux combinaisons identiques — la seconde
    // `RegisterEventHotKey` échoue, la première de la liste gagne. Un badge dans les réglages si ça
    // devient un vrai problème.
    for (index, shortcut) in KeyShortcut.decode(
      UserDefaults.standard.data(forKey: KeyShortcut.storageKey) ?? Data()
    ).enumerated() {
      guard let combo = shortcut.key else { continue }
      let token = shortcut.expansion
      register(combo, id: UInt32(index + 2)) { [weak self] in self?.perform(token) }
    }
  }

  private func register(_ combo: KeyCombo, id: UInt32, run: @escaping () -> Void) {
    var ref: EventHotKeyRef?
    // Signature arbitraire mais stable ("TDYQ") : elle n'identifie nos hot keys qu'auprès de nous.
    let hotKeyID = EventHotKeyID(signature: 0x5444_5951, id: id)
    let status = RegisterEventHotKey(
      UInt32(combo.keyCode), Self.carbonModifiers(combo.flags), hotKeyID,
      GetApplicationEventTarget(), 0, &ref)
    // Échec = combinaison déjà prise par une autre app (Spotlight, etc.). Rien à faire ici : le
    // réglage reste affiché tel quel, l'utilisateur en choisira une autre en voyant que rien ne vient.
    guard status == noErr, let ref else { return }
    hotKeys.append(ref)
    actions[id] = run
  }

  private func installHandler() {
    guard handler == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let userData else { return noErr }
        // UN seul handler pour toutes les combinaisons : c'est l'identifiant porté par l'événement
        // qui dit laquelle a été frappée. Un handler par hot key coûterait une installation (et un
        // désenregistrement à ne pas rater) par ligne de réglage.
        var id = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        // Le handler Carbon est appelé sur la boucle d'exécution PRINCIPALE : l'action peut toucher
        // l'UI directement, sans saut de file.
        Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().actions[id.id]?()
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
