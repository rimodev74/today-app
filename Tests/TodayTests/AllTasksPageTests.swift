import SwiftData
import XCTest

@testable import Today

/// Ce que la page « Tâches » présente, et dans quel ordre.
///
/// La règle qui compte, et qu'aucun test ne tenait : **une tâche n'apparaît qu'UNE fois**. Celles
/// du jour sont retirées de leur projet et de leur liste, sinon la même ligne se sélectionnerait à
/// deux endroits — et la sélection au clavier deviendrait incompréhensible.
final class AllTasksPageTests: XCTestCase {
  /// Conteneur en mémoire : ces sections lisent de VRAIES relations (`project.allTasks`,
  /// `list.tasks`), qu'un objet détaché ne remplirait pas.
  private func makeContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  private func today() -> Date { Calendar.current.startOfDay(for: Date()) }

  private func build(_ ctx: ModelContext) throws -> AllTasksPage {
    AllTasksPage.build(
      tasks: try ctx.fetch(FetchDescriptor<TaskItem>()),
      projects: try ctx.fetch(FetchDescriptor<Project>()),
      lists: try ctx.fetch(FetchDescriptor<TodoList>()))
  }

  // MARK: L'ossature de la page

  /// La boîte de réception ouvre la page et n'a PAS de bandeau ; « Aujourd'hui » vient juste après.
  /// Cet ordre n'est pas cosmétique : c'est celui que ↑/↓ parcourent.
  func testInboxOpensThePageWithoutAHeader() throws {
    let ctx = try makeContext()
    let inbox = TodoList(title: "Tâches")
    inbox.isInbox = true
    ctx.insert(inbox)
    ctx.insert(TaskItem(title: "notée", list: inbox))

    let page = try build(ctx)

    XCTAssertEqual(page.sections.first?.kind, .inbox)
    XCTAssertEqual(page.sections.first?.hasHeader, false)
    XCTAssertEqual(page.sections.dropFirst().first?.kind, .today)
  }

  /// Une liste vide ne fabrique pas de dépliant : la page serait une liste de titres creux.
  func testEmptyListsGetNoSection() throws {
    let ctx = try makeContext()
    ctx.insert(TodoList(title: "Vide"))

    let page = try build(ctx)

    XCTAssertFalse(page.sections.contains { $0.title == "Vide" })
  }

  // MARK: Une tâche, un seul endroit

  func testATaskOfTheDayLeavesItsList() throws {
    let ctx = try makeContext()
    let courses = TodoList(title: "Courses")
    ctx.insert(courses)
    let pain = TaskItem(title: "pain", when: today(), list: courses)
    ctx.insert(pain)
    ctx.insert(TaskItem(title: "lait", list: courses))

    let page = try build(ctx)

    let jour = page.sections.first { $0.kind == .today }
    let liste = page.sections.first { $0.title == "Courses" }
    XCTAssertEqual(jour?.tasks.map(\.title), ["pain"])
    XCTAssertEqual(liste?.tasks.map(\.title), ["lait"], "« pain » ne doit pas y être une 2e fois")
  }

  /// Les listes d'un projet sont déjà dans `project.allTasks` : elles ne doivent pas produire
  /// EN PLUS un dépliant à elles, sinon chaque tâche de projet s'afficherait deux fois.
  func testProjectListsDoNotGetTheirOwnSection() throws {
    let ctx = try makeContext()
    let projet = Project(title: "Site")
    ctx.insert(projet)
    let lot = TodoList(title: "Lot 1")
    lot.project = projet
    ctx.insert(lot)
    ctx.insert(TaskItem(title: "maquette", list: lot))

    let page = try build(ctx)

    XCTAssertEqual(page.sections.first { $0.title == "Site" }?.tasks.map(\.title), ["maquette"])
    XCTAssertNil(page.sections.first { $0.title == "Lot 1" })
  }

  /// Une tâche cochée n'est plus à faire : elle sort de l'inventaire (elle vit dans « Archives »).
  func testCompletedTasksLeaveTheInventory() throws {
    let ctx = try makeContext()
    let liste = TodoList(title: "Courses")
    ctx.insert(liste)
    let faite = TaskItem(title: "faite", list: liste)
    faite.isCompleted = true
    ctx.insert(faite)

    let page = try build(ctx)

    XCTAssertNil(page.sections.first { $0.title == "Courses" })
  }

  // MARK: Ce que le clavier parcourt

  /// Un dépliant fermé ne fournit aucune ligne : ↑/↓ ne peuvent pas emmener la sélection sur une
  /// ligne que l'œil ne voit pas.
  func testClosedSectionsOfferNoRow() throws {
    let ctx = try makeContext()
    let inbox = TodoList(title: "Tâches")
    inbox.isInbox = true
    ctx.insert(inbox)
    ctx.insert(TaskItem(title: "notée", list: inbox))
    let courses = TodoList(title: "Courses")
    ctx.insert(courses)
    ctx.insert(TaskItem(title: "pain", list: courses))

    let page = try build(ctx)

    let tout = page.blocks { _ in true }.displayedRows.map(\.title)
    let defaut = page.blocks { $0.defaultExpanded }.displayedRows.map(\.title)
    XCTAssertEqual(tout, ["notée", "pain"])
    XCTAssertEqual(defaut, ["notée"], "« Courses » est replié par défaut")
  }
}
