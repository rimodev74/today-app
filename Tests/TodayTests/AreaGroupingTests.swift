import SwiftData
import XCTest

@testable import Today

final class AreaGroupingTests: XCTestCase {
  @MainActor
  func testLooseProjectsFirstThenAreasInOrderKeepingProjectOrder() throws {
    let schema = Schema([Area.self, Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let container = try ModelContainer(
      for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext

    let agency = Area(title: "Double Vision")
    agency.sortIndex = 1
    let perso = Area(title: "Perso")
    perso.sortIndex = 0
    let empty = Area(title: "Vide")
    empty.sortIndex = 2
    let zen = Project(title: "Zen Sauna")
    let bizz = Project(title: "Place de bizz")
    let loose = Project(title: "Seul")
    let house = Project(title: "Maison")
    for item in [agency, perso, empty] { context.insert(item) }
    for project in [zen, loose, bizz, house] { context.insert(project) }
    zen.area = agency
    bizz.area = agency
    house.area = perso

    let sections = AreaGrouping(
      projects: [zen, loose, bizz, house], areas: [agency, empty, perso]
    )
    .sections
    XCTAssertEqual(sections.map { $0.area?.title }, [nil, "Perso", "Double Vision", "Vide"])
    XCTAssertEqual(
      sections.map { $0.projects.map(\.title) },
      [["Seul"], ["Maison"], ["Zen Sauna", "Place de bizz"], []])

    // Supprimer une zone rend ses projets à la racine, sans les emporter.
    XCTAssertTrue(context.deleteCascadeAndSave(agency))
    XCTAssertEqual(try context.fetch(FetchDescriptor<Project>()).count, 4)
    XCTAssertNil(zen.area)
  }
}
