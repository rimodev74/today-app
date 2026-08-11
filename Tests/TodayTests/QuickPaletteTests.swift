import XCTest

@testable import Today

/// Ce que la capsule propose, et surtout ce que ↩ en fera — vérifié sans capsule.
///
/// La question posée est celle qu'on se poserait à l'œil, sauf qu'à l'œil il faudrait ouvrir une
/// fenêtre flottante par-dessus une autre app et taper dedans : *avec ces listes, ces dossiers et
/// cette frappe, quelles lignes, dans quel ordre, et que déclenche chacune ?*
///
/// Ces tests tiennent le principe qui porte tout le reste : **une ligne = une action**. Il a une
/// histoire — la capsule supposait qu'on composait toujours une tâche, et Tab, qui répondait « les
/// notes de la tâche en cours », plantait l'app dès qu'on regardait autre chose.
final class QuickPaletteTests: XCTestCase {
  private let calendar = Calendar.current

  private func task(_ title: String, daysFromToday: Int? = nil, completed: Bool = false)
    -> TaskItem
  {
    let when = daysFromToday.map {
      calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: Date()))!
    }
    let item = TaskItem(title: title, when: when)
    if completed { item.toggleCompletion() }
    return item
  }

  private func inbox() -> TodoList {
    let list = TodoList(title: "Boîte de réception")
    list.isInbox = true
    return list
  }

  private func titles(_ palette: QuickPalette) -> [String] { palette.rows.map(\.title) }
  private func kinds(_ palette: QuickPalette) -> [String] { palette.rows.map(\.kind) }

  private func action(_ palette: QuickPalette, _ title: String) -> QuickPalette.Action? {
    palette.rows.first { $0.title == title }?.action
  }

  // MARK: L'ouverture

  /// **La capsule s'ouvre sur une barre NUE.** Rien en dessous tant qu'on n'a rien demandé — et
  /// surtout pas une ligne présélectionnée, qui donnerait à ↩ une action qu'on n'a pas choisie.
  func testOpeningShowsNothing() {
    let palette = QuickPalette.search(
      "", lists: [TodoList(title: "Courses", project: Project(title: "Maison"))],
      projects: [Project(title: "Maison")],
      tasks: [task("aujourd'hui", daysFromToday: 0)])

    XCTAssertTrue(palette.isEmpty)
  }

  /// Une frappe qui n'est que des espaces reste une frappe vide : sinon un espace malencontreux
  /// ferait surgir une liste sous la barre.
  func testWhitespaceOnlyShowsNothing() {
    XCTAssertTrue(
      QuickPalette.search("   ", lists: [], projects: [], tasks: [task("x", daysFromToday: 0)])
        .isEmpty)
  }

  // MARK: Une ligne, une action

  /// Le cœur du modèle : la nature de la ligne décide, pas une touche à mémoriser.
  func testEachKindCarriesItsOwnAction() {
    let project = Project(title: "Maison")
    let list = TodoList(title: "Courses", project: project)
    let existing = task("Courses du soir")

    let palette = QuickPalette.search(
      "cour", lists: [list], projects: [project], tasks: [existing])

    guard case .addTask(.list(let target)) = action(palette, "Courses") else {
      return XCTFail("une liste doit proposer d'y ajouter une tâche")
    }
    XCTAssertIdentical(target, list)

    guard case .complete(let done) = action(palette, "Courses du soir") else {
      return XCTFail("une tâche doit proposer de la valider")
    }
    XCTAssertIdentical(done, existing)
  }

  /// Un dossier ne reçoit pas de tâche : il reçoit une liste. C'est la seule nature dont l'action
  /// n'est pas « ajouter une tâche », et c'est ce qui la distingue d'une liste à l'œil comme au
  /// clavier.
  func testAFolderCreatesAList() {
    let project = Project(title: "Maison")
    let palette = QuickPalette.search("mais", lists: [], projects: [project], tasks: [])

    guard case .createList(let target) = action(palette, "Maison") else {
      return XCTFail("un dossier doit proposer d'y créer une liste")
    }
    XCTAssertIdentical(target, project)
    XCTAssertEqual(palette.rows.first?.kind, "Dossier")
  }

  func testSmartListsAddATask() {
    let palette = QuickPalette.search("auj", lists: [], projects: [], tasks: [])

    guard case .addTask(.today) = action(palette, "Aujourd'hui") else {
      return XCTFail("« Aujourd'hui » doit proposer d'y ajouter une tâche")
    }
  }

  /// « À venir » et « Archives » ne sont PAS des endroits où l'on ajoute : l'une est définie par
  /// une date future, l'autre par la complétion. Elles restent atteignables par leurs commandes.
  func testUpcomingAndArchiveAreNotContainers() {
    let upcoming = QuickPalette.search("À venir", lists: [], projects: [], tasks: [])
    XCTAssertFalse(kinds(upcoming).contains("Vue"))

    let archive = QuickPalette.search("Archives", lists: [], projects: [], tasks: [])
    XCTAssertFalse(kinds(archive).contains("Vue"))
  }

  // MARK: Ce qui correspond

  /// Début de MOT, pas milieu : c'est la règle qui empêche la première lettre tapée de faire
  /// remonter la moitié de la base.
  func testMatchesWordStartsOnly() {
    let all = [task("Faire les courses")]

    XCTAssertTrue(
      titles(QuickPalette.search("cour", lists: [], projects: [], tasks: all)).contains(
        "Faire les courses"))
    XCTAssertFalse(
      titles(QuickPalette.search("our", lists: [], projects: [], tasks: all)).contains(
        "Faire les courses"))
  }

  func testIgnoresCaseAndDiacritics() {
    let palette = QuickPalette.search(
      "REU", lists: [], projects: [], tasks: [task("Réunion d'équipe")])

    XCTAssertTrue(titles(palette).contains("Réunion d'équipe"))
  }

  /// Une en-tête de section porte un titre comme une tâche, mais il n'y a rien à y valider.
  ///
  /// On vérifie l'absence de ligne « Tâche » et pas une palette VIDE : « cour » sort aussi
  /// « Démarrer une pause **cour**te », et c'est le bon comportement.
  func testSectionHeadersAreExcluded() {
    let header = task("Courses")
    header.isHeader = true
    let palette = QuickPalette.search("cour", lists: [], projects: [], tasks: [header])

    XCTAssertFalse(kinds(palette).contains("Tâche"))
  }

  func testNoMatchYieldsNothing() {
    XCTAssertTrue(
      QuickPalette.search("zzzz", lists: [], projects: [], tasks: [task("Courses")]).isEmpty)
  }

  // MARK: Le classement

  /// À qualité de correspondance égale, un ENDROIT passe devant une ligne : on vise beaucoup plus
  /// souvent « où aller » qu'une tâche précise.
  func testPlacesOutrankTasksAtEqualQuality() {
    let project = Project(title: "Courses")
    let list = TodoList(title: "Courses", project: project)
    let palette = QuickPalette.search(
      "courses", lists: [list], projects: [project], tasks: [task("Courses du soir")])

    XCTAssertEqual(kinds(palette), ["Dossier", "Liste", "Tâche"])
  }

  /// Un titre qui COMMENCE par la frappe passe devant celui qui ne fait que la contenir, quelle
  /// que soit sa nature.
  func testPrefixBeatsWordMatchAcrossKinds() {
    let project = Project(title: "Grand plombier")
    let palette = QuickPalette.search(
      "plomb", lists: [], projects: [project], tasks: [task("Plombier à rappeler")])

    XCTAssertEqual(titles(palette), ["Plombier à rappeler", "Grand plombier"])
  }

  func testRowsAreCapped() {
    let projects = (1...12).map { Project(title: "Courses \($0)") }
    let palette = QuickPalette.search("courses", lists: [], projects: projects, tasks: [])

    XCTAssertEqual(palette.rows.count, QuickPalette.limit)
  }

  // MARK: Les commandes

  /// Ce que la palette rend atteignable : la commande se trouve par son LIBELLÉ, sans connaître le
  /// déclencheur qu'on lui avait donné dans les Réglages.
  func testCommandsMatchOnTheirLabel() {
    let palette = QuickPalette.search("pause courte", lists: [], projects: [], tasks: [])

    guard case .run(let command) = palette.rows.first?.action else {
      return XCTFail("une commande devrait sortir")
    }
    XCTAssertEqual(command, .pomodoroShortBreak)
  }

  /// **Le mot-clé, et pourquoi il existe** : « Passer à la phase suivante » est une action de
  /// pomodoro dont le libellé ne contient pas le mot. Sans `AppCommand.keywords`, taper
  /// « pomodoro » n'en sortait que deux sur cinq.
  func testPomodoroFindsAllFiveActions() {
    let palette = QuickPalette.search("pomodoro", lists: [], projects: [], tasks: [])
    let commands: [AppCommand] = palette.rows.compactMap {
      guard case .run(let command) = $0.action else { return nil }
      return command
    }

    XCTAssertEqual(Set(commands), Set(AppCommand.pomodoroCommands))
    XCTAssertTrue(commands.contains(.pomodoroSkip), "son libellé ne dit pourtant pas « pomodoro »")
    XCTAssertEqual(palette.rows.first?.kind, "Pomodoro")
  }

  /// Les commandes se rangent avec ce qui emmène quelque part, jamais après le contenu.
  func testCommandsComeBeforeTasks() {
    let palette = QuickPalette.search(
      "pomodoro", lists: [], projects: [], tasks: [task("Pomodoro du matin")])

    XCTAssertEqual(palette.rows.last?.kind, "Tâche")
  }

  // MARK: La seconde étape

  func testInsideAListShowsItsTasks() {
    let project = Project(title: "Maison")
    let list = TodoList(title: "Courses", project: project)
    let mine = task("Acheter du pain")
    mine.list = list

    let palette = QuickPalette.inside(.list(list), lists: [], tasks: [])

    XCTAssertEqual(titles(palette), ["Acheter du pain"])
    guard case .complete = palette.rows.first?.action else {
      return XCTFail("le contexte se coche, il ne se remplit pas")
    }
  }

  /// Choisir un dossier doit montrer ce qu'il CONTIENT. Sans ça il fallait relancer une recherche
  /// pour atteindre ses listes, et le geste perdait son sens.
  func testInsideAFolderShowsItsLists() {
    let project = Project(title: "Maison")
    let list = TodoList(title: "Courses", project: project)
    project.lists = [list]

    let palette = QuickPalette.inside(project: project)

    XCTAssertEqual(titles(palette), ["Courses"])
    guard case .addTask(.list(let target)) = palette.rows.first?.action else {
      return XCTFail("une liste du dossier doit s'ouvrir pour y ajouter une tâche")
    }
    XCTAssertIdentical(target, list)
  }

  func testInsideTodayShowsTheDay() {
    let palette = QuickPalette.inside(
      .today, lists: [],
      tasks: [task("aujourd'hui", daysFromToday: 0), task("demain", daysFromToday: 1)])

    XCTAssertEqual(titles(palette), ["aujourd'hui"])
  }

  // MARK: Où atterrit la tâche

  /// « Aujourd'hui » n'est pas un rangement, c'est une DATE : la tâche va dans la boîte de
  /// réception, datée du jour. C'est le seul sens que « ajouter à Aujourd'hui » puisse avoir.
  func testTodayTargetLandsInInboxDatedToday() {
    let box = inbox()
    let resolved = QuickPalette.TaskTarget.today.resolve(in: [box])

    XCTAssertIdentical(resolved.list, box)
    XCTAssertEqual(resolved.when, calendar.startOfDay(for: Date()))
  }

  /// **Le contenant CHOISI, pas son point de chute.** « Aujourd'hui » se résout dans la boîte de
  /// réception : le chip de la capsule affichait donc « Tâches » juste après qu'on ait choisi
  /// « Aujourd'hui ». Ce libellé est ce qu'il doit lire.
  func testTargetLabelNamesTheChosenPlace() {
    XCTAssertEqual(QuickPalette.TaskTarget.today.label, "Aujourd'hui")
    XCTAssertEqual(QuickPalette.TaskTarget.inbox.label, "Tâches")
    XCTAssertEqual(QuickPalette.TaskTarget.list(TodoList(title: "Courses")).label, "Courses")
  }

  func testInboxTargetHasNoDate() {
    let box = inbox()
    let resolved = QuickPalette.TaskTarget.inbox.resolve(in: [box])

    XCTAssertIdentical(resolved.list, box)
    XCTAssertNil(resolved.when)
  }

  func testListTargetKeepsItsList() {
    let list = TodoList(title: "Courses", project: Project(title: "Maison"))
    let resolved = QuickPalette.TaskTarget.list(list).resolve(in: [inbox()])

    XCTAssertIdentical(resolved.list, list)
    XCTAssertNil(resolved.when)
  }

  // MARK: Ce que la ligne promet

  /// Le libellé d'action est affiché sur la ligne visée : c'est la promesse de ↩, écrite noir sur
  /// blanc. S'il ment, le principe entier s'écroule.
  func testActionLabelsSayWhatWillHappen() {
    XCTAssertEqual(QuickPalette.Action.addTask(.inbox).label, "Ajouter une tâche")
    XCTAssertEqual(QuickPalette.Action.createList(Project(title: "x")).label, "Créer une liste")
    XCTAssertEqual(QuickPalette.Action.complete(task("x")).label, "Valider")
    XCTAssertEqual(QuickPalette.Action.run(.pomodoroStart).label, "Lancer")
  }

  /// ⌘↩ « va voir » là où ↩ « fait ici ». Les deux gestes tiennent sur la même ligne, et c'est
  /// l'ENDROIT désigné qui décide si le second existe — une tâche et une commande n'en ont pas.
  func testDestinationsAreTheOnesWorthOpening() {
    let project = Project(title: "Maison")
    let list = TodoList(title: "Courses", project: project)
    let done = TaskItem(title: "Acheter du pain", list: list)

    func destination(of query: String) -> SidebarSelection? {
      QuickPalette.search(query, lists: [list], projects: [project], tasks: [done]).rows
        .first?.destination
    }

    XCTAssertEqual(destination(of: "Tâches"), .smartList(.all))
    XCTAssertEqual(destination(of: "Aujourd"), .smartList(.today))
    XCTAssertEqual(destination(of: "Courses"), .list(list))
    XCTAssertEqual(destination(of: "Maison"), .project(project))
    // Une tâche ouvre la liste qui la porte : c'est l'endroit le plus proche qu'un onglet montre.
    XCTAssertEqual(destination(of: "Acheter"), .list(list))
    XCTAssertNil(destination(of: "pomodoro"))
  }

  /// Une tâche cochée le dit dans la palette : sans ça, la case vide démentait le titre barré.
  func testCompletedTaskShowsACheckedBox() {
    let list = TodoList(title: "Courses")
    let done = TaskItem(title: "Acheter du pain", list: list)
    done.toggleCompletion()
    let todo = TaskItem(title: "Payer le loyer", list: list)

    func image(of query: String) -> String? {
      QuickPalette.search(query, lists: [list], projects: [], tasks: [done, todo]).rows
        .first { $0.kind == "Tâche" }?.systemImage
    }

    XCTAssertEqual(image(of: "Acheter"), "checkmark.circle.fill")
    XCTAssertEqual(image(of: "Payer"), "circle")
  }

}
