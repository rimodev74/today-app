import XCTest

@testable import Today

/// **Le premier test d'une PAGE.** Ce qu'aucun des 125 autres ne couvrait.
///
/// Jusqu'ici tout le calcul d'une page vivait dans la vue, mêlé à `@Query` : la seule façon de
/// vérifier ce qu'elle affiche était de cliquer. Une page pouvait donc perdre une ligne, un
/// groupe, ou l'ordre de ses sections sans qu'aucun test ne rougisse — c'est arrivé.
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

  // MARK: Le partage jour / réserve

  func testKeepsOnlyTheDayAtTheTop() {
    let page = TodayPage.build(from: [
      task("aujourd'hui", daysFromToday: 0),
      task("demain", daysFromToday: 1),
      task("hier", daysFromToday: -1),
    ])

    XCTAssertEqual(page.tasks.map(\.title), ["aujourd'hui"])
  }

  /// La règle qui tient toute la page : une tâche en retard n'est repêchée NULLE PART. Ni dans le
  /// jour, ni dans la réserve (elle a une date) — elle est retournée dans sa liste.
  func testYesterdayIsNowhereOnThePage() {
    let page = TodayPage.build(from: [task("hier", daysFromToday: -1)])

    XCTAssertTrue(page.tasks.isEmpty)
    XCTAssertEqual(page.undatedCount, 0)
  }

  func testUndatedTasksGoToTheReserve() {
    let page = TodayPage.build(from: [
      task("sans date", daysFromToday: nil),
      task("du jour", daysFromToday: 0),
    ])

    XCTAssertEqual(page.tasks.map(\.title), ["du jour"])
    XCTAssertEqual(page.undated.flatMap { $0.tasks }.map(\.title), ["sans date"])
  }

  /// Une tâche cochée du jour RESTE affichée, barrée, jusqu'au lendemain. Une tâche cochée sans
  /// date, elle, n'a rien à faire dans la réserve : on n'y pioche que ce qui reste à faire.
  func testCompletedStaysForTheDayButNotInTheReserve() {
    let doneToday = task("faite aujourd'hui", daysFromToday: 0)
    doneToday.isCompleted = true
    let doneUndated = task("faite sans date", daysFromToday: nil)
    doneUndated.isCompleted = true

    let page = TodayPage.build(from: [doneToday, doneUndated])

    XCTAssertEqual(page.tasks.map(\.title), ["faite aujourd'hui"])
    XCTAssertEqual(page.undatedCount, 0)
  }

  /// Une en-tête de section n'est pas une tâche : elle n'a rien à faire sur cette page.
  func testHeadersAreNotRows() {
    let header = TaskItem(title: "section", when: nil, isHeader: true)
    let page = TodayPage.build(from: [header])

    XCTAssertTrue(page.tasks.isEmpty)
    XCTAssertEqual(page.undatedCount, 0)
  }

  // MARK: Les groupes de la réserve

  func testReserveIsGroupedByParent() {
    let courses = TodoList(title: "Courses")
    let boulot = TodoList(title: "Boulot")

    let page = TodayPage.build(from: [
      task("pain", daysFromToday: nil, list: courses),
      task("devis", daysFromToday: nil, list: boulot),
      task("lait", daysFromToday: nil, list: courses),
    ])

    XCTAssertEqual(page.undated.map(\.name), ["Courses", "Boulot"])
    XCTAssertEqual(page.undated.first?.tasks.map(\.title), ["pain", "lait"])
    XCTAssertEqual(page.undatedCount, 3)
  }

  /// Sans liste ni projet, une tâche a quand même besoin d'un groupe — un titre vide ne se lit pas.
  func testTasksWithoutAParentGetANamedGroup() {
    let page = TodayPage.build(from: [task("orpheline", daysFromToday: nil)])

    XCTAssertEqual(page.undated.map(\.name), ["Sans projet"])
  }

  // MARK: Les pans, c'est-à-dire ce que le clavier parcourt

  /// Réserve repliée : ses lignes sont DÉCLARÉES mais ne se parcourent pas. Sans ça, ↑/↓
  /// emmèneraient la sélection sur une ligne que l'œil ne voit pas.
  func testCollapsedReserveOffersNoRowToTheKeyboard() {
    let page = TodayPage.build(from: [
      task("du jour", daysFromToday: 0),
      task("sans date", daysFromToday: nil),
    ])

    XCTAssertEqual(page.blocks(undatedExpanded: false).displayedRows.map(\.title), ["du jour"])
    XCTAssertEqual(
      page.blocks(undatedExpanded: true).displayedRows.map(\.title), ["du jour", "sans date"])
  }

  /// L'ordre des pans EST l'ordre du rendu : le jour d'abord, la réserve ensuite. C'est ce que
  /// suivent ↑ et ↓.
  func testBlocksFollowTheRenderedOrder() {
    let courses = TodoList(title: "Courses")
    let page = TodayPage.build(from: [
      task("sans date", daysFromToday: nil, list: courses),
      task("du jour", daysFromToday: 0),
    ])

    XCTAssertEqual(
      page.blocks(undatedExpanded: true).displayedRows.map(\.title), ["du jour", "sans date"])
  }
}
