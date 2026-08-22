import Foundation

/// Saisie rapide : « @demain #Courses Faire la vaisselle » → une tâche datée, rangée dans Courses.
///
/// Les jetons sont reconnus n'importe où dans la ligne, et un jeton NON reconnu reste tel quel dans
/// le titre : « écrire à jean@exemple.fr » ou « lire #42 » ne perdent rien. C'est pour ça que le
/// parseur reçoit les noms de destinations possibles (`names`) au lieu de deviner.
struct QuickEntry {
  let title: String
  /// Jour planifié, minuit — l'heure est à côté (`minutes`), jamais dedans (cf. `TaskItem.when`).
  let when: Date?
  /// Heure planifiée en minutes depuis minuit (cf. `TaskItem.whenMinutes`), tirée d'un SECOND jeton
  /// `@` : « @demain @14h30 ». Deux jetons indépendants, dans n'importe quel ordre, plutôt qu'une
  /// syntaxe composée — c'est ce qui laisse poser l'heure seule, ou la changer sans retoucher le jour.
  let minutes: Int?
  /// Nom exact tiré de `names`, à résoudre par l'appelant (liste ou projet).
  let target: String?

  init(
    parsing raw: String,
    names: [String] = [],
    now: Date = Date(),
    calendar: Calendar = .current
  ) {
    var when: Date?
    var minutes: Int?
    var target: String?
    var words: [Substring] = []

    for word in raw.split(whereSeparator: \.isWhitespace) {
      let token = String(word.dropFirst())
      if word.hasPrefix("@"), when == nil,
        let date = Self.date(token, now: now, calendar: calendar)
      {
        when = date
      } else if word.hasPrefix("@"), minutes == nil, let time = Self.time(token) {
        minutes = time
      } else if word.hasPrefix("#"), target == nil, let match = Self.match(token, in: names) {
        target = match
      } else {
        words.append(word)
      }
    }

    self.title = words.joined(separator: " ")
    self.when = when
    self.minutes = minutes
    self.target = target
  }

  /// Le jour qu'IMPLIQUE une heure posée sans date : aujourd'hui, même s'il est déjà passé — on lit
  /// ce qui a été tapé, pas ce qu'on aurait voulu dire. Sans ça une tâche sortirait avec une heure
  /// et aucun jour, donc invisible partout (`TaskRow.dateTag` n'affiche l'heure que datée).
  ///
  /// Ici et pas dans l'init : le jour peut venir d'AILLEURS que du texte (le menu calendrier de la
  /// capsule, une pastille déjà posée), et l'init ne le voit pas. C'est l'appelant qui a l'état
  /// complet — cette fonction lui évite d'écrire la règle deux fois.
  static func day(
    _ when: Date?, minutes: Int?, now: Date = Date(), calendar: Calendar = .current
  ) -> Date? {
    guard when == nil, minutes != nil else { return when }
    return calendar.startOfDay(for: now)
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
    guard entry.when != nil || entry.minutes != nil || entry.target != nil else { return nil }
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

  /// Un jeton `#Ancien` dont la LISTE a été renommée depuis, réconcilié contre les titres
  /// COURANTS — même résolution que `match`, ci-dessus. Sert aux Réglages (`ActionPicker`) : son
  /// menu suit le titre courant d'une liste, mais un raccourci déjà enregistré garde le nom du
  /// jour où il a été posé tant que rien ne le retouche — sans réconciliation, le menu ne retrouve
  /// alors plus aucune option pour lui et la ligne semble orpheline.
  ///
  /// Rend le jeton tel quel s'il ne vise pas une liste (`@today`, `!today`), ou si aucun titre
  /// courant ne s'y retrouve (liste supprimée, ou déjà à jour).
  static func reconciledListToken(_ token: String, against listTitles: [String]) -> String {
    guard token.hasPrefix("#") else { return token }
    guard let name = match(String(token.dropFirst()), in: listTitles) else { return token }
    return "#" + name.filter { !$0.isWhitespace }
  }

  /// `false` seulement pour un jeton `#Nom` qu'AUCUN titre courant ne reconnaît : liste supprimée,
  /// ou renommée au point de perdre tout préfixe commun avec son nom d'origine. Un jeton de date ou
  /// de commande (`@today`, `!today`) est toujours vivant — il ne vise aucune liste.
  ///
  /// Sert à ÉLAGUER les raccourcis (cf. `[TextShortcut].reconciled(against:)`), pas à les
  /// réafficher : `reconciledListToken`, ci-dessus, reste la version qui rend le jeton tel quel,
  /// pour le `Picker` des Réglages qui doit continuer de montrer une valeur même orpheline.
  static func listTokenIsAlive(_ token: String, against listTitles: [String]) -> Bool {
    guard token.hasPrefix("#") else { return true }
    return match(String(token.dropFirst()), in: listTitles) != nil
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

  /// « 14h », « 14h30 », « 14:30 », « 9h05 ». Un séparateur est EXIGÉ : « @14 » nu reste du texte,
  /// il ressemble trop à ce qu'on écrit dans une phrase (« @14 rue des Lilas »). Pas d'am/pm —
  /// l'app est en français, et « @2pm » n'y a jamais été tapé.
  private static func time(_ token: String) -> Int? {
    let key = fold(token)
    guard let separator = key.firstIndex(where: { $0 == "h" || $0 == ":" }) else { return nil }
    guard let hour = Int(key[..<separator]), (0...23).contains(hour) else { return nil }
    let tail = key[key.index(after: separator)...]
    guard !tail.isEmpty else { return hour * 60 }  // « 14h »
    guard tail.count <= 2, let minute = Int(tail), (0...59).contains(minute) else { return nil }
    return hour * 60 + minute
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
