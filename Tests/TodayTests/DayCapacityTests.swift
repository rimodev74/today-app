import XCTest

@testable import Today

final class DayCapacityTests: XCTestCase {
  /// 14h00 pile, journée finissant à 18h → 240 min disponibles.
  private func earlyAfternoon() -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 7
    components.day = 27
    components.hour = 14
    return Calendar.current.date(from: components)!
  }

  func testFitsInDay_isNotOverbooked() {
    let capacity = DayCapacity(
      estimates: [60, 30, 15], now: earlyAfternoon(), endOfDayHour: 18)
    XCTAssertEqual(capacity.plannedMinutes, 105)
    XCTAssertEqual(capacity.availableMinutes, 240)
    XCTAssertFalse(capacity.isOverbooked)
    XCTAssertEqual(capacity.fill, 105.0 / 240.0, accuracy: 0.001)
  }

  func testOverbooked_reportsOverflowAndCapsFill() {
    let capacity = DayCapacity(
      estimates: [240, 120], now: earlyAfternoon(), endOfDayHour: 18)
    XCTAssertEqual(capacity.overflowMinutes, 120)
    XCTAssertEqual(capacity.fill, 1)
  }

  func testUnestimatedTasks_countZeroMinutesButAreSignalled() {
    let capacity = DayCapacity(
      estimates: [60, 0, 0], now: earlyAfternoon(), endOfDayHour: 18)
    XCTAssertEqual(capacity.plannedMinutes, 60)
    XCTAssertEqual(capacity.unestimatedCount, 2)
  }

  /// Après l'heure de fin : plus une minute disponible, donc tout ce qui reste est en dépassement.
  func testPastEndOfDay_hasNoCapacityLeft() {
    let capacity = DayCapacity(estimates: [30], now: earlyAfternoon(), endOfDayHour: 9)
    XCTAssertEqual(capacity.availableMinutes, 0)
    XCTAssertEqual(capacity.overflowMinutes, 30)
    XCTAssertEqual(capacity.fill, 1)
  }

  func testEstimateLabel() {
    XCTAssertNil(Estimate.label(0))
    XCTAssertEqual(Estimate.label(45), "45 min")
    XCTAssertEqual(Estimate.label(120), "2 h")
    XCTAssertEqual(Estimate.label(90), "1 h 30")
  }
}
