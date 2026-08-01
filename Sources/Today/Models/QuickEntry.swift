import Foundation

/// Saisie rapide : « @demain #Courses Faire la vaisselle » → une tâche datée, rangée dans Courses.
///
/// Les jetons sont reconnus n'importe où dans la ligne, et un jeton NON reconnu reste tel quel dans
/// le titre : « écrire à jean@exemple.fr » ou « lire #42 » ne perdent rien. C'est pour ça que le
/// parseur reçoit les noms de destinations possibles (`names`) au lieu de deviner.
struct QuickEntry {
  let title: String
  /// Jour planifié, minuit (la saisie rapide ne porte pas d'heure — cf. `TaskItem.hasTime`).
  let when: Date?
  /// Nom exact tiré de `names`, à résoudre par l'appelant (liste ou projet).
  let target: String?

  init(
    parsing raw: String,
    names: [String] = [],
    now: Date = Date(),
    calendar: Calendar = .current
  ) {
    var when: Date?
    var target: String?
    var words: [Substring] = []

    for word in raw.split(whereSeparator: \.isWhitespace) {
      let token = String(word.dropFirst())
      if word.hasPrefix("@"), when == nil,
        let date = Self.date(token, now: now, calendar: calendar)
      {
        when = date
      } else if word.hasPrefix("#"), target == nil, let match = Self.match(token, in: names) {
        target = match
      } else {
        words.append(word)
      }
    }

    self.title = words.joined(separator: " ")
    self.when = when
    self.target = target
  }

