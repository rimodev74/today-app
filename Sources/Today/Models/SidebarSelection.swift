import SwiftData
import SwiftUI

extension TodoList {
  /// Une liste vide et sans raccourci s'efface sans rien demander ; dès qu'elle porte des tâches
  /// OU qu'un raccourci la vise, l'appelant doit confirmer d'abord — sans quoi une liste neuve à
  /// peine créée, juste rattachée à une abréviation, part avec elle sans qu'on ait pu le voir.
  var needsDeleteConfirmation: Bool { !tasks.isEmpty || linkedShortcutLabel != nil }

  /// Le déclencheur texte ou la combinaison globale qui vise CETTE liste, s'il y en a un — lu
  /// directement dans `UserDefaults` (même contournement que `autoSortCompletedEnabled` ci-dessous :
  /// ce fichier ne connaît pas de contexte SwiftUI). Même résolution que
  /// `[TextShortcut].reconciled(against:)`, réduite à ce seul titre.
  private var linkedShortcutLabel: String? {
    guard !title.isEmpty else { return nil }
    let token = "#" + title.filter { !$0.isWhitespace }
    if let trigger = TextShortcut.decode(
      UserDefaults.standard.data(forKey: TextShortcut.storageKey) ?? Data()
    ).first(where: { QuickEntry.reconciledListToken($0.expansion, against: [title]) == token })?
      .trigger {
      return "« \(trigger) »"
    }
    if let combo = KeyShortcut.decode(
      UserDefaults.standard.data(forKey: KeyShortcut.storageKey) ?? Data()
    ).first(where: { QuickEntry.reconciledListToken($0.expansion, against: [title]) == token })?
      .key {
      return combo.label
    }
    return nil
  }

  /// Ce que l'alerte annonce. Ici et pas dans une vue : deux alertes la posent (sidebar, carte
  /// d'un projet), et deux textes auraient fini par ne plus dire la même chose.
  var deleteConfirmationMessage: String {
    let name = title.isEmpty ? "Cette liste" : "« \(title) »"
    var message: String
    if tasks.isEmpty {
      message = "\(name) sera supprimée."
    } else {
      let n = tasks.count
      message = "\(name) contient \(n) tâche\(n > 1 ? "s" : ""). Elles seront aussi supprimées."
    }
    if let label = linkedShortcutLabel {
      message += " Son raccourci \(label) sera aussi retiré."
    }
    return message
  }

  /// LA suppression d'une liste, pour les trois endroits qui l'offrent (clic droit dans la
  /// sidebar, menu ••• de la page, menu d'une carte de projet). Deux l'écrivaient chacun de leur
  /// côté, et le second à l'avoir écrit ne savait rien du premier.
  ///
  /// La sélection quitte la page AVANT l'effacement : rendue après, elle s'adosse à un modèle
  /// effacé — SwiftData sert alors l'ancien instantané au lieu de planter, et on tape dans le vide.
  /// Écriture explicite comme partout dans l'app : l'autosave laissait une fenêtre où la cascade
  /// (une liste emporte ses tâches) n'était pas encore sur le disque.
  /// `forget` reçoit les tâches que la cascade va emporter, AVANT qu'elles ne disparaissent : c'est
  /// la seule fenêtre où leurs rappels Apple sont encore lisibles. Sans lui, les rappels restaient
  /// derrière, orphelins, et réapparaissaient dans les sections « Rappels » de l'app (cf.
  /// `RemindersService.forgetReminders(_:)`).
  ///
  /// **Sans valeur par défaut, délibérément.** Ce code vit dans `Models/`, qui ne connaît pas le
  /// service ; le brancher revient donc à ne pas l'oublier sur CHACUN des quatre appelants. Un
  /// défaut à `{ _ in }` aurait laissé l'oubli compiler sans un mot — exactement le défaut que
  /// `TaskPageBase.reorder` et `newTask` documentent, et qui s'est déjà produit deux fois ici.
  func delete(
    from selection: Binding<SidebarSelection?>, in context: ModelContext,
    forgetReminders: ([String]) -> Void
  ) {
    // Des IDENTIFIANTS, pas des tâches : de simples chaînes, qui survivent à ce que la cascade
    // efface. Lues ici, tant que tout est debout.
    let doomedReminders = tasks.compactMap(\.reminderIdentifier)
    if selection.wrappedValue == .list(self) {
      selection.wrappedValue = project.map(SidebarSelection.project) ?? .smartList(.all)
    }
    // `deleteCascadeAndSave` et pas `delete` + `save` : une liste emporte ses tâches, qui emportent
    // leurs sous-tâches, et l'`UndoManager` branché sur le contexte fait tomber SwiftData pendant
    // l'enregistrement. Le pourquoi, avec la mesure, est en tête du helper.
    context.deleteCascadeAndSave(self)
    // APRÈS l'enregistrement, jamais pendant : effacer un rappel fait écrire EventKit, qui poste sa
    // notification de changement, qui relance la synchro, qui réenregistre CE contexte. Écrire dans
    // un contexte pendant qu'on l'enregistre n'a rien à faire là — mais ce n'est PAS ce qui faisait
    // planter l'app le 6 août 2026 : la vraie cause était l'annulation, cf. `deleteCascadeAndSave`.
    forgetReminders(doomedReminders)
  }
}

