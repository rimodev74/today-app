import Foundation

/// Ce que la capsule propose sous sa barre, et ce que ↩ en fait.
///
/// ## Le principe : c'est la LIGNE qui porte l'action
///
/// Pas une touche à mémoriser, pas un mode invisible — le modèle de Raycast. Une même touche ne
/// peut donc jamais vouloir dire deux choses selon un état qu'on ne voit pas.
///
/// C'est la correction d'un défaut mesuré : la capsule supposait qu'on était TOUJOURS en train de
/// composer une tâche. Tant qu'elle n'affichait rien, c'était vrai. Dès qu'elle a listé des choses,
/// chaque touche est devenue ambiguë — Tab répondait « ouvre les notes de la tâche en cours »
/// alors qu'on regardait une autre tâche.
///
/// ## Pourquoi c'est une valeur et pas du code de vue
///
/// Même raison que `TodayPage` : mêlé à `@State` et `@Query`, ce classement ne se vérifierait qu'en
/// tapant dans une fenêtre flottante par-dessus une autre app — c'est-à-dire jamais. Ici un test
/// lui donne des listes, des dossiers et une frappe, et lit ce que la capsule doit montrer.
struct QuickPalette {

  // MARK: Ce qu'une ligne déclenche

  /// Où atterrit une tâche ajoutée depuis la palette.
  ///
  /// Un DOSSIER n'en fait pas partie : son action à lui est de créer une liste. Une tâche se pose
  /// toujours dans une liste (`TaskItem.project` se déduit de `list?.project`), jamais dans un
  /// dossier directement.
  enum TaskTarget: Equatable {
    /// « Tâches » — la boîte de réception, sans date.
    case inbox
    /// « Aujourd'hui » — la boîte de réception, datée du jour. C'est le seul sens que « ajouter à
    /// Aujourd'hui » puisse avoir : le jour est une DATE portée par la tâche, pas un rangement.
    case today
    case list(TodoList)

    /// La liste où écrire et la date à poser. `lists` sert à retrouver la boîte de réception, que
    /// ce type ne peut pas connaître seul.
    func resolve(in lists: [TodoList], now: Date = Date(), calendar: Calendar = .current) -> (
      list: TodoList?, when: Date?
    ) {
      switch self {
      case .inbox: return (lists.first(where: \.isInbox), nil)
      case .today: return (lists.first(where: \.isInbox), calendar.startOfDay(for: now))
      case .list(let list): return (list, nil)
      }
    }

    /// Ce que le chip de la seconde étape affiche.
    var label: String {
      switch self {
      case .inbox: return SmartList.all.label
      case .today: return SmartList.today.label
      case .list(let list): return list.title.isEmpty ? "Sans titre" : list.title
      }
    }
  }

  /// L'état du minuteur, vu par la palette. Un instantané de VALEURS et pas `PomodoroTimer` : ce
  /// type se vérifie sans fenêtre ni singleton, et c'est tout son intérêt (cf. l'en-tête).
  struct PomodoroSnapshot: Equatable {
    let phaseLabel: String
    let remaining: String
    /// Une phase ATTEND qu'on la lance : engagée, arrêtée. C'est le seul état où la reprise a un
    /// sens — sinon « Lancer un pomodoro » (rien n'a commencé) ou « Mettre en pause » (ça tourne).
    let isWaiting: Bool
  }

  enum Action {
    /// Demande un titre : la capsule passe à sa seconde étape.
    case addTask(TaskTarget)
    /// Demande un nom : même seconde étape, autre chose à écrire.
    case createList(Project)
    /// Immédiat.
    case complete(TaskItem)
    /// Immédiat.
    case run(AppCommand)
    /// Immédiat : lance la phase qui ATTEND. Aucune commande ne sait le faire — `pomodoroStart`
    /// rouvre un travail, les deux autres ouvrent une pause neuve ; après une fin d'étape sans
    /// enchaînement, ce qui attend est une pause déjà prête, qu'il ne faut ni rouvrir ni passer.
    case startPomodoro

    /// Ce que la ligne annonce à droite. C'est la promesse de ↩, écrite noir sur blanc — sans elle,
    /// le principe « la ligne porte l'action » ne se devine qu'à l'usage.
    var label: String {
      switch self {
      case .addTask: return "Ajouter une tâche"
      case .createList: return "Créer une liste"
      case .complete: return "Valider"
      case .run, .startPomodoro: return "Lancer"
      }
    }
  }

