import SwiftData
import XCTest

@testable import Today

/// `SidebarCounts` a été extrait de `TodoList.progress` / `remainingCount` pour ne plus traverser
/// la relation `TodoList.tasks` une fois par rangée. Ces tests tiennent l'équivalence : le
/// déplacement ne doit RIEN changer aux nombres affichés, en-têtes exclues comprises.
final class SidebarCountsTests: XCTestCase {
  private func makeContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  @discardableResult
  private func add(
    _ title: String, to list: TodoList, in context: ModelContext,
    completed: Bool = false, isHeader: Bool = false
  ) -> TaskItem {
    let task = TaskItem(title: title, isHeader: isHeader)
    task.isCompleted = completed
    task.list = list
    context.insert(task)
    return task
  }

  func testCompteLesTachesDeLaListeEtPasLesAutres() throws {
    let context = try makeContext()
    let a = TodoList(title: "A")
    let b = TodoList(title: "B")
    context.insert(a)
    context.insert(b)
    add("1", to: a, in: context)
    add("2", to: a, in: context, completed: true)
    add("3", to: b, in: context)

    let counts = SidebarCounts(tasks: [a, b].flatMap(\.tasks))
    XCTAssertEqual(counts[a].countable, 2)
    XCTAssertEqual(counts[a].done, 1)
    XCTAssertEqual(counts[a].remaining, 1)
    XCTAssertEqual(counts[b].remaining, 1)
  }

  /// La règle qui distingue ce compteur d'un simple `tasks.count` : une en-tête de section n'est
  /// pas une tâche (même exclusion que `TodoList.countableTasks`).
  func testUneEnTeteNeComptePas() throws {
    let context = try makeContext()
    let list = TodoList(title: "A")
    context.insert(list)
    add("Section", to: list, in: context, isHeader: true)
    add("Vraie tâche", to: list, in: context)

    let counts = SidebarCounts(tasks: list.tasks)
    XCTAssertEqual(counts[list].countable, 1)
    XCTAssertEqual(counts[list].remaining, 1)
  }

  /// Une liste VIDE reste à zéro et pas à « tout fait » : 0/0 rendrait `nan`, et l'anneau se
  /// remplirait pour une liste où il n'y a rien à faire.
  func testListeVideResteAZeroEtPasAUn() throws {
    let context = try makeContext()
    let list = TodoList(title: "Vide")
    context.insert(list)

    let counts = SidebarCounts(tasks: [])
    XCTAssertEqual(counts[list].progress, 0)
    XCTAssertEqual(counts[list].remaining, 0)
  }

  func testProgressionToutCoche() throws {
    let context = try makeContext()
    let list = TodoList(title: "A")
    context.insert(list)
    add("1", to: list, in: context, completed: true)
    add("2", to: list, in: context, completed: true)

    let counts = SidebarCounts(tasks: list.tasks)
    XCTAssertEqual(counts[list].progress, 1)
    XCTAssertEqual(counts[list].remaining, 0)
  }

  /// Le vrai garde-fou : les mêmes nombres que les propriétés qu'il remplace, sur un jeu mêlant
  /// en-têtes, cochées et non cochées. C'est ce test qui échouera si l'une des deux règles dérive.
  func testMemesNombresQueTodoList() throws {
    let context = try makeContext()
    let list = TodoList(title: "A")
    context.insert(list)
    add("Section", to: list, in: context, isHeader: true)
    add("1", to: list, in: context)
    add("2", to: list, in: context, completed: true)
    add("3", to: list, in: context)

    let counts = SidebarCounts(tasks: list.tasks)
    XCTAssertEqual(counts[list].remaining, list.remainingCount)
    XCTAssertEqual(counts[list].progress, list.progress())
  }
}
