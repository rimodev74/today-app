import SwiftData
import SwiftUI
import XCTest

@testable import Today

/// Ranger une liste terminée dans les archives de son projet : ce qu'elle quitte, ce qu'elle garde,
/// et où elle revient. Le dépliant lui-même ne se voit qu'à l'écran.
final class ListArchiveTests: XCTestCase {
  /// Conteneur en mémoire : `Project.lists` et `TodoList.project` sont de VRAIES relations.
  private func makeContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  private func project(
    _ titles: [String], in context: ModelContext
  ) -> (Project, [TodoList]) {
    let project = Project(title: "Maison")
    context.insert(project)
    let lists = titles.map { project.appendList(titled: $0, in: context) }
    return (project, lists)
  }

  func testArchivedListLeavesActiveListsButStaysInTheProject() throws {
    let context = try makeContext()
    let (project, lists) = project(["A", "B", "C"], in: context)
    var selection: SidebarSelection? = .smartList(.today)

    lists[1].archive(from: Binding(get: { selection }, set: { selection = $0 }), in: context)

    XCTAssertEqual(project.activeLists.map(\.title), ["A", "C"])
    XCTAssertEqual(project.orderedLists.map(\.title), ["A", "B", "C"], "rien n'est effacé")
    XCTAssertNotNil(lists[1].archivedAt)
    XCTAssertEqual(selection, .smartList(.today), "une autre page reste où elle est")
  }

  /// La liste affichée vient de quitter la sidebar : la page part sur son projet, là où elle s'est
  /// rangée — pas sur une page qu'aucune ligne ne désigne plus.
  func testArchivingTheShownListOpensItsProject() throws {
    let context = try makeContext()
    let (project, lists) = project(["A"], in: context)
    var selection: SidebarSelection? = .list(lists[0])

    lists[0].archive(from: Binding(get: { selection }, set: { selection = $0 }), in: context)

    XCTAssertEqual(selection, .project(project))
  }

  /// Entre-temps, un glissement a renuméroté les listes restées en place : l'ancien rang ferait
  /// retomber la liste au milieu d'elles. Elle revient en fin de projet.
  func testUnarchivedListComesBackAtTheEnd() throws {
    let context = try makeContext()
    let (project, lists) = project(["A", "B", "C"], in: context)
    var selection: SidebarSelection?
    lists[0].archive(from: Binding(get: { selection }, set: { selection = $0 }), in: context)
    // Ce qu'écrit un glissement de la sidebar : les listes VISIBLES, renumérotées depuis 0.
    for (index, list) in project.activeLists.enumerated() { list.sortIndex = index }

    lists[0].unarchive(in: context)

    XCTAssertNil(lists[0].archivedAt)
    XCTAssertEqual(project.activeLists.map(\.title), ["B", "C", "A"])
  }

  /// Une nouvelle liste prend son rang après TOUTES celles du projet, archivées comprises.
  func testNewListRanksAfterArchivedOnes() throws {
    let context = try makeContext()
    let (project, lists) = project(["A", "B"], in: context)
    var selection: SidebarSelection?
    lists[1].archive(from: Binding(get: { selection }, set: { selection = $0 }), in: context)

    let fresh = project.appendList(titled: "C", in: context)

    XCTAssertGreaterThan(fresh.sortIndex, lists[1].sortIndex)
  }

  /// La capsule ne propose plus une archivée comme endroit où écrire ; ses tâches restent trouvables.
  func testPaletteNoLongerOffersAnArchivedListButStillFindsItsTasks() throws {
    let context = try makeContext()
    let (_, lists) = project(["Courses"], in: context)
    let task = TaskItem(title: "Courgettes")
    task.list = lists[0]
    context.insert(task)
    func search() -> QuickPalette {
      QuickPalette.search("cour", lists: lists, projects: [], tasks: [task])
    }
    XCTAssertTrue(search().rows.contains { $0.kind == "Liste" }, "témoin : proposée avant")

    lists[0].archivedAt = Date()

    XCTAssertFalse(search().rows.contains { $0.kind == "Liste" })
    XCTAssertTrue(search().rows.contains { $0.title == "Courgettes" })
  }
}