  // MARK: Une ligne

  /// Volontairement PLATE, et pas une énumération à valeurs associées : la vue rend toutes les
  /// lignes de la même façon et n'a rien à démêler. Tout ce qu'elle affiche est lu ICI, une fois —
  /// une rangée qui lirait `task.list?.title` elle-même traverserait SwiftData à chaque rendu, le
  /// piège mesuré sur `SidebarView` (cf. `SidebarCounts`).
  struct Row: Identifiable {
    let id: AnyHashable
    let title: String
    /// La nature, à gauche de l'action : « Vue », « Dossier », « Liste », « Tâche », « Pomodoro ».
    /// C'est ce qui rend l'action prévisible AVANT de la déclencher.
    let kind: String
    let systemImage: String
    /// Le complément propre à la nature : la date d'une tâche, le nombre de listes d'un dossier.
    let detail: String?
    let isCompleted: Bool
    let action: Action
    /// L'endroit que ⌘↩ ouvre DANS l'app — le pendant « aller voir » de l'action, qui, elle, « fait
    /// ici ». Porté par la LIGNE et pas déduit de l'action : celle d'une tâche demande de traverser
    /// `task.list`, une lecture SwiftData qui n'a rien à faire dans un rendu de rangée.
    ///
    /// `nil` sur une commande seule : elle n'emmène nulle part qu'un onglet puisse montrer.
    let destination: SidebarSelection?
  }

  let rows: [Row]

  var isEmpty: Bool { rows.isEmpty }

  /// Le plafond de lignes. Le panneau a une hauteur FIXE et ne se redimensionne jamais (cf.
  /// `QuickEntryWindow.makePanel`) : au-delà, le bloc déborderait de la fenêtre.
  // ponytail: coupe franche, sans défilement — passer le panneau en `setFrame` animé le jour où la
  // limite gêne à l'usage.
  static let limit = 7

  /// Les commandes sont bornées AVANT le mélange : cinq libellés commencent par « Afficher », et
  /// sans borne une frappe d'une lettre remplissait la palette de commandes.
  ///
  /// Cinq et pas trois, parce que « pomodoro » doit sortir les CINQ actions du minuteur — c'est ce
  /// mot-là qu'on tape pour les atteindre toutes, et en couper deux rendait les pauses
  /// introuvables autrement que par leur nom exact.
  static let commandLimit = 5

  // MARK: La recherche

