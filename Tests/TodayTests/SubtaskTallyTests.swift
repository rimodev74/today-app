import SwiftData
import XCTest

@testable import Today

/// Ce que `TaskRow` lit de ses sous-tâches. La rangée le calculait par cinq lectures de la
/// relation, donc invérifiable autrement qu'en regardant un anneau à l'écran.
final class SubtaskTallyTests: XCTestCase {
  private func makeContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  func testCountsTotalAndDone() throws {
    let ctx = try makeContext()
    let task = TaskItem(title: "T")
    ctx.insert(task)
    task.addSubtask().isDone = true
    task.addSubtask().isDone = true
    _ = task.addSubtask()

    let tally = SubtaskTally(task)
    XCTAssertEqual(tally.total, 3)
    XCTAssertEqual(tally.done, 2)
    XCTAssertFalse(tally.isEmpty)
  }

  /// Sans sous-tâche, la rangée n'affiche pas son résumé — et l'anneau reste vide au lieu de
  /// valoir `nan` : 0/0 le remplirait là où il n'y a rien à cocher.
  func testEmptyTaskHasNoFraction() throws {
    let ctx = try makeContext()
    let task = TaskItem(title: "T")
    ctx.insert(task)

    let tally = SubtaskTally(task)
    XCTAssertTrue(tally.isEmpty)
    XCTAssertEqual(tally.fraction, 0)
  }

  func testFractionIsDoneOverTotal() throws {
    let ctx = try makeContext()
    let task = TaskItem(title: "T")
    ctx.insert(task)
    task.addSubtask().isDone = true
    _ = task.addSubtask()

    XCTAssertEqual(SubtaskTally(task).fraction, 0.5, accuracy: 0.0001)
  }
}
