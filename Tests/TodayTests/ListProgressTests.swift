import SwiftData
import XCTest

@testable import Today

/// L'anneau mesure la LISTE : ce qui est coché sur ce qu'elle contient AUJOURD'HUI.
///
/// Deuxième révision de cette règle. La PREMIÈRE mesurait le flux VISIBLE — une tâche sortie de la
/// page ne comptait ni au numérateur ni au dénominateur — pour qu'une liste au long cours n'affiche
/// pas un disque quasi plein devant une page où rien n'est fait. Retirée : vu d'un anneau il n'y a
/// AUCUNE page, et la règle retombait sur `CompletedTaskRetention` — son mode « 1,5 s » faisait
/// sortir toute tâche cochée une seconde et demie après le clic. Mesuré : 2 faites sur 4 → 0,0.
/// L'anneau montait puis retombait à zéro tout seul, sur la sidebar comme sur la page d'un projet.
///
/// La DEUXIÈME ignorait donc l'âge d'une coche : une tâche complétée compte pour toujours. Ça
/// tenait pour une liste qu'on termine une fois, mais pas pour une liste au long cours jamais
/// terminée (ex. « Bugs & fix ») : chaque tâche archivée restait au dénominateur pour toujours,
/// l'anneau plafonnait près du plein et une tâche neuve ne le faisait quasiment plus bouger.
///
/// Celle-ci (la troisième) ancre l'exclusion sur le JOUR CALENDAIRE plutôt que sur
/// `CompletedTaskRetention` : la borne ne bouge qu'une fois par jour, à minuit — jamais en cours de
/// journée comme le mode « 1,5 s », donc jamais le clignotement qui avait fait retirer la première
/// version. Une tâche archivée AVANT aujourd'hui ne compte plus dans AUCUN des deux termes, comme
/// si elle n'avait jamais existé. Le réglage de rétention reste, lui, la règle de ce que la PAGE
/// d'une liste affiche (cf. `CompletedTaskRetentionTests`) — il ne pilote plus l'anneau.
final class ListProgressTests: XCTestCase {
  private var context: ModelContext!

  override func setUpWithError() throws {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    context = ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: CompletedTaskRetention.storageKey)
    UserDefaults.standard.removeObject(forKey: TaskItem.progressResetsDailyStorageKey)
  }

  /// `long: true` = cochée hier, donc déjà archivée pour l'anneau — quel que soit le réglage de
  /// rétention, qui ne gouverne plus que la page.
  @discardableResult
  private func addTask(to list: TodoList, completed: Bool, long: Bool = true) -> TaskItem {
    let task = TaskItem(title: "t", list: list)
    task.isCompleted = completed
    if completed { task.completedAt = long ? Date().addingTimeInterval(-86_400) : Date() }
    context.insert(task)
    list.tasks.append(task)
    return task
  }

  private func makeList() -> TodoList {
    let list = TodoList(title: "Courses")
    context.insert(list)
    return list
  }

  // MARK: LE cas qui a motivé le changement

  /// Une liste terminée hier (donc archivée), à laquelle on ajoute une tâche neuve aujourd'hui,
  /// repart comme une liste vierge — pas presque pleine. C'est le bug d'origine : une liste au long
  /// cours plafonnait près du plein pour toujours, une tâche neuve ne la faisait quasiment plus
  /// bouger.
  func testListeArchivéeHier_TâcheNeuve_RepartVierge() {
    let list = makeList()
    addTask(to: list, completed: true)  // finie hier
    addTask(to: list, completed: true)  // finie hier
    addTask(to: list, completed: false)  // ajoutée aujourd'hui

    XCTAssertEqual(list.progress(), 0)
  }

  /// Une tâche cochée AUJOURD'HUI compte toujours : seul l'historique archivé sort du calcul, pas
  /// ce qui vient d'être fait.
  func testUneCochéeDuJourCompteEncore() {
    let list = makeList()
    addTask(to: list, completed: true, long: false)
    addTask(to: list, completed: false)

    XCTAssertEqual(list.progress(), 0.5, accuracy: 0.001)
  }

  /// Le réglage de rétention ne pilote plus l'anneau, dans aucun sens : même en « Ne jamais les
  /// masquer » (la tâche reste visible sur la page pour toujours), une coche d'hier sort quand même
  /// de l'anneau — sa borne est le calendrier, pas ce réglage.
  func testLeRéglageDeRétentionNePiloteJamaisLAnneau() {
    for retention in CompletedTaskRetention.allCases {
      UserDefaults.standard.set(retention.rawValue, forKey: CompletedTaskRetention.storageKey)
      let list = makeList()
      addTask(to: list, completed: true)  // archivée, quel que soit le réglage
      addTask(to: list, completed: false)

      XCTAssertEqual(list.progress(), 0, "mode \(retention.rawValue)")
    }
  }

  /// Réglage désactivé : l'ancien comportement revient tel quel — l'archivé d'hier compte encore,
  /// pour toujours.
  func testProgressResetsDailyDésactivé_LArchivéCompteToujours() {
    UserDefaults.standard.set(false, forKey: TaskItem.progressResetsDailyStorageKey)
    let list = makeList()
    addTask(to: list, completed: true)  // finie hier
    addTask(to: list, completed: false)  // ajoutée aujourd'hui

    XCTAssertEqual(list.progress(), 0.5, accuracy: 0.001)
  }

  // MARK: les bornes

  func testToutFait_disquePlein() {
    let list = makeList()
    addTask(to: list, completed: true, long: false)
    addTask(to: list, completed: true, long: false)

    XCTAssertEqual(list.progress(), 1)
  }

  func testRienFait_anneauVide() {
    let list = makeList()
    addTask(to: list, completed: false)

    XCTAssertEqual(list.progress(), 0)
  }

  /// Pas de division par zéro, et une liste neuve part vide.
  func testListeVide_anneauVide() {
    XCTAssertEqual(makeList().progress(), 0)
  }

  /// Une en-tête n'est pas une tâche : elle ne pèse dans aucun des deux termes. Sans cette garde,
  /// deux en-têtes derrière une tâche faite affichaient un tiers au lieu du plein.
  func testLesEnTêtesNeComptentPas() {
    let list = makeList()
    let header = TaskItem(title: "Section", isHeader: true, list: list)
    context.insert(header)
    list.tasks.append(header)
    addTask(to: list, completed: true, long: false)

    XCTAssertEqual(list.progress(), 1)
  }

  // MARK: le projet

  func testProjectProgress_confondToutesSesListes() {
    let project = Project(title: "Déménagement")
    context.insert(project)
    for _ in 0..<2 {
      let list = TodoList(title: "Cartons", project: project)
      context.insert(list)
      project.lists.append(list)
      addTask(to: list, completed: true, long: false)
      addTask(to: list, completed: false)
    }

    XCTAssertEqual(project.progress(), 0.5, accuracy: 0.001)
  }

  func testProjectProgress_sansTâche_anneauVide() {
    let project = Project(title: "Vide")
    context.insert(project)

    XCTAssertEqual(project.progress(), 0)
  }

  /// Même règle côté projet : ce qui est archivé dans une de ses listes ne pèse plus non plus dans
  /// l'anneau du projet.
  func testProjectProgress_IgnoreLArchivé() {
    let project = Project(title: "Déménagement")
    context.insert(project)
    let list = TodoList(title: "Cartons", project: project)
    context.insert(list)
    project.lists.append(list)
    addTask(to: list, completed: true)  // archivée
    addTask(to: list, completed: false)

    XCTAssertEqual(project.progress(), 0)
  }
}
