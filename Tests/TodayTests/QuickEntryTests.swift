import XCTest

@testable import Today

final class QuickEntryTests: XCTestCase {
  /// Lundi 27 juillet 2026, 14h.
  private let now: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 7
    components.day = 27
    components.hour = 14
    return Calendar.current.date(from: components)!
  }()

  private func parse(_ raw: String, names: [String] = []) -> QuickEntry {
    QuickEntry(parsing: raw, names: names, now: now)
  }

  private func day(_ entry: QuickEntry) -> DateComponents? {
    entry.when.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) }
  }

  func testDateTokenIsStrippedFromTitle() {
    let entry = parse("@today Faire la vaisselle")
    XCTAssertEqual(entry.title, "Faire la vaisselle")
    XCTAssertEqual(day(entry), DateComponents(year: 2026, month: 7, day: 27))
  }

  func testTokenAnywhereAndAccentInsensitive() {
    let entry = parse("Faire la vaisselle @Aujourd'hui".replacingOccurrences(of: "'", with: ""))
    XCTAssertEqual(entry.title, "Faire la vaisselle")
    XCTAssertEqual(day(entry), DateComponents(year: 2026, month: 7, day: 27))
  }

  func testDemainAndRelativeDays() {
    XCTAssertEqual(day(parse("@demain X")), DateComponents(year: 2026, month: 7, day: 28))
    XCTAssertEqual(day(parse("@+3j X")), DateComponents(year: 2026, month: 7, day: 30))
  }

  /// « @lundi » un lundi vise le lundi suivant, pas aujourd'hui.
  func testWeekdayIsAlwaysInTheFuture() {
    XCTAssertEqual(day(parse("@lundi X")), DateComponents(year: 2026, month: 8, day: 3))
    XCTAssertEqual(day(parse("@friday X")), DateComponents(year: 2026, month: 7, day: 31))
  }

  func testNumericDates() {
    XCTAssertEqual(day(parse("@12/08 X")), DateComponents(year: 2026, month: 8, day: 12))
    XCTAssertEqual(day(parse("@3/2/27 X")), DateComponents(year: 2027, month: 2, day: 3))
    // Jour déjà passé sans année : l'an prochain.
    XCTAssertEqual(day(parse("@1/1 X")), DateComponents(year: 2027, month: 1, day: 1))
  }

  func testUnknownTokensStayInTheTitle() {
    XCTAssertEqual(parse("Écrire à jean@exemple.fr").title, "Écrire à jean@exemple.fr")
    XCTAssertEqual(parse("@40/40 Relire").title, "@40/40 Relire")
    XCTAssertEqual(parse("Relire #42").title, "Relire #42")
    XCTAssertNil(parse("Relire #Courses").target)
  }

  func testTargetMatchesIgnoringCaseAccentsAndSpaces() {
    XCTAssertEqual(parse("#courses Lait", names: ["Courses"]).target, "Courses")
    XCTAssertEqual(parse("#malist Lait", names: ["Ma Liste"]).target, "Ma Liste")
    // Préfixe suffisant, et le jeton disparaît du titre.
    let entry = parse("#cou Lait", names: ["Courses"])
    XCTAssertEqual(entry.target, "Courses")
    XCTAssertEqual(entry.title, "Lait")
  }

  func testCombinedTokens() {
    let entry = parse("@demain #Courses Acheter du lait", names: ["Courses"])
    XCTAssertEqual(entry.title, "Acheter du lait")
    XCTAssertEqual(entry.target, "Courses")
    XCTAssertEqual(day(entry), DateComponents(year: 2026, month: 7, day: 28))
  }

  func testTokensOnlyGivesNoTitle() {
    XCTAssertTrue(parse("@today").title.isEmpty)
  }

  // MARK: Saisie en cours (pastilles)

  private func consume(_ text: String, names: [String] = []) -> (text: String, entry: QuickEntry)? {
    QuickEntry.consuming(text, names: names, now: now)
  }

  /// Tant qu'aucun espace ne suit le jeton, on ne touche à rien : « @tod » reste corrigeable.
  func testTokenIsNotConsumedBeforeItsSpace() {
    XCTAssertNil(consume("@tod"))
    XCTAssertNil(consume("@today"))
  }

  func testSpaceValidatesTokenAndClearsTheText() {
    let result = consume("@today ")
    XCTAssertEqual(result?.text, "")
    XCTAssertNotNil(result?.entry.when)
  }

  /// Le mot en cours de frappe survit au retrait du jeton.
  func testConsumingKeepsTheWordInProgress() {
    XCTAssertEqual(consume("@today Faire la vais")?.text, "Faire la vais")
    XCTAssertEqual(consume("Faire @demain la ")?.text, "Faire la ")
  }

  func testNothingToConsume() {
    XCTAssertNil(consume("Faire la vaisselle "))
    XCTAssertNil(consume("#inconnu ", names: ["Courses"]))
  }
}
