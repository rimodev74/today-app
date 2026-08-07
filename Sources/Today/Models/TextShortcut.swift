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

/// Régler un raccourci PAR ACTION, sans ouvrir un second stockage. Les réglages du Pomodoro
/// présentent cinq actions nommées ; l'onglet Raccourcis présente la même liste, par la ligne. Les
/// deux écrivent DANS la même liste, à la ligne qui porte ce jeton — sans ça, la même combinaison
/// aurait deux origines possibles et l'une des deux aurait fini par mentir.
///
/// Poser `nil` (ou une abréviation vide) RETIRE la ligne : une ligne sans déclencheur ne déclenche
/// rien, la garder ferait grossir la liste de l'onglet Raccourcis d'entrées invisibles.
extension Array where Element == KeyShortcut {
  func combo(for token: String) -> KeyCombo? {
    first { $0.expansion == token }?.key
  }

  mutating func setCombo(_ combo: KeyCombo?, for token: String) {
    guard let combo else {
      removeAll { $0.expansion == token }
      return
    }
    if let index = firstIndex(where: { $0.expansion == token }) {
      self[index].key = combo
    } else {
      append(KeyShortcut(expansion: token, key: combo))
    }
  }

  /// Recolle chaque `expansion` de liste à son titre COURANT (cf.
  /// `QuickEntry.reconciledListToken`). Appelée à chaque sauvegarde par `ContentView`, pas
  /// seulement quand les Réglages sont ouverts — sans quoi une combinaison globale posée sur
  /// « #Courses », la liste renommée « Achats » pendant que les Réglages sont fermés, continue de
  /// viser un nom qui n'existe plus jusqu'à leur prochaine ouverture.
  ///
  /// Une ligne dont AUCUN titre courant ne reconnaît le jeton est RETIRÉE — liste supprimée, ou
  /// renommée au point de perdre tout préfixe commun (cf. `QuickEntry.listTokenIsAlive`) : dans les
  /// deux cas la combinaison ne route plus nulle part, la garder ne ferait que grossir l'onglet
  /// Raccourcis d'une ligne morte.
  func reconciled(against listTitles: [String]) -> [KeyShortcut] {
    compactMap { shortcut in
      guard QuickEntry.listTokenIsAlive(shortcut.expansion, against: listTitles) else { return nil }
      var reconciled = shortcut
      reconciled.expansion = QuickEntry.reconciledListToken(shortcut.expansion, against: listTitles)
      return reconciled
    }
  }
}

extension Array where Element == TextShortcut {
  func trigger(for token: String) -> String {
    first { $0.expansion == token }?.trigger ?? ""
  }

  mutating func setTrigger(_ trigger: String, for token: String) {
    let trimmed = trigger.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      removeAll { $0.expansion == token }
      return
    }
    if let index = firstIndex(where: { $0.expansion == token }) {
      self[index].trigger = trimmed
    } else {
      append(TextShortcut(trigger: trimmed, expansion: token))
    }
  }

  /// Même correction que `[KeyShortcut].reconciled(against:)`, pour l'abréviation tapée dans la
  /// capsule : sans elle, « crs » ⇥ continue d'écrire « #Courses » — un jeton qu'aucune liste ne
  /// porte plus — au lieu de « #Achats ». Et même élagage des lignes mortes : sans lui, supprimer
  /// la liste « Courses » laissait « crs » ⇥ écrire « #Courses » en toutes lettres dans le titre de
  /// la tâche suivante — la ligne ne route plus nulle part, mais rien ne prévenait que le jeton
  /// restait tel quel dans le champ au lieu de se résoudre en destination.
  func reconciled(against listTitles: [String]) -> [TextShortcut] {
    compactMap { shortcut in
      guard QuickEntry.listTokenIsAlive(shortcut.expansion, against: listTitles) else { return nil }
      var reconciled = shortcut
      reconciled.expansion = QuickEntry.reconciledListToken(shortcut.expansion, against: listTitles)
      return reconciled
    }
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
    let decoded = (try? JSONDecoder().decode([TextShortcut].self, from: data)) ?? defaults
    return decoded.map(sanitized)
  }

  /// Un jeton `#liste` ne porte jamais d'espace (cf. `QuickEntry.fold`) : une version antérieure du
  /// menu de réglages écrivait le nom de la liste tel quel, espaces compris (« #Bugs / Modifications »),
  /// ce qui laissait les mots suivants tels quels dans le champ au lieu de les résoudre en destination.
  /// Réparé à la LECTURE plutôt qu'à l'écriture : une entrée déjà enregistrée dans les défauts d'un
  /// utilisateur se corrige d'elle-même, sans qu'il ait à la retoucher à la main.
  private static func sanitized(_ shortcut: TextShortcut) -> TextShortcut {
    guard shortcut.expansion.hasPrefix("#") else { return shortcut }
    var fixed = shortcut
    fixed.expansion = "#" + shortcut.expansion.dropFirst().filter { !$0.isWhitespace }
    return fixed
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