enum SmartList: Hashable, CaseIterable {
  case all
  case today
  case upcoming
  case archive

  var label: String {
    switch self {
    case .all: return "Tâches"
    case .today: return "Aujourd'hui"
    case .upcoming: return "À venir"
    case .archive: return "Archives"
    }
  }

  var systemImage: String {
    switch self {
    case .all: return "square.stack.fill"
    case .today: return "star.fill"
    case .upcoming: return "calendar"
    case .archive: return "checkmark.square.fill"
    }
  }

  var color: Color {
    switch self {
    case .all: return .teal
    case .today: return .yellow
    case .upcoming: return .red
    case .archive: return .green
    }
  }
}

enum SidebarSelection: Hashable {
  case smartList(SmartList)
  case project(Project)
  case list(TodoList)
  case pomodoro
}

/// Les bornes de date d'un filtrage, calculées UNE fois pour toute une liste de tâches.
///
/// Sans elles, `scopeMatches` reconstruisait un `Calendar` et le début de demain à CHAQUE tâche —
/// mesuré à 40 % du coût du filtre sur une page. Elles rendent aussi la date injectable : les
/// périmètres « aujourd'hui » et « à venir » ne se testaient jusque-là que par rapport à l'heure
/// réelle de la machine.
struct DayBounds {
  let calendar: Calendar
  let now: Date
  let startOfToday: Date
  let startOfTomorrow: Date

  init(now: Date = Date(), calendar: Calendar = .current) {
    self.calendar = calendar
    self.now = now
    startOfToday = calendar.startOfDay(for: now)
    // Repli plutôt que force-unwrap : `date(byAdding:)` ne rend `nil` pour aucune date qu'on peut
    // représenter, mais la garantie n'a pas besoin d'un `!` pour tenir.
    startOfTomorrow =
      calendar.date(byAdding: .day, value: 1, to: startOfToday)
      ?? startOfToday.addingTimeInterval(86_400)
  }
}

extension SmartList {
  /// Une tâche appartient-elle à cette liste, indépendamment de son statut isCompleted ?
  ///
  /// Les bornes se passent en paramètre pour être calculées une fois par filtrage (cf. `DayBounds`)
  /// ; le défaut garde l'appel à une tâche isolée lisible.
  func scopeMatches(_ task: TaskItem, _ bounds: DayBounds = DayBounds()) -> Bool {
    guard !task.isHeader else { return false }
    let calendar = bounds.calendar
    let startOfTomorrow = bounds.startOfTomorrow
    switch self {
    case .all, .archive: return true
    // Le JOUR même, ni avant ni après. Une tâche datée d'hier et non faite quitte donc
    // « Aujourd'hui » au passage de minuit : elle retourne dans sa liste ou son projet (l'Inbox
    // pour une tâche libre), d'où on la reprogramme d'un « Quand… » si on la veut encore.
    // Volontairement SANS repêchage des retards : « Aujourd'hui » ne montre que ce qu'on a
    // décidé de faire aujourd'hui, pas l'accumulation des jours précédents.
    case .today: return task.when.map { calendar.isDate($0, inSameDayAs: bounds.now) } ?? false
    case .upcoming: return task.when.map { $0 >= startOfTomorrow } ?? false
    }
  }

