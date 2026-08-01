import SwiftData
import XCTest

@testable import Today

/// L'anneau doit mesurer le flux VISIBLE : les tâches archivées ne comptent ni au numérateur ni au
/// dénominateur. Sans ça, une liste au long cours (trente archivées, deux à faire) affichait un
/// disque quasi plein devant une page où rien n'est fait.
final class ListProgressTests: XCTestCase {
  private var context: ModelContext!

  override func setUpWithError() throws {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    context = ModelContext(try ModelContainer(for: schema, configurations: config))
    UserDefaults.standard.set(
      CompletedTaskRetention.untilViewChange.rawValue, forKey: CompletedTaskRetention.storageKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: CompletedTaskRetention.storageKey)
  }

  /// `completedAt` daté d'hier : au-delà du délai, donc archivée dans tous les modes sauf `.never`.
  @discardableResult
  private func addTask(to list: TodoList, completed: Bool, archived: Bool = true) -> TaskItem {
    let task = TaskItem(title: "t", list: list)
    task.isCompleted = completed
    if completed {
      task.completedAt = archived ? Date().addingTimeInterval(-86_400) : Date()
    }
    context.insert(task)
    list.tasks.append(task)
    return task
  }

  func testProgress_tousArchivés_anneauVide() {
    let list = TodoList(title: "Courses")
    context.insert(list)
    addTask(to: list, completed: true)
    addTask(to: list, completed: true)
    XCTAssertEqual(list.progress, 0)
  }

  /// Le plein doit rester visible tant que la dernière cochée n'a pas quitté le flux : sinon
  /// l'anneau ne se remplirait jamais.
  func testProgress_uneCochéeEncoreDansLeFlux_compteEncore() {
    let list = TodoList(title: "Courses")
    context.insert(list)
    addTask(to: list, completed: true)
    addTask(to: list, completed: true, archived: false)
    XCTAssertEqual(list.progress, 1)
  }

  /// Les archivées ne comptent plus DU TOUT : l'anneau mesure ce que la page montre. Une liste où
  /// il reste deux tâches à faire derrière trente archivées est une liste où rien n'est fait.
  func testProgress_archivéesIgnorées_seulLeFluxCompte() {
    let list = TodoList(title: "Courses")
    context.insert(list)
    addTask(to: list, completed: true)
    addTask(to: list, completed: false)
    XCTAssertEqual(list.progress, 0)
  }

  /// « Ne jamais les masquer » : rien ne quitte le flux, donc le disque plein reste — c'est
  /// exactement ce que le réglage promet.
  func testProgress_rétentionNever_gardeLeDisquePlein() {
    UserDefaults.standard.set(
      CompletedTaskRetention.never.rawValue, forKey: CompletedTaskRetention.storageKey)
    let list = TodoList(title: "Courses")
    context.insert(list)
    addTask(to: list, completed: true)
    XCTAssertEqual(list.progress, 1)
  }

  func testProjectProgress_toutArchivé_anneauVide() {
    let project = Project(title: "Déménagement")
    let list = TodoList(title: "Cartons", project: project)
    context.insert(project)
    project.lists.append(list)
    context.insert(list)
    addTask(to: list, completed: true)
    XCTAssertEqual(project.progress, 0)
  }
}
