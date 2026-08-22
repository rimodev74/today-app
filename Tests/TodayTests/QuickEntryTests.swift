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

  // MARK: Réconciliation d'un jeton de liste (Réglages)

  func testReconciledListTokenFollowsARenamedList() {
    // « Courses » est devenue « Courses de la semaine » : le jeton enregistré, lui, n'a pas bougé.
    XCTAssertEqual(
      QuickEntry.reconciledListToken("#Courses", against: ["Courses de la semaine"]),
      "#Coursesdelasemaine")
  }

  func testReconciledListTokenLeavesNonListTokensAlone() {
    XCTAssertEqual(QuickEntry.reconciledListToken("@today", against: ["Courses"]), "@today")
    XCTAssertEqual(QuickEntry.reconciledListToken("!today", against: ["Courses"]), "!today")
  }

  func testReconciledListTokenLeavesAnAlreadyCorrectTokenAlone() {
    XCTAssertEqual(QuickEntry.reconciledListToken("#Courses", against: ["Courses"]), "#Courses")
  }

  /// Liste supprimée entre-temps : rien à quoi se raccrocher, le jeton reste tel quel plutôt que
  /// de sauter vers une autre liste par accident.
  func testReconciledListTokenKeepsAnOrphanedTokenWhenNothingMatches() {
    XCTAssertEqual(QuickEntry.reconciledListToken("#Courses", against: ["Travail"]), "#Courses")
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

  // MARK: Heure

  func testTimeTokenFormats() {
    XCTAssertEqual(parse("@14h30 Faire à manger").minutes, 14 * 60 + 30)
    XCTAssertEqual(parse("@14:30 Faire à manger").minutes, 14 * 60 + 30)
    XCTAssertEqual(parse("@14h Faire à manger").minutes, 14 * 60)
    XCTAssertEqual(parse("@9h05 Faire à manger").minutes, 9 * 60 + 5)
    XCTAssertEqual(parse("@0h Faire à manger").minutes, 0)
    XCTAssertEqual(parse("@14h30 Faire à manger").title, "Faire à manger")
  }

  /// L'heure est un SECOND jeton, indépendant du jour : l'ordre ne compte pas.
  func testDayAndTimeInEitherOrder() {
    for raw in ["@demain @14h30 Dentiste", "@14h30 @demain Dentiste"] {
      let entry = parse(raw)
      XCTAssertEqual(entry.title, "Dentiste", raw)
      XCTAssertEqual(day(entry), DateComponents(year: 2026, month: 7, day: 28), raw)
      XCTAssertEqual(entry.minutes, 14 * 60 + 30, raw)
    }
  }

  /// Un séparateur est exigé, et les bornes sont vraies : le reste redevient du texte.
  func testRejectedTimesStayInTheTitle() {
    for raw in ["@14", "@25h", "@14h60", "@h30", "@14h305", "@2pm"] {
      let entry = parse("\(raw) Faire à manger")
      XCTAssertNil(entry.minutes, raw)
      XCTAssertEqual(entry.title, "\(raw) Faire à manger", raw)
    }
  }

  /// Une heure seule n'a pas de jour : c'est l'appelant qui le complète, par aujourd'hui.
  func testTimeAloneImpliesToday() {
    let entry = parse("@14h30 Faire à manger")
    XCTAssertNil(entry.when)
    let filled = QuickEntry.day(entry.when, minutes: entry.minutes, now: now)
    XCTAssertEqual(
      filled.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) },
      DateComponents(year: 2026, month: 7, day: 27))
  }

  /// Complété APRÈS le jeton de date : « @14h @demain » garde demain.
  func testDayWinsOverTheImpliedToday() {
    let entry = parse("@14h @demain Dentiste")
    XCTAssertEqual(
      QuickEntry.day(entry.when, minutes: entry.minutes, now: now), entry.when)
  }

  func testSpaceValidatesATimeToken() {
    let result = consume("@14h30 ")
    XCTAssertEqual(result?.text, "")
    XCTAssertEqual(result?.entry.minutes, 14 * 60 + 30)
  }
}
