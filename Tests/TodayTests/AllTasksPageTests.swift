import SwiftData
import XCTest

@testable import Today

/// Ce que la page « Tâches » présente : la boîte de réception, et RIEN d'autre.
///
/// La page a montré l'inventaire complet ; ces tests couvraient alors « une tâche n'apparaît
/// qu'une fois ». Ils couvrent maintenant l'inverse, et c'est la règle qui compte depuis le
/// 12 août 2026 : **ce qui est déjà rangé ne s'affiche pas ici**.
final class AllTasksPageTests: XCTestCase {
  /// Conteneur en mémoire : le filtre lit de VRAIES relations (`task.list`), qu'un objet détaché ne
  /// remplirait pas.
  private func makeContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  private func today() -> Date { Calendar.current.startOfDay(for: Date()) }

  private func build(_ ctx: ModelContext) throws -> AllTasksPage {
    AllTasksPage.build(tasks: try ctx.fetch(FetchDescriptor<TaskItem>()))
  }

  private func inbox(_ ctx: ModelContext) -> TodoList {
    let inbox = TodoList(title: "Tâches")
    inbox.isInbox = true
    ctx.insert(inbox)
    return inbox
  }

  // MARK: Ce que la page montre

  func testOnlyInboxTasksAreShown() throws {
    let ctx = try makeContext()
    ctx.insert(TaskItem(title: "notée", list: inbox(ctx)))
    let courses = TodoList(title: "Courses")
    ctx.insert(courses)
    ctx.insert(TaskItem(title: "pain", list: courses))

    XCTAssertEqual(try build(ctx).tasks.map(\.title), ["notée"])
  }

  /// Une tâche d'un PROJET n'y est pas non plus : elle est rangée, donc elle se lit dans son projet.
  func testProjectTasksStayOut() throws {
    let ctx = try makeContext()
    let projet = Project(title: "Site")
    ctx.insert(projet)
    let lot = TodoList(title: "Lot 1")
    lot.project = projet
    ctx.insert(lot)
    ctx.insert(TaskItem(title: "maquette", list: lot))

    XCTAssertTrue(try build(ctx).tasks.isEmpty)
  }

  /// **Une tâche datée du jour RESTE ici.** Elle était retirée du temps où la page portait une
  /// section « Aujourd'hui » qui l'aurait affichée deux fois ; sans cette section, la retirer la
  /// ferait simplement disparaître de la seule page qui montre l'Inbox.
  func testATaskOfTheDayStays() throws {
    let ctx = try makeContext()
    ctx.insert(TaskItem(title: "aujourd'hui", when: today(), list: inbox(ctx)))

    XCTAssertEqual(try build(ctx).tasks.map(\.title), ["aujourd'hui"])
  }

  /// Une tâche cochée n'est plus à classer : elle vit dans « Archives ».
  func testCompletedTasksLeaveTheInbox() throws {
    let ctx = try makeContext()
    let faite = TaskItem(title: "faite", list: inbox(ctx))
    faite.isCompleted = true
    ctx.insert(faite)

    XCTAssertTrue(try build(ctx).tasks.isEmpty)
  }

  // MARK: Ce que le clavier parcourt

  /// Un seul pan, toujours ouvert : ↑/↓ parcourent exactement ce que la page rend.
  func testEveryRowIsOfferedToTheKeyboard() throws {
    let ctx = try makeContext()
    let list = inbox(ctx)
    ctx.insert(TaskItem(title: "une", list: list))
    ctx.insert(TaskItem(title: "deux", list: list))

    let page = try build(ctx)

    XCTAssertEqual(page.blocks.displayedRows.map(\.title), page.tasks.map(\.title))
    XCTAssertEqual(page.blocks.count, 1)
  }
}
