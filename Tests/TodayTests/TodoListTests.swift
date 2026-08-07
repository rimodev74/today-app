import SwiftData
import XCTest

@testable import Today

/// `TodoList.appendAnchor` : où une tâche neuve doit s'accrocher pour ne pas atterrir sous les
/// cochées que `moveToEndOfSection` repousse en bas.
final class TodoListTests: XCTestCase {
  /// `orderedTasks` lit la VRAIE relation `TodoList.tasks` : un objet détaché (jamais inséré dans
  /// un contexte) ne la remplit pas, cf. `AllTasksPageTests`.
  private func makeContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: config))
  }

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

  /// `moveAboveCompleted` : cocher PUIS décocher la MÊME tâche doit la faire remonter — le cas le
  /// plus courant, et celui qu'une version précédente ratait. Cette version-là ancrait la tâche
  /// décochée juste au-dessus des autres cochées : quand c'est la SEULE tâche cochée de la
  /// section, cette ancre est déjà sa position courante (`moveToEndOfSection` l'avait posée juste
  /// après la dernière active, exactement là où l'ancre retombe) — aucun mouvement.
  func testDecocher_laMemeTacheQuonVientDeCocher_remonte() throws {
    let ctx = try makeContext()
    let list = TodoList(title: "l")
    ctx.insert(list)
    let a = TaskItem(title: "a", list: list)
    let b = TaskItem(title: "b", list: list)
    let c = TaskItem(title: "c", list: list)
    for t in [a, b, c] { ctx.insert(t) }
    for (i, t) in [a, b, c].enumerated() { t.sortIndex = i }

    b.isCompleted = true
    list.moveToEndOfSection(b)
    XCTAssertEqual(list.orderedTasks.map(\.title), ["a", "c", "b"])

    b.isCompleted = false
    list.moveAboveCompleted(b)
    XCTAssertEqual(list.orderedTasks.map(\.title), ["b", "a", "c"])
  }

  /// Décocher remonte en TÊTE de section, devant tout — actives comprises, pas seulement devant
  /// ce qui reste coché.
  func testDecocher_remonteEnTeteDeSection() throws {
    let ctx = try makeContext()
    let list = TodoList(title: "l")
    ctx.insert(list)
    let a = TaskItem(title: "a", list: list)
    let b = TaskItem(title: "b", list: list)
    let c = TaskItem(title: "c", list: list)
    for t in [a, b, c] { ctx.insert(t) }
    for (i, t) in [a, b, c].enumerated() { t.sortIndex = i }

    // b puis c cochées : chacune descend en bas, dans l'ordre où elle a été cochée.
    b.isCompleted = true
    list.moveToEndOfSection(b)
    c.isCompleted = true
    list.moveToEndOfSection(c)
    XCTAssertEqual(list.orderedTasks.map(\.title), ["a", "b", "c"])

    // On décoche c (la plus profonde) : tête de section, devant a ET devant b encore cochée.
    c.isCompleted = false
    list.moveAboveCompleted(c)
    XCTAssertEqual(list.orderedTasks.map(\.title), ["c", "a", "b"])
  }

  func testDecocher_reglageDesactive_neBougePas() throws {
    UserDefaults.standard.set(false, forKey: TodoList.autoSortCompletedStorageKey)
    defer { UserDefaults.standard.removeObject(forKey: TodoList.autoSortCompletedStorageKey) }

    let ctx = try makeContext()
    let list = TodoList(title: "l")
    ctx.insert(list)
    let a = TaskItem(title: "a", list: list)
    let b = TaskItem(title: "b", list: list)
    for t in [a, b] { ctx.insert(t) }
    a.sortIndex = 0
    b.sortIndex = 1

    b.isCompleted = false
    list.moveAboveCompleted(b)
    XCTAssertEqual(list.orderedTasks.map(\.title), ["a", "b"])
  }
}
