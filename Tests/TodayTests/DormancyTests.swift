import XCTest

@testable import Today

final class DormancyTests: XCTestCase {
  func testFade_isFullBeforeThreshold() {
    XCTAssertEqual(Dormancy.fade(days: 0), 1)
    XCTAssertEqual(Dormancy.fade(days: Dormancy.thresholdDays), 1)
  }

  func testFade_decreasesBetweenThresholdAndFloor() {
    let early = Dormancy.fade(days: Dormancy.thresholdDays + 7)
    let late = Dormancy.fade(days: Dormancy.floorDays - 7)
    XCTAssertLessThan(early, 1)
    XCTAssertLessThan(late, early)
    XCTAssertGreaterThan(late, Dormancy.minOpacity)
  }

  /// Le plancher existe pour que la ligne reste lisible : une tâche vieille d'un an ne doit pas
  /// être plus effacée qu'une de deux mois.
  func testFade_stopsAtFloor() {
    XCTAssertEqual(Dormancy.fade(days: Dormancy.floorDays), Dormancy.minOpacity)
    XCTAssertEqual(Dormancy.fade(days: 365), Dormancy.minOpacity)
  }

  func testDays_countsCalendarDays() {
    let now = Date()
    let past = now.addingTimeInterval(-30 * 24 * 3600)
    XCTAssertEqual(Dormancy.days(since: past, now: now), 30)
  }
}
