import Foundation
import XCTest

@testable import Today

/// La grille est de l'arithmétique de calendrier : ce sont ses bords qui cassent, pas son milieu.
/// D'où des calendriers FIGÉS (lundi et dimanche en premier jour), et pas `Calendar.current` — un
/// test qui dépend de la région de la machine ne dit rien.
final class MonthGridTests: XCTestCase {
  /// Août 2026 : le 1er tombe un samedi. Grille lundi-en-premier ⇒ elle démarre le lundi 27 juillet.
  private static let august2026 = DateComponents(
    calendar: mondayFirst, year: 2026, month: 8, day: 10
  ).date!

  private static var mondayFirst: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    calendar.locale = Locale(identifier: "fr_FR")
    calendar.firstWeekday = 2
    return calendar
  }

  private static var sundayFirst: Calendar {
    var calendar = mondayFirst
    calendar.locale = Locale(identifier: "en_US")
    calendar.firstWeekday = 1
    return calendar
  }

  func testAlwaysSixFullWeeks() {
    let calendar = Self.mondayFirst
    // Février 2026 commence un dimanche et fait 28 jours : le mois qui tient dans le moins de
    // semaines. La grille en donne six quand même — c'est tout l'intérêt d'une hauteur fixe.
    for month in 1...12 {
      let date = DateComponents(calendar: calendar, year: 2026, month: month, day: 1).date!
      let grid = MonthGrid(containing: date, calendar: calendar)
      XCTAssertEqual(grid.days.count, 42, "mois \(month)")
    }
  }

  func testStartsOnTheUsersFirstWeekday() {
    let monday = MonthGrid(containing: Self.august2026, calendar: Self.mondayFirst)
    XCTAssertEqual(
      Self.mondayFirst.component(.weekday, from: monday.days[0]), 2, "doit démarrer un lundi")

    let sunday = MonthGrid(containing: Self.august2026, calendar: Self.sundayFirst)
    XCTAssertEqual(
      Self.sundayFirst.component(.weekday, from: sunday.days[0]), 1, "doit démarrer un dimanche")
  }

  func testLeadingDaysComeFromThePreviousMonth() {
    let calendar = Self.mondayFirst
    let grid = MonthGrid(containing: Self.august2026, calendar: calendar)
    // 27 28 29 30 31 (juillet) puis 1 2 (août) — exactement ce qu'affichait le picker natif.
    XCTAssertEqual(
      grid.days.prefix(7).map { calendar.component(.day, from: $0) }, [27, 28, 29, 30, 31, 1, 2])
    XCTAssertFalse(grid.isInMonth(grid.days[0], calendar: calendar))
    XCTAssertTrue(grid.isInMonth(grid.days[5], calendar: calendar))
  }

  func testDaysAreConsecutiveStartsOfDay() {
    let calendar = Self.mondayFirst
    let grid = MonthGrid(containing: Self.august2026, calendar: calendar)
    for day in grid.days {
      XCTAssertEqual(day, calendar.startOfDay(for: day))
    }
    for (previous, next) in zip(grid.days, grid.days.dropFirst()) {
      XCTAssertEqual(calendar.dateComponents([.day], from: previous, to: next).day, 1)
    }
  }

  /// Le passage à l'heure d'hiver ajoute une heure à la journée : un saut de 86 400 s manquerait le
  /// jour suivant. `byAdding: .day` ne s'y trompe pas — ce test est là pour que ça reste vrai.
  func testCrossesDaylightSavingWithoutSlipping() {
    let calendar = Self.mondayFirst
    let october = DateComponents(calendar: calendar, year: 2026, month: 10, day: 1).date!
    let grid = MonthGrid(containing: october, calendar: calendar)
    let days = grid.days.map { calendar.component(.day, from: $0) }
    // Le changement d'heure français tombe le dimanche 25 octobre 2026.
    XCTAssertTrue(days.contains(25))
    XCTAssertTrue(days.contains(26))
    for day in grid.days { XCTAssertEqual(calendar.component(.hour, from: day), 0) }
  }

  func testAdvancedMovesByWholeMonths() {
    let calendar = Self.mondayFirst
    let grid = MonthGrid(containing: Self.august2026, calendar: calendar)
    let december = grid.advanced(byMonths: 4, calendar: calendar)
    XCTAssertEqual(calendar.component(.month, from: december.month), 12)
    XCTAssertEqual(calendar.component(.year, from: december.month), 2026)
    // Et le retour tombe pile sur le mois de départ, changement d'année compris.
    XCTAssertEqual(december.advanced(byMonths: -4, calendar: calendar), grid)
    XCTAssertEqual(
      calendar.component(.year, from: grid.advanced(byMonths: -8, calendar: calendar).month), 2025)
  }

  func testWeekdaySymbolsFollowTheCalendar() {
    let monday = MonthGrid.weekdaySymbols(Self.mondayFirst)
    XCTAssertEqual(monday.count, 7)
    XCTAssertEqual(monday.first, Self.mondayFirst.shortWeekdaySymbols[1], "lundi en tête")
    XCTAssertEqual(monday.last, Self.mondayFirst.shortWeekdaySymbols[0], "dimanche en queue")

    let sunday = MonthGrid.weekdaySymbols(Self.sundayFirst)
    XCTAssertEqual(sunday.first, Self.sundayFirst.shortWeekdaySymbols[0], "dimanche en tête")
  }
}
