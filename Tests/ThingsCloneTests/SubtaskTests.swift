import SwiftData
import XCTest

@testable import ThingsClone

final class SubtaskTests: XCTestCase {
  /// Conteneur en mémoire : les tests de modèle ne touchent jamais le vrai store sur disque.
  private func makeContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  func testAddSubtask_appendsInOrderAndReturnsObject() throws {
    let ctx = try makeContext()
    let task = TaskItem(title: "T")
    ctx.insert(task)

    let a = task.addSubtask(); a.title = "a"
    let b = task.addSubtask(); b.title = "b"

    XCTAssertEqual(task.orderedSubtasks.map(\.title), ["a", "b"])
    XCTAssertEqual(b.sortIndex, a.sortIndex + 1)
  }

  func testOrderedSubtasks_sortsBySortIndex() throws {
    let ctx = try makeContext()
    let task = TaskItem(title: "T")
    ctx.insert(task)

    let a = task.addSubtask(); a.title = "a"
    let b = task.addSubtask(); b.title = "b"
    b.sortIndex = -5  // b passe devant

    XCTAssertEqual(task.orderedSubtasks.map(\.title), ["b", "a"])
  }

  func testDeletingTask_cascadesToSubtasks() throws {
    let ctx = try makeContext()
    let task = TaskItem(title: "T")
    ctx.insert(task)
    _ = task.addSubtask()
    try ctx.save()

    ctx.delete(task)
    try ctx.save()

    let remaining = try ctx.fetch(FetchDescriptor<Subtask>())
    XCTAssertTrue(remaining.isEmpty, "la suppression en cascade doit retirer les sous-tâches")
  }
}
