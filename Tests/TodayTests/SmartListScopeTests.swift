import XCTest

@testable import Today

/// Le partage des tâches entre « Aujourd'hui » et « À venir ». La règle qui compte : une tâche
/// datée d'un jour passé n'est dans AUCUNE des deux — elle est retournée dans sa liste ou son
/// projet. C'est ce qui distingue « Aujourd'hui » d'une pile de retards, et rien à l'écran ne le
/// dit ; seul ce test le tient.
final class SmartListScopeTests: XCTestCase {
  private let calendar = Calendar.current

  private func task(daysFromToday: Int?) -> TaskItem {
    let when = daysFromToday.map {
      calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: Date()))!
    }
    return TaskItem(title: "t", when: when)
  }

  func testToday_prendLeJourMemeUniquement() {
    XCTAssertTrue(SmartList.today.scopeMatches(task(daysFromToday: 0)))
    XCTAssertFalse(SmartList.today.scopeMatches(task(daysFromToday: -1)))
    XCTAssertFalse(SmartList.today.scopeMatches(task(daysFromToday: 1)))
    XCTAssertFalse(SmartList.today.scopeMatches(task(daysFromToday: nil)))
  }

  /// Une heure tardive reste le même jour : le filtre compare des jours, pas des instants.
  func testToday_ignoreLHeure() {
    let ceSoir = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: Date())!
    XCTAssertTrue(SmartList.today.scopeMatches(TaskItem(title: "t", when: ceSoir)))
  }

  func testUpcoming_commenceDemain() {
    XCTAssertFalse(SmartList.upcoming.scopeMatches(task(daysFromToday: 0)))
    XCTAssertTrue(SmartList.upcoming.scopeMatches(task(daysFromToday: 1)))
    XCTAssertFalse(SmartList.upcoming.scopeMatches(task(daysFromToday: nil)))
  }

  /// Le trou est délibéré : le retard ne s'empile nulle part.
  func testUneTacheEnRetardNestDansAucuneVueDatee() {
    let hier = task(daysFromToday: -1)
    XCTAssertFalse(SmartList.today.scopeMatches(hier))
    XCTAssertFalse(SmartList.upcoming.scopeMatches(hier))
  }

  /// Une tâche cochée du jour reste dans le périmètre (`scoped`) alors que `filter` l'écarte —
  /// c'est ce qui la laisse affichée, barrée, jusqu'à minuit. Et le réglage « Descendre en bas de
  /// la liste » la fait passer sous ce qui reste à faire, priorité comprise.
  func testCochee_resteAffichee_maisDescendEnBas() {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: TodoList.autoSortCompletedStorageKey)
    defaults.set(true, forKey: TodoList.autoSortCompletedStorageKey)
    defer { defaults.set(previous, forKey: TodoList.autoSortCompletedStorageKey) }

    let faite = task(daysFromToday: 0)
    faite.title = "faite"
    faite.isCompleted = true
    faite.priority = .high
    let aFaire = task(daysFromToday: 0)
    aFaire.title = "à faire"

    let all = [faite, aFaire]
    XCTAssertEqual(SmartList.today.filter(all).count, 1)
    XCTAssertEqual(SmartList.today.scoped(all).count, 2)
    XCTAssertEqual(
      SmartList.today.sort(SmartList.today.scoped(all)).map(\.title), ["à faire", "faite"])

    defaults.set(false, forKey: TodoList.autoSortCompletedStorageKey)
    // Réglage coupé : la priorité haute de la cochée reprend la main.
    XCTAssertEqual(
      SmartList.today.sort(SmartList.today.scoped(all)).map(\.title), ["faite", "à faire"])
  }

  /// Une en-tête de section n'est jamais une tâche, quelle que soit sa date.
  func testEnTeteJamaisRetenue() {
    let header = TaskItem(title: "s", when: Date(), isHeader: true)
    XCTAssertFalse(SmartList.today.scopeMatches(header))
  }
}
