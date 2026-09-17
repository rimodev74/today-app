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

  /// Rétention INJECTÉE, jamais lue dans les défauts : un test qui dépend du réglage de la machine
  /// passe ou casse selon ce qu'on a coché dans les Réglages la veille.
  private func build(
    _ ctx: ModelContext, retention: CompletedTaskRetention = .untilNextDay, now: Date = Date()
  ) throws -> AllTasksPage {
    AllTasksPage.build(
      tasks: try ctx.fetch(FetchDescriptor<TaskItem>()), retention: retention, now: now)
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

  /// **Une tâche qu'on vient de cocher RESTE affichée**, barrée. Elle disparaissait sous le clic :
  /// plus rien ne confirmait la coche, et on la croyait archivée d'office. (Où elle se range est
  /// l'affaire de `SmartList.sort` et de son réglage « Descendre en bas », testés chez eux.)
  func testAFreshlyCompletedTaskStays() throws {
    let ctx = try makeContext()
    let list = inbox(ctx)
    ctx.insert(TaskItem(title: "à faire", list: list))
    let faite = TaskItem(title: "faite", list: list)
    faite.isCompleted = true
    faite.completedAt = Date()
    ctx.insert(faite)

    XCTAssertEqual(try build(ctx).tasks.map(\.title), ["à faire", "faite"])
  }

  /// Et elle sort par la règle COMMUNE, pas par un filtre propre à cette page : cochée hier, elle
  /// n'est plus là ce matin — elle se lit dans « Archives ».
  func testYesterdaysCompletedTaskLeavesTheInbox() throws {
    let ctx = try makeContext()
    let faite = TaskItem(title: "faite hier", list: inbox(ctx))
    faite.isCompleted = true
    faite.completedAt = today().addingTimeInterval(-3600)
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
