import XCTest

@testable import Today

/// **Le premier test d'une PAGE.** Ce qu'aucun des 125 autres ne couvrait.
///
/// Jusqu'ici tout le calcul d'une page vivait dans la vue, mêlé à `@Query` : la seule façon de
/// vérifier ce qu'elle affiche était de cliquer. Une page pouvait donc perdre une ligne ou l'ordre
/// de ses tâches sans qu'aucun test ne rougisse — c'est arrivé.
///
/// La question posée ici est exactement celle qu'on se posait à l'œil : *avec ces tâches-là, que
/// montre la page, et dans quel ordre ?*
final class TodayPageTests: XCTestCase {
  private let calendar = Calendar.current

  private func task(_ title: String, daysFromToday: Int?, list: TodoList? = nil) -> TaskItem {
    let when = daysFromToday.map {
      calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: Date()))!
    }
    return TaskItem(title: title, when: when, list: list)
  }

  // MARK: Le jour, et rien d'autre

  func testKeepsOnlyTheDayAtTheTop() {
    let page = TodayPage.build(from: [
      task("aujourd'hui", daysFromToday: 0),
      task("demain", daysFromToday: 1),
      task("hier", daysFromToday: -1),
    ])

    XCTAssertEqual(page.tasks.map(\.title), ["aujourd'hui"])
  }

  /// La règle qui tient toute la page : une tâche en retard n'est repêchée NULLE PART — elle est
  /// retournée dans sa liste.
  func testYesterdayIsNowhereOnThePage() {
    let page = TodayPage.build(from: [task("hier", daysFromToday: -1)])

    XCTAssertTrue(page.tasks.isEmpty)
  }

  /// Une tâche sans date n'apparaît pas sur cette page : elle reste dans sa liste ou son projet.
  func testUndatedTasksAreNotShown() {
    let page = TodayPage.build(from: [
      task("sans date", daysFromToday: nil),
      task("du jour", daysFromToday: 0),
    ])

    XCTAssertEqual(page.tasks.map(\.title), ["du jour"])
  }

  /// Une tâche cochée du jour RESTE affichée, barrée, jusqu'au lendemain.
  func testCompletedStaysForTheDay() {
    let doneToday = task("faite aujourd'hui", daysFromToday: 0)
    doneToday.isCompleted = true

    let page = TodayPage.build(from: [doneToday])

    XCTAssertEqual(page.tasks.map(\.title), ["faite aujourd'hui"])
  }

  /// Une en-tête de section n'est pas une tâche : elle n'a rien à faire sur cette page.
  func testHeadersAreNotRows() {
    let header = TaskItem(title: "section", when: nil, isHeader: true)
    let page = TodayPage.build(from: [header])

    XCTAssertTrue(page.tasks.isEmpty)
  }

  // MARK: Les pans, c'est-à-dire ce que le clavier parcourt

  /// Le seul pan de la page, toujours visible.
  func testBlocksExposeAllTasksToTheKeyboard() {
    let page = TodayPage.build(from: [task("du jour", daysFromToday: 0)])

    XCTAssertEqual(page.blocks.displayedRows.map(\.title), ["du jour"])
  }
}
