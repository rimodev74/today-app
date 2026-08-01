import AppKit

/// Une combinaison de touches, telle qu'enregistrée. `label` est calculé à la capture et STOCKÉ :
/// le réafficher demanderait de retraduire un code de touche en glyphe, ce qui dépend de la
/// disposition clavier active — celle du jour de la capture est la bonne réponse.
struct KeyCombo: Codable, Hashable {
  var keyCode: Int
  /// `NSEvent.ModifierFlags.rawValue` : le type d'AppKit n'est pas `Codable`.
  var modifiers: UInt
  var label: String

  var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
}

/// Raccourci texte : « ajd » puis Tab → « @today ». Il ne connaît AUCUNE action — il réécrit le
/// dernier mot en un jeton que `QuickEntry` sait déjà lire.
///
/// C'est le point du design : toute la résolution (dates relatives, correspondance de préfixe sur
/// les noms de listes, projet → sa première liste) reste au même endroit, et un nouveau type
/// d'action s'obtient en donnant un sigil au parseur, pas en touchant ici.
struct TextShortcut: Codable, Identifiable, Hashable {
  var id = UUID()
  /// Ce qu'on tape, sans sigil.
  var trigger: String
  /// Ce qui le remplace : un jeton `QuickEntry` (« @today », « #Courses »).
  var expansion: String
}

/// Le pendant clavier : la MÊME action (le même jeton), atteinte par une combinaison globale au lieu
/// d'une abréviation tapée dans la capsule.
///
/// Liste SÉPARÉE de `TextShortcut` et pas un champ de plus sur lui : les deux gestes se règlent dans
/// deux sections distinctes, et rien n'oblige une action à porter les deux — une combinaison sans
/// abréviation aurait laissé une colonne « déclencheur » vide, et réciproquement.
struct KeyShortcut: Codable, Identifiable, Hashable {
  var id = UUID()
  /// Même vocabulaire que `TextShortcut.expansion` : un jeton `QuickEntry` ou une `AppCommand`.
  var expansion: String
  /// `nil` tant que la ligne n'a pas reçu de combinaison — elle ne déclenche alors rien.
  var key: KeyCombo?
}

extension KeyShortcut {
  static let storageKey = "keyShortcuts"

  /// Aucun défaut, contrairement aux raccourcis texte : une combinaison globale prise d'office
  /// pourrait entrer en conflit avec celle d'une autre app, sans que personne ne l'ait demandée.
  static func decode(_ data: Data) -> [KeyShortcut] {
    (try? JSONDecoder().decode([KeyShortcut].self, from: data)) ?? []
  }

  static func encode(_ shortcuts: [KeyShortcut]) -> Data {
    (try? JSONEncoder().encode(shortcuts)) ?? Data()
  }
}

extension TextShortcut {
  static let storageKey = "textShortcuts"

  static let defaults: [TextShortcut] = [
    .init(trigger: "ajd", expansion: "@today"),
    .init(trigger: "dem", expansion: "@demain"),
    .init(trigger: "we", expansion: "@weekend"),
  ]

  /// `Data` vide = clé jamais écrite → les défauts. Une liste vidée à la main, elle, s'encode en
  /// « [] » : elle survit au relancement au lieu de voir les défauts ressusciter.
  static func decode(_ data: Data) -> [TextShortcut] {
    guard !data.isEmpty else { return defaults }
    return (try? JSONDecoder().decode([TextShortcut].self, from: data)) ?? defaults
  }

  static func encode(_ shortcuts: [TextShortcut]) -> Data {
    (try? JSONEncoder().encode(shortcuts)) ?? Data()
  }

  /// Les jetons de date proposés dans les réglages : un sous-ensemble de ce que `QuickEntry`
  /// accepte. « @+3 » et « @12/08 » restent tapables à la main dans le champ, ils n'ont juste rien
  /// à faire dans un menu déroulant.
  static let dateOptions: [(label: String, token: String)] = [
    ("Aujourd'hui", "@today"),
    ("Demain", "@demain"),
    ("Après-demain", "@apresdemain"),
    ("Ce week-end", "@weekend"),
    ("Lundi", "@lundi"),
    ("Mardi", "@mardi"),
    ("Mercredi", "@mercredi"),
    ("Jeudi", "@jeudi"),
    ("Vendredi", "@vendredi"),
    ("Samedi", "@samedi"),
    ("Dimanche", "@dimanche"),
  ]
}