  /// Saisie EN COURS : ne reconnaît que les jetons validés par un espace, et renvoie le texte à
  /// réafficher (jeton retiré) avec ce qui a été reconnu — `nil` s'il n'y a rien à consommer.
  /// Le dernier mot est laissé intact tant qu'aucun espace ne le suit : « @tod » reste corrigeable
  /// au clavier, on ne transforme rien sous les doigts de l'utilisateur.
  static func consuming(
    _ text: String,
    names: [String] = [],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> (text: String, entry: QuickEntry)? {
    guard let lastSpace = text.lastIndex(where: \.isWhitespace) else { return nil }
    let entry = QuickEntry(
      parsing: String(text[..<lastSpace]), names: names, now: now, calendar: calendar)
    guard entry.when != nil || entry.target != nil else { return nil }
    // `entry.title` est déjà nettoyé ; on lui recolle la fin non validée (espace + mot en cours).
    let rest = text[lastSpace...]
    let remaining =
      entry.title.isEmpty ? String(rest.drop(while: \.isWhitespace)) : entry.title + rest
    return (remaining, entry)
  }

  /// Raccourci texte validé par Tab. Renvoie ce qui PRÉCÈDE le déclencheur et le raccourci trouvé,
  /// parce que tous les raccourcis ne s'écrivent pas : un jeton de saisie rapide se recolle au
  /// texte (`applying`), une commande d'app (`!today`, cf. `AppCommand`) s'exécute et n'y laisse
  /// rien. Le parseur, lui, ne connaît que `@` et `#` — c'est à l'appelant de trancher.
  ///
  /// `nil` si le dernier mot n'est pas un déclencheur : Tab retourne alors à son usage normal
  /// (ouvrir les notes, passer au champ suivant) plutôt que d'être avalé.
  static func expanding(_ text: String, shortcuts: [TextShortcut])
    -> (before: String, shortcut: TextShortcut)?
  {
    let start = text.lastIndex(where: \.isWhitespace).map(text.index(after:)) ?? text.startIndex
    let word = fold(String(text[start...]))
    guard !word.isEmpty else { return nil }
    guard let shortcut = shortcuts.first(where: { fold($0.trigger) == word }) else { return nil }
    return (String(text[..<start]), shortcut)
  }

  /// Le texte à réafficher pour un raccourci qui S'ÉCRIT. L'espace final n'est pas cosmétique :
  /// c'est lui qui fait passer le jeton par `consuming`, donc la pastille apparaît par le chemin
  /// habituel. Il vit ici, en un seul endroit, plutôt que chez chaque appelant.
  static func applying(_ match: (before: String, shortcut: TextShortcut)) -> String {
    match.before + match.shortcut.expansion + " "
  }

  /// Le raccourci posé en fin de texte, résolu — l'entrée unique pour les vues. Un jeton se recolle
  /// au texte, une commande d'app en SORT pour que l'appelant l'exécute lui-même (le modèle ne
  /// bouge pas de fenêtre).
  ///
  /// Passe par ici tout ce qui valide une saisie, pas seulement ⇥ : Entrée doit reconnaître un
  /// raccourci elle aussi, sinon « op » seul part en tâche nommée « op » au lieu d'ouvrir la page
  /// demandée. `nil` = pas de raccourci en fin de texte, l'appelant garde sa touche.
  static func resolving(_ text: String, shortcuts: [TextShortcut]) -> (
    text: String, command: AppCommand?
  )? {
    guard let match = expanding(text, shortcuts: shortcuts) else { return nil }
    guard let command = AppCommand(token: match.shortcut.expansion) else {
      return (applying(match), nil)
    }
    return (match.before, command)
  }

  // MARK: Destinations

  /// Comparaison insensible à la casse, aux accents ET aux espaces : `#malist` trouve « Ma Liste »
  /// (un jeton ne peut pas contenir d'espace). Préfixe accepté, premier gagnant.
  // ponytail: pas de désambiguïsation si deux listes commencent pareil — l'appelant ordonne.
  private static func match(_ token: String, in names: [String]) -> String? {
    guard !token.isEmpty else { return nil }
    let key = fold(token)
    return names.first { fold($0) == key } ?? names.first { fold($0).hasPrefix(key) }
  }

  private static func fold(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .filter { !$0.isWhitespace }
  }

  // MARK: Dates

  private static let weekdays: [String: Int] = [
    "dimanche": 1, "sunday": 1,
    "lundi": 2, "monday": 2,
    "mardi": 3, "tuesday": 3,
    "mercredi": 4, "wednesday": 4,
    "jeudi": 5, "thursday": 5,
    "vendredi": 6, "friday": 6,
    "samedi": 7, "saturday": 7,
  ]

  private static func date(_ token: String, now: Date, calendar: Calendar) -> Date? {
    let today = calendar.startOfDay(for: now)
    let key = fold(token)

    switch key {
    case "today", "aujourdhui", "auj", "ajd":
      return today
    case "tomorrow", "demain", "dem":
      return calendar.date(byAdding: .day, value: 1, to: today)
    case "apresdemain":
      return calendar.date(byAdding: .day, value: 2, to: today)
    case "weekend", "we":
      return next(7, from: today, calendar: calendar)
    default:
      break
    }

    if let weekday = weekdays[key] { return next(weekday, from: today, calendar: calendar) }

    // « +3 » / « +3j » : dans N jours.
    if key.hasPrefix("+"), let days = Int(key.dropFirst().prefix(while: \.isNumber)) {
      return calendar.date(byAdding: .day, value: days, to: today)
    }

    return numeric(key, today: today, calendar: calendar)
  }

  /// Prochaine occurrence STRICTE : « @lundi » un lundi vise le lundi suivant — pour aujourd'hui il
  /// y a « @today ».
  private static func next(_ weekday: Int, from today: Date, calendar: Calendar) -> Date? {
    var delta = (weekday - calendar.component(.weekday, from: today) + 7) % 7
    if delta == 0 { delta = 7 }
    return calendar.date(byAdding: .day, value: delta, to: today)
  }

  /// « 12/08 » (prochaine occurrence) ou « 12/08/2026 ». Les bornes sont vérifiées à la main :
  /// `Calendar.date(from:)` accepte le mois 13 et le reporte sur l'année suivante au lieu d'échouer.
  private static func numeric(_ key: String, today: Date, calendar: Calendar) -> Date? {
    let parts = key.split(separator: "/")
    guard (2...3).contains(parts.count) else { return nil }
    let numbers = parts.compactMap { Int($0) }
    guard numbers.count == parts.count, (1...31).contains(numbers[0]),
      (1...12).contains(numbers[1])
    else { return nil }

    var components = DateComponents()
    components.day = numbers[0]
    components.month = numbers[1]
    components.year =
      numbers.count == 3
      ? (numbers[2] < 100 ? 2000 + numbers[2] : numbers[2])
      : calendar.component(.year, from: today)

    guard let date = calendar.date(from: components) else { return nil }
    guard numbers.count == 2, date < today else { return date }
    return calendar.date(byAdding: .year, value: 1, to: date)
  }
}