  /// ponytail: filtrage en mémoire tant que le volume reste petit — passer en #Predicate si lent.
  func filter(_ all: [TaskItem], _ bounds: DayBounds = DayBounds()) -> [TaskItem] {
    switch self {
    case .archive:
      return all.filter { $0.isCompleted && !$0.isHeader }
    default:
      return all.filter { !$0.isCompleted && scopeMatches($0, bounds) }
    }
  }

  /// Ce qu'affichent la page « Aujourd'hui » et sa section homonyme dans « Tâches » : le périmètre
  /// du jour, tâches COCHÉES COMPRISES — elles restent barrées à leur place jusqu'à minuit, où
  /// leur `when` cesse d'être aujourd'hui et les fait sortir d'elles-mêmes. `filter` reste la
  /// version « ce qui reste à faire » (badge de la sidebar).
  func scoped(_ all: [TaskItem], _ bounds: DayBounds = DayBounds()) -> [TaskItem] {
    all.filter { scopeMatches($0, bounds) }
  }

  /// Ordre d'affichage.
  ///
  /// **L'ordre manuel gagne** : ce qu'on a placé à la main (`TaskItem.smartOrder`) passe avant tout
  /// le reste. C'est le comportement de Things, et la raison d'être de la page « Aujourd'hui » —
  /// on planifie sa journée en glissant, pas en ajustant des priorités jusqu'à ce que le tri
  /// automatique tombe juste.
  ///
  /// Le tri automatique (priorité, puis date, puis création) ne disparaît pas : il PLACE ce qui
  /// n'a jamais été touché à la main. Une tâche qui arrive sur la page porte `smartOrder == 0` et
  /// se range donc après les placées, à l'endroit que la règle lui donne — pas au hasard, et sans
  /// bousculer un ordre choisi.
  func sort(_ tasks: [TaskItem]) -> [TaskItem] {
    if self == .archive {
      return sortedByKey(
        tasks, key: { $0.completedAt ?? .distantPast }, areInIncreasingOrder: >)
    }
    // Réglage « Descendre en bas de la liste », lu UNE fois. Dans le comparateur, c'était une
    // interrogation des défauts par COMPARAISON — n log n accès pour une valeur qui ne bouge pas
    // pendant un tri.
    let autoSortCompleted = TodoList.autoSortCompletedEnabled
    // Les cinq clés, lues une fois par tâche (cf. `sortedByKey` : ×7 mesuré). Elles sont rangées
    // dans l'ordre de priorité de la règle, et TOURNÉES pour que le `<` naturel du tuple dise
    // exactement ce que disaient les `if` d'avant :
    // 1. cochée en dernier — `false` (0) avant `true` (1), et seulement si le réglage est actif ;
    // 2. ordre manuel — 0 = jamais posée à la main, donc après toutes celles qui l'ont été ;
    // 3. priorité DÉCROISSANTE, d'où le signe moins ;
    // 4. date planifiée, la plus proche d'abord, non datée à la fin ;
    // 5. création — départage les ex æquo, et rend l'ordre totalement déterminé.
    return sortedByKey(
      tasks,
      key: { task -> (Int, Int, Int, Date, Date) in
        (
          autoSortCompleted && task.isCompleted ? 1 : 0,
          task.smartOrder == 0 ? Int.max : task.smartOrder,
          -task.priorityRaw,
          task.when ?? .distantFuture,
          task.createdAt
        )
      },
      areInIncreasingOrder: <)
  }
}