  /// Ce que la barre propose pour une frappe donnée.
  ///
  /// **Frappe vide → RIEN.** La capsule s'ouvre sur une barre nue, comme Spotlight : elle ne
  /// propose que ce qu'on lui a demandé. Une liste posée d'office serait du bruit à écarter avant
  /// même d'avoir tapé, et donnerait à ↩ une action qu'on n'a pas choisie.
  ///
  /// « À venir » et « Archives » ne sont jamais proposés comme endroits, et c'est un choix : on
  /// n'y AJOUTE rien (l'une est définie par une date future, l'autre par la complétion). Elles
  /// restent atteignables par les commandes « Afficher À venir » / « Afficher Archives ».
  /// `pomodoro` vaut `nil` quand il n'y a rien à en dire — c'est le défaut, et c'est le cas de la
  /// plupart des appels : un minuteur au repos ne propose rien de plus que ses commandes.
  static func search(
    _ query: String, lists: [TodoList], projects: [Project], tasks: [TaskItem],
    pomodoro: PomodoroSnapshot? = nil
  ) -> QuickPalette {
    let needle = fold(query)
    guard !needle.isEmpty else { return QuickPalette(rows: []) }

    // La ligne n'est PAS construite ici : on ne garde que de quoi la fabriquer. Une ligne coûte
    // cher — `projectRow` trie les listes du dossier, `listRow` traverse la relation, `taskRow`
    // formate une date — et à ce stade on ignore encore laquelle sera coupée. On classe des
    // clés, on ne fabrique que ce qui s'affiche (même motif que `matchingTasks` avant lui).
    var scored: [(make: () -> Row, quality: Int, weight: Int, index: Int)] = []
    var index = 0
    func offer(_ haystacks: [String], weight: Int, row: @escaping @autoclosure () -> Row) {
      defer { index += 1 }
      let folded = haystacks.map(fold)
      guard let best = folded.compactMap({ quality(of: $0, for: needle) }).min() else { return }
      scored.append((row, best, weight, index))
    }

    // Les vues d'abord, les tâches en dernier : à qualité de correspondance égale, on vise
    // beaucoup plus souvent un endroit qu'une ligne précise.
    offer([SmartList.all.label], weight: 0, row: smartRow(.all, target: .inbox))
    offer([SmartList.today.label], weight: 0, row: smartRow(.today, target: .today))
    for project in projects {
      offer([project.title], weight: 1, row: projectRow(project))
    }
    // La boîte de réception est déjà représentée par « Tâches » : la proposer une seconde fois
    // sous son nom de liste donnerait deux lignes pour un seul endroit. Et une liste SANS dossier
    // n'apparaît nulle part dans la sidebar (cf. `reachable`) — il en traîne d'anciennes en base,
    // y déposer une tâche la rendrait introuvable.
    for list in lists where !list.isInbox && list.project != nil {
      offer([list.title], weight: 2, row: listRow(list))
    }
    for task in tasks where !task.isHeader {
      offer([task.title], weight: taskWeight, row: taskRow(task))
    }

    let places = scored.sorted {
      ($0.quality, $0.weight, $0.index) < ($1.quality, $1.weight, $1.index)
    }

    // Les commandes sont classées à part : leur borne leur est propre, et les mêler au tri général
    // ferait sortir les tâches dès qu'une frappe touche plusieurs libellés.
    let commands =
      AppCommand.allCases
      .compactMap { command -> (AppCommand, Int)? in
        guard
          let best = ([command.label] + command.keywords)
            .compactMap({ quality(of: fold($0), for: needle) }).min()
        else { return nil }
        return (command, best)
      }
      .sorted { $0.1 < $1.1 }
      .prefix(commandLimit)
      .map { pair in { commandRow(pair.0) } }

    // La reprise passe DEVANT les cinq commandes : c'est la seule qui sache ce qui attend, les
    // autres proposent d'ouvrir autre chose. Elle se cherche aussi par le nom de sa phase — après
    // un travail, on tape « pause » aussi souvent que « pomodoro ».
    var commandMakers = commands
    if let pomodoro, pomodoro.isWaiting,
      ["reprendre", "pomodoro", "minuteur", pomodoro.phaseLabel]
        .compactMap({ quality(of: fold($0), for: needle) }).min() != nil
    {
      commandMakers.insert({ resumeRow(pomodoro) }, at: 0)
    }

    // Elles se glissent AVANT les tâches et après les endroits : ce sont des actions, elles se
    // rangent avec ce qui emmène quelque part, pas avec le contenu. Le POIDS suffit à trouver la
    // frontière — inutile de construire une ligne pour lire sa nature.
    var makers = places.map(\.make)
    makers.insert(
      contentsOf: commandMakers, at: places.firstIndex { $0.weight == taskWeight } ?? places.count)
    return QuickPalette(rows: makers.prefix(limit).map { $0() })
  }

  /// Le poids d'une tâche dans le classement. Nommé parce qu'il sert DEUX fois : à ranger, et à
  /// trouver où insérer les commandes.
  private static let taskWeight = 4

  /// La SECONDE étape : ce que le contenant choisi porte déjà, en contexte sous la barre où l'on
  /// écrit. On peut y cocher, rien d'autre — l'action de la barre, elle, est d'ajouter.
  static func inside(_ target: TaskTarget, lists: [TodoList], tasks: [TaskItem]) -> QuickPalette {
    let scoped: [TaskItem]
    switch target {
    case .inbox: scoped = lists.first(where: \.isInbox)?.orderedTasks ?? []
    case .today: scoped = TodayPage.build(from: tasks).tasks
    case .list(let list): scoped = list.orderedTasks
    }
    return QuickPalette(rows: scoped.filter { !$0.isHeader }.prefix(limit).map(taskRow))
  }

  /// La seconde étape d'un DOSSIER : ses listes. La barre en crée une nouvelle, et chaque ligne
  /// permet d'entrer dans une existante — sans quoi choisir un dossier obligeait à relancer une
  /// recherche pour atteindre ce qu'il contient, ce qui vidait le geste de son sens.
  static func inside(project: Project) -> QuickPalette {
    QuickPalette(rows: project.orderedLists.prefix(limit).map(listRow))
  }

  // MARK: Les lignes, par nature

