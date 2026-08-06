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

  // MARK: Le dépôt d'un glissement

  /// Lâcher une tâche dans un autre dépliant la RATTACHE à cette liste. Sans ça, elle remonterait
  /// à sa place d'origine au rendu suivant : le geste aurait l'air de ne pas marcher.
  func testDroppingIntoAnotherSectionReattachesTheTask() throws {
    let ctx = try makeContext()
    let courses = TodoList(title: "Courses")
    let boulot = TodoList(title: "Boulot")
    ctx.insert(courses)
    ctx.insert(boulot)
    let pain = TaskItem(title: "pain", list: courses)
    ctx.insert(pain)
    let devis = TaskItem(title: "devis", list: boulot)
    ctx.insert(devis)

    let page = try build(ctx)
    // « pain » lâché juste sous « devis », donc dans la section « Boulot ».
    page.applyDrop(of: pain, in: [devis, pain], today: today())

    XCTAssertEqual(pain.list?.title, "Boulot")
  }

  /// Lâcher dans « Aujourd'hui » ne change pas la liste : cette section-là veut dire « datée du
  /// jour », c'est la DATE qu'il faut écrire.
  func testDroppingIntoTodaySetsTheDateAndKeepsTheList() throws {
    let ctx = try makeContext()
    let courses = TodoList(title: "Courses")
    ctx.insert(courses)
    let dujour = TaskItem(title: "du jour", when: today(), list: courses)
    ctx.insert(dujour)
    let pain = TaskItem(title: "pain", list: courses)
    ctx.insert(pain)

    let page = try build(ctx)
    page.applyDrop(of: pain, in: [dujour, pain], today: today())

    XCTAssertNotNil(pain.when)
    XCTAssertEqual(pain.list?.title, "Courses", "la liste ne bouge pas : le jour est une date")
  }

  /// Sortir une tâche du jour vers un projet lui retire sa date. Sinon la section « Aujourd'hui »
  /// la reprendrait aussitôt (elle retire ses tâches de toutes les autres) et le dépôt serait sans
  /// effet visible.
  func testLeavingTodayClearsTheDate() throws {
    let ctx = try makeContext()
    let courses = TodoList(title: "Courses")
    ctx.insert(courses)
    let pain = TaskItem(title: "pain", list: courses)
    ctx.insert(pain)
    let dujour = TaskItem(title: "du jour", when: today(), list: courses)
    ctx.insert(dujour)

    let page = try build(ctx)
    page.applyDrop(of: dujour, in: [pain, dujour], today: today())

    XCTAssertNil(dujour.when, "elle doit quitter le jour, sinon elle y remonte")
  }

  /// Le rang ne se réécrit QUE dans la section d'accueil : renuméroter toute la page mélangerait
  /// des tâches qui ne se comparent jamais entre elles.
  func testOnlyTheDestinationSectionIsRenumbered() throws {
    let ctx = try makeContext()
    let courses = TodoList(title: "Courses")
    let boulot = TodoList(title: "Boulot")
    ctx.insert(courses)
    ctx.insert(boulot)
    let pain = TaskItem(title: "pain", list: courses)
    ctx.insert(pain)
    let lait = TaskItem(title: "lait", list: courses)
    ctx.insert(lait)
    let devis = TaskItem(title: "devis", list: boulot)
    ctx.insert(devis)

    let page = try build(ctx)
    page.applyDrop(of: pain, in: [devis, pain, lait], today: today())

    XCTAssertNotEqual(pain.smartOrder, 0, "la déplacée reçoit un rang")
    XCTAssertNotEqual(devis.smartOrder, 0, "sa nouvelle voisine aussi")
    XCTAssertEqual(lait.smartOrder, 0, "une section qu'on n'a pas touchée ne bouge pas")
  }

  /// Déposer en tête de page : il n'y a pas de voisine au-dessus, c'est celle du dessous qui
  /// désigne la section.
  func testDroppingFirstReadsTheSectionBelow() throws {
    let ctx = try makeContext()
    let inbox = TodoList(title: "Tâches")
    inbox.isInbox = true
    ctx.insert(inbox)
    let notee = TaskItem(title: "notée", list: inbox)
    ctx.insert(notee)
    let courses = TodoList(title: "Courses")
    ctx.insert(courses)
    let pain = TaskItem(title: "pain", list: courses)
    ctx.insert(pain)

    let page = try build(ctx)
    page.applyDrop(of: pain, in: [pain, notee], today: today())

    XCTAssertEqual(pain.list?.title, "Tâches", "posée en tête, elle rejoint la boîte de réception")
  }
}
