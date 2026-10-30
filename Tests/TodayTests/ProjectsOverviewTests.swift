import SwiftData
import XCTest

@testable import Today

/// La vue « Projets » additionne `SidebarCounts` par projet, en CUMULÉ. Ces tests tiennent les trois
/// règles qui la distinguent de l'anneau : archivées comptées, rien de remis à zéro à minuit,
/// en-têtes exclues.
final class ProjectsOverviewTests: XCTestCase {
  private var context: ModelContext!
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUpWithError() throws {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    context = ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  private func project(_ title: String, sortIndex: Int = 0) -> Project {
    let project = Project(title: title)
    project.sortIndex = sortIndex
    context.insert(project)
    return project
  }

  private func list(_ title: String, in project: Project, sortIndex: Int = 0) -> TodoList {
    let list = TodoList(title: title, project: project)
    list.sortIndex = sortIndex
    context.insert(list)
    return list
  }

  private func add(
    to list: TodoList, done: Bool = false, completedAt: Date? = nil, header: Bool = false
  ) {
    let task = TaskItem(title: "t", isHeader: header)
    task.isCompleted = done
    task.completedAt = completedAt
    task.list = list
    context.insert(task)
  }

  private func overview(_ projects: [Project]) -> ProjectsOverview {
    let tasks = projects.flatMap(\.allTasks)
    return ProjectsOverview.build(
      projects: projects,
      counts: SidebarCounts(tasks: tasks, bounds: ProjectsOverview.cumulativeBounds(now: now)))
  }

  func testTotalCompteLesListesArchiveesMaisNeLesAffichePas() {
    let p = project("P")
    let active = list("En cours", in: p)
    let archived = list("Finie", in: p, sortIndex: 1)
    archived.archivedAt = now
    add(to: active)
    add(to: active, done: true, completedAt: now)
    add(to: archived, done: true, completedAt: now)

    let card = overview([p]).cards[0]
    XCTAssertEqual(card.total.countable, 3)
    XCTAssertEqual(card.total.done, 2)
    XCTAssertEqual(card.lists.map(\.list.title), ["En cours"])
    XCTAssertEqual(card.lists[0].row.done, 1)
  }

  /// Le cœur du choix : une tâche cochée il y a un mois compte toujours, alors que l'anneau du jour
  /// (réglage par défaut) l'aurait sortie.
  func testCumulIgnoreLaRemiseAZeroQuotidienne() {
    let p = project("P")
    let l = list("L", in: p)
    add(to: l, done: true, completedAt: now.addingTimeInterval(-30 * 86_400))
    add(to: l)

    let total = overview([p]).cards[0].total
    XCTAssertEqual(total.done, 1)
    XCTAssertEqual(total.progress, 0.5)
  }

  func testEnTetesExcluesEtProjetVideA0() {
    let p = project("P")
    let l = list("L", in: p)
    add(to: l, header: true)
    let empty = project("Vide", sortIndex: 1)

    let cards = overview([p, empty]).cards
    XCTAssertEqual(cards[0].total.countable, 0)
    XCTAssertEqual(cards[1].total.progress, 0)
    XCTAssertFalse(cards[1].total.progress.isNaN)
  }

  func testOrdreDesCartesEtDesListesSuitLOrdreDonne() {
    let a = project("A")
    let b = project("B", sortIndex: 1)
    _ = list("2", in: a, sortIndex: 2)
    _ = list("1", in: a, sortIndex: 1)

    let cards = overview([a, b]).cards
    XCTAssertEqual(cards.map(\.project.title), ["A", "B"])
    XCTAssertEqual(cards[0].lists.map(\.list.title), ["1", "2"])
    XCTAssertEqual(cards[0].uuid, a.uuid)
  }

  func testTotalDUnProjetEgaleSaCarte() {
    let p = project("P")
    let l = list("L", in: p)
    add(to: l, done: true, completedAt: now.addingTimeInterval(-3 * 86_400))
    add(to: l)

    XCTAssertEqual(ProjectsOverview.total(of: p, now: now), overview([p]).cards[0].total)
  }
}