  private static func smartRow(_ smart: SmartList, target: TaskTarget) -> Row {
    Row(
      id: AnyHashable("smart-" + smart.label), title: smart.label, kind: "Vue",
      systemImage: smart.systemImage, detail: nil, isCompleted: false,
      action: .addTask(target), destination: .smartList(smart))
  }

  private static func projectRow(_ project: Project) -> Row {
    let lists = project.orderedLists
    return Row(
      id: AnyHashable(project.uuid),
      title: project.title.isEmpty ? "Sans titre" : project.title, kind: "Dossier",
      systemImage: "folder",
      detail: lists.isEmpty ? nil : "\(lists.count) liste\(lists.count > 1 ? "s" : "")",
      isCompleted: false, action: .createList(project), destination: .project(project))
  }

  private static func listRow(_ list: TodoList) -> Row {
    Row(
      id: AnyHashable(list.uuid), title: list.title.isEmpty ? "Sans titre" : list.title,
      kind: "Liste", systemImage: "list.bullet", detail: list.project?.title, isCompleted: false,
      action: .addTask(.list(list)), destination: .list(list))
  }

  /// La case COCHÉE, pas un cercle : la ligne dit déjà l'état de la tâche par son titre barré, et
  /// une case vide à côté se lisait comme un démenti.
  ///
  /// ⌘↩ y ouvre la LISTE qui la porte — c'est l'endroit le plus proche qu'un onglet sache montrer,
  /// et déjà ce que fait la recherche de l'app (cf. `QuickFindPanel`).
  private static func taskRow(_ task: TaskItem) -> Row {
    Row(
      id: AnyHashable(task.uuid), title: task.title.isEmpty ? "Sans titre" : task.title,
      kind: "Tâche", systemImage: task.isCompleted ? "checkmark.circle.fill" : "circle",
      detail: task.when?.formatted(.dateTime.day().month(.abbreviated)),
      isCompleted: task.isCompleted, action: .complete(task),
      destination: task.list.map { .list($0) })
  }

  /// La ligne qui lance ce qui attend. Son titre porte la PHASE, pas un verbe seul : « Reprendre »
  /// sans dire quoi obligerait à se souvenir d'où l'on en était, ce que la capsule existe pour
  /// éviter. Le temps restant va à droite, comme la date d'une tâche.
  private static func resumeRow(_ pomodoro: PomodoroSnapshot) -> Row {
    Row(
      id: AnyHashable("pomodoro-resume"), title: "Reprendre : " + pomodoro.phaseLabel,
      kind: "Pomodoro", systemImage: "play.fill", detail: pomodoro.remaining, isCompleted: false,
      action: .startPomodoro, destination: nil)
  }

  private static func commandRow(_ command: AppCommand) -> Row {
    Row(
      id: AnyHashable("cmd-" + command.rawValue), title: command.label,
      kind: command.isPomodoro ? "Pomodoro" : "Commande", systemImage: command.systemImage,
      // Sans destination : ↩ l'exécute déjà, et « Afficher Aujourd'hui » n'a rien de plus à ouvrir
      // que ce que son propre libellé annonce.
      detail: nil, isCompleted: false, action: .run(command), destination: nil)
  }

  // MARK: La correspondance

  /// Le rang d'une correspondance, ou `nil` si elle n'a pas lieu. Plus petit = meilleur.
  ///
  /// Début de MOT, jamais `contains` : « cour » trouve « Faire les courses », « our » ne le trouve
  /// pas. Avec `contains`, la première lettre tapée faisait remonter la moitié de la base. Le
  /// préfixe de la chaîne entière reste accepté, sans quoi une frappe à plusieurs mots (« faire
  /// les cou ») ne correspondrait plus à rien.
  private static func quality(of haystack: String, for needle: String) -> Int? {
    if haystack.hasPrefix(needle) { return 0 }
    // À partir de n'importe quel début de MOT, et pas mot à mot : découpé en mots, « pause courte »
    // ne trouvait pas « Démarrer une pause courte » — aucun mot seul ne commence par deux mots.
    var index = haystack.startIndex
    while let space = haystack[index...].firstIndex(of: " ") {
      let next = haystack.index(after: space)
      guard next < haystack.endIndex else { break }
      if haystack[next...].hasPrefix(needle) { return 1 }
      index = next
    }
    return nil
  }

  /// Insensible à la casse et aux accents, espaces CONSERVÉS — contrairement à `QuickEntry.fold`,
  /// qui les retire parce qu'il compare des jetons d'un seul mot. Ici on cherche dans des phrases.
  private static func fold(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
