import XCTest

@testable import Today

/// `TodoList.appendAnchor` : où une tâche neuve doit s'accrocher pour ne pas atterrir sous les
/// cochées que `moveToEndOfSection` repousse en bas.
final class TodoListTests: XCTestCase {
  func testAncre_surLaDerniereNonCochee() {
    let a = TaskItem(title: "a")
    a.sortIndex = 0
    let b = TaskItem(title: "b")
    b.sortIndex = 1
    let doneC = TaskItem(title: "c")
    doneC.sortIndex = 2
    doneC.isCompleted = true

    XCTAssertEqual(TodoList.appendAnchor(among: [a, b, doneC])?.title, "b")
  }

  func testAncre_nilQuandToutEstCoche() {
    let doneA = TaskItem(title: "a")
    doneA.isCompleted = true
    let doneB = TaskItem(title: "b")
    doneB.isCompleted = true

    XCTAssertNil(TodoList.appendAnchor(among: [doneA, doneB]))
  }

  func testAncre_nilQuandVide() {
    XCTAssertNil(TodoList.appendAnchor(among: []))
  }

  func testAncre_ignoreLesCocheesIntercalees() {
    // Une tâche non cochée peut suivre une cochée si l'utilisateur l'a glissée là à la main :
    // l'ancre reste la DERNIÈRE non cochée, quelle que soit sa position.
    let doneA = TaskItem(title: "a")
    doneA.isCompleted = true
    let b = TaskItem(title: "b")

    XCTAssertEqual(TodoList.appendAnchor(among: [doneA, b])?.title, "b")
  }
}
