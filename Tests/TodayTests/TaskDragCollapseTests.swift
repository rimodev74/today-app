import SwiftData
import XCTest

@testable import Today

/// Le repli des sous-tâches le temps d'un glissement, partagé par les trois moteurs de l'app.
/// La règle qui compte est le `true` de retour : c'est lui qui fait RENONCER l'appelant à l'image
/// courante, et donc lui qui garantit une mise en page entre le repli et le gel des cadres.
@MainActor
final class TaskDragCollapseTests: XCTestCase {
  /// Conteneur en mémoire : ces tests ne touchent jamais le vrai store (cf. `SubtaskTests`).
  private func makeTask(subtasks: Int) throws -> TaskItem {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let context = ModelContext(try ModelContainer(for: schema, configurations: config))
    let task = TaskItem(title: "Tirée")
    context.insert(task)
    for _ in 0..<subtasks { _ = task.addSubtask() }
    return task
  }

  func testShortMoveDoesNotCollapse() throws {
    let task = try makeTask(subtasks: 3)
    var collapse = TaskDragCollapse()
    // Un clic ne parcourt pas 3 pt : il ne doit rien replier.
    XCTAssertFalse(collapse.collapseIfNeeded(task, translation: CGSize(width: 2, height: 2)))
    XCTAssertFalse(collapse.isCollapsed(task))
    XCTAssertFalse(collapse.isCollapsing)
  }

  func testCrossingTheThresholdCollapsesOnceAndYieldsThatFrame() throws {
    let task = try makeTask(subtasks: 3)
    var collapse = TaskDragCollapse()
    XCTAssertTrue(collapse.collapseIfNeeded(task, translation: CGSize(width: 0, height: 5)))
    XCTAssertTrue(collapse.isCollapsed(task))
    // Les images SUIVANTES rendent `false` : sans ça l'appelant renoncerait à tout le geste et
    // n'armerait jamais son moteur.
    XCTAssertFalse(collapse.collapseIfNeeded(task, translation: CGSize(width: 0, height: 40)))
  }

  func testATaskWithoutSubtasksNeverCollapses() throws {
    let task = try makeTask(subtasks: 0)
    var collapse = TaskDragCollapse()
    XCTAssertFalse(collapse.collapseIfNeeded(task, translation: CGSize(width: 0, height: 40)))
    XCTAssertFalse(collapse.isCollapsing)
  }

  func testResetReopensWhateverHappenedBefore() throws {
    let task = try makeTask(subtasks: 2)
    var collapse = TaskDragCollapse()
    _ = collapse.collapseIfNeeded(task, translation: CGSize(width: 0, height: 5))
    collapse.reset()
    XCTAssertFalse(collapse.isCollapsed(task))
    XCTAssertFalse(collapse.isCollapsing)
  }

  /// Le seuil de repli doit rester SOUS celui d'empoignade de chaque page (6 pt côté
  /// `ListPageView`, 4 pt côté `RowPressGesture`) — c'est ce demi-pas qui laisse passer une mise en
  /// page pendant que les cadres sont encore vivants.
  func testCollapseThresholdStaysBelowTheGrabThresholds() {
    XCTAssertLessThan(TaskDragCollapse.threshold, 4)
  }
}
