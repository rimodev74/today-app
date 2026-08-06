import SwiftData
import XCTest

@testable import Today

/// L'anneau mesure la LISTE : ce qui est coché sur ce qu'elle contient.
///
/// Il a d'abord mesuré le flux VISIBLE — une tâche sortie de la page ne comptait ni au numérateur
/// ni au dénominateur — pour qu'une liste au long cours n'affiche pas un disque quasi plein devant
/// une page où rien n'est fait. Sauf qu'un anneau ne regarde AUCUNE page : la règle retombait sur
/// le seuil de 1,5 s, et toute tâche cochée quittait le flux une seconde et demie après le clic.
/// Mesuré : 2 faites sur 4 → 0,0. L'anneau montait puis retombait à zéro tout seul, sur la sidebar
/// comme sur la page d'un projet.
///
/// Ces tests tiennent le nouveau contrat : l'âge d'une coche et le réglage de rétention n'entrent
/// PLUS dans une progression. Ils restent en revanche la règle de ce que la PAGE d'une liste
/// affiche (cf. `CompletedTaskRetentionTests`).
final class ListProgressTests: XCTestCase {
  private var context: ModelContext!

  override func setUpWithError() throws {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    context = ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: CompletedTaskRetention.storageKey)
  }

  /// `long: true` = cochée hier, donc au-delà de tous les délais de rétention.
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

  /// Une coche vieille d'un jour compte toujours. C'est exactement ce qui ne marchait pas.
  func testUneCochéeAncienneCompteEncore() {
    let list = makeList()
    addTask(to: list, completed: true)
    addTask(to: list, completed: true)
    addTask(to: list, completed: false)
    addTask(to: list, completed: false)

    XCTAssertEqual(list.progress, 0.5, accuracy: 0.001)
  }

  /// Le réglage de rétention ne déplace plus l'anneau : les trois modes donnent la même jauge.
  func testLeRéglageDeRétentionNeChangePlusLaProgression() {
    for retention in CompletedTaskRetention.allCases {
      UserDefaults.standard.set(retention.rawValue, forKey: CompletedTaskRetention.storageKey)
      let list = makeList()
      addTask(to: list, completed: true)
      addTask(to: list, completed: false)

      XCTAssertEqual(list.progress, 0.5, accuracy: 0.001, "mode \(retention.rawValue)")
    }
  }

  // MARK: les bornes

  func testToutFait_disquePlein() {
    let list = makeList()
    addTask(to: list, completed: true)
    addTask(to: list, completed: true)

    XCTAssertEqual(list.progress, 1)
  }

  func testRienFait_anneauVide() {
    let list = makeList()
    addTask(to: list, completed: false)

    XCTAssertEqual(list.progress, 0)
  }

  /// Pas de division par zéro, et une liste neuve part vide.
  func testListeVide_anneauVide() {
    XCTAssertEqual(makeList().progress, 0)
  }

  /// Une en-tête n'est pas une tâche : elle ne pèse dans aucun des deux termes. Sans cette garde,
  /// deux en-têtes derrière une tâche faite affichaient un tiers au lieu du plein.
  func testLesEnTêtesNeComptentPas() {
    let list = makeList()
    let header = TaskItem(title: "Section", isHeader: true, list: list)
    context.insert(header)
    list.tasks.append(header)
    addTask(to: list, completed: true)

    XCTAssertEqual(list.progress, 1)
  }

  // MARK: le projet

  func testProjectProgress_confondToutesSesListes() {
    let project = Project(title: "Déménagement")
    context.insert(project)
    for _ in 0..<2 {
      let list = TodoList(title: "Cartons", project: project)
      context.insert(list)
      project.lists.append(list)
      addTask(to: list, completed: true)
      addTask(to: list, completed: false)
    }

    XCTAssertEqual(project.progress, 0.5, accuracy: 0.001)
  }

  func testProjectProgress_sansTâche_anneauVide() {
    let project = Project(title: "Vide")
    context.insert(project)

    XCTAssertEqual(project.progress, 0)
  }
}
