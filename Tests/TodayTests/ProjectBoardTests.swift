import XCTest

@testable import Today

/// Ce que les cartes d'un projet montrent, avec ces listes-là. La page tirait ces chiffres depuis
/// son `body` : ils ne se vérifiaient qu'en cliquant, et un aperçu qui montrait une en-tête ou une
/// tâche cochée passait inaperçu.
final class ProjectBoardTests: XCTestCase {
  private func project(_ lists: [TodoList]) -> Project {
    let project = Project(title: "Projet")
    for list in lists {
      list.project = project
      project.lists.append(list)
    }
    return project
  }

  private func list(_ title: String, sortIndex: Int = 0, tasks: [TaskItem] = []) -> TodoList {
    let list = TodoList(title: title)
    list.sortIndex = sortIndex
    for task in tasks {
      task.list = list
      list.tasks.append(task)
    }
    return list
  }

  private func task(
    _ title: String, sortIndex: Int = 0, done: Bool = false, header: Bool = false
  ) -> TaskItem {
    let task = TaskItem(title: title, isHeader: header)
    task.sortIndex = sortIndex
    if done { task.isCompleted = true }
    return task
  }

  // MARK: L'aperçu

  /// La règle de la carte : ce qu'il RESTE à faire. Une en-tête n'est pas une tâche, une tâche
  /// cochée n'attend plus rien — ni l'une ni l'autre n'ont à occuper une des quatre lignes.
  func testPreviewSkipsHeadersAndCompletedTasks() {
    let board = ProjectBoard.build(
      from: project([
        list(
          "Liste",
          tasks: [
            task("en-tête", sortIndex: 0, header: true),
            task("faite", sortIndex: 1, done: true),
            task("à faire", sortIndex: 2),
          ])
      ]), previewLimit: 4)

    XCTAssertEqual(board.cards.first?.preview.map(\.title), ["à faire"])
    XCTAssertEqual(board.cards.first?.remainingCount, 1)
  }

  func testPreviewKeepsListOrderAndStopsAtTheLimit() {
    let board = ProjectBoard.build(
      from: project([
        list(
          "Liste",
          tasks: [
            task("c", sortIndex: 2), task("a", sortIndex: 0), task("b", sortIndex: 1),
            task("d", sortIndex: 3),
          ])
      ]), previewLimit: 2)

    XCTAssertEqual(board.cards.first?.preview.map(\.title), ["a", "b"])
  }

  /// La carte REND plus de rangées qu'elle n'en laisse voir : ce sont elles qui passent sous le
  /// fondu. Un aperçu coupé à ce qui tient exactement ne laisserait rien à estomper.
  func testPreviewFillsUpToTheLimitSoTheFadeHasSomethingToHide() {
    let board = ProjectBoard.build(
      from: project([
        list("Liste", tasks: (0..<9).map { task("t\($0)", sortIndex: $0) })
      ]), previewLimit: 6)

    XCTAssertEqual(board.cards.first?.preview.count, 6)
    XCTAssertEqual(board.cards.first?.remainingCount, 9)
  }

  // MARK: Le pied de carte

  /// Le compte de la carte ne doit pas diverger de celui du badge de la sidebar : même liste, même
  /// nombre. Les deux se lisent côte à côte à l'écran.
  func testRemainingCountMatchesTheSidebarBadge() {
    let todos = list(
      "Liste",
      tasks: [
        task("en-tête", sortIndex: 0, header: true),
        task("faite", sortIndex: 1, done: true),
        task("a", sortIndex: 2),
        task("b", sortIndex: 3),
      ])
    let board = ProjectBoard.build(from: project([todos]), previewLimit: 4)

    XCTAssertEqual(board.cards.first?.remainingCount, todos.remainingCount)
  }

  /// Le compte du pied porte sur TOUTE la liste, pas sur les rangées montrées : la carte dit ce
  /// qu'il reste dans la liste, pas ce que son aperçu contient.
  func testRemainingCountIgnoresThePreviewLimit() {
    let board = ProjectBoard.build(
      from: project([
        list("Liste", tasks: (0..<7).map { task("t\($0)", sortIndex: $0) })
      ]), previewLimit: 2)

    XCTAssertEqual(board.cards.first?.preview.count, 2)
    XCTAssertEqual(board.cards.first?.remainingCount, 7)
  }

  // MARK: La grille

  func testCardsFollowTheProjectOrder() {
    let board = ProjectBoard.build(
      from: project([list("deuxième", sortIndex: 1), list("première", sortIndex: 0)]),
      previewLimit: 4)

    XCTAssertEqual(board.cards.map(\.list.title), ["première", "deuxième"])
  }

  func testEmptyProjectHasNoCard() {
    let board = ProjectBoard.build(from: project([]), previewLimit: 4)

    XCTAssertTrue(board.cards.isEmpty)
    XCTAssertEqual(board.remainingCount, 0)
  }

  func testRemainingCountAddsUpAcrossLists() {
    let board = ProjectBoard.build(
      from: project([
        list("a", sortIndex: 0, tasks: [task("t1"), task("t2", sortIndex: 1)]),
        list("b", sortIndex: 1, tasks: [task("t3")]),
      ]), previewLimit: 4)

    XCTAssertEqual(board.remainingCount, 3)
  }
}
