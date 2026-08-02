import XCTest

@testable import Today

/// Ce que la page « À venir » présente. Ce calcul vivait dans le `body` de la vue : il ne se
/// vérifiait qu'en cliquant, un jour donné, et portait trois force-unwraps. La date est ici
/// FIXÉE — sans ça, « les 7 prochains jours » et « le bandeau du mois » se testeraient
/// différemment selon le jour où l'on lance la suite.
final class UpcomingPageTests: XCTestCase {
  /// Mercredi 5 août 2026, midi. Août a 31 jours : la fenêtre proche (6→12 août) laisse un
  /// bandeau « 13-31 » pour le reste du mois.
  private let now = date(2026, 8, 5, hour: 12)
  private var calendar: Calendar { Calendar(identifier: .gregorian) }

  private static func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
    var components = DateComponents()
    (components.year, components.month, components.day, components.hour) = (y, m, d, hour)
    return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
  }
  private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
    Self.date(y, m, d, hour: hour)
  }

  private func task(_ title: String, on day: Date?) -> TaskItem {
    TaskItem(title: title, when: day)
  }

  private func page(_ tasks: [TaskItem]) -> UpcomingPage {
    UpcomingPage(tasks: tasks, now: now, calendar: calendar)
  }

  // MARK: La fenêtre proche

  /// Sept jours, toujours — même sans rien dedans. C'est le point de la fenêtre proche : on doit
  /// VOIR le trou, pas juste l'absence de ligne.
  func testFenetreProche_toujoursSeptJoursMemeVides() {
    let days = page([]).nearDays
    XCTAssertEqual(days.count, 7)
    XCTAssertTrue(days.allSatisfy { $0.items.isEmpty })
    XCTAssertEqual(days.first?.date, date(2026, 8, 6, hour: 0))
    XCTAssertEqual(days.last?.date, date(2026, 8, 12, hour: 0))
  }

  /// Elle commence DEMAIN : « À venir » n'est pas « Aujourd'hui », une tâche du jour n'y est pas.
  func testFenetreProche_commenceDemainEtExclutAujourdhui() {
    let page = page([
      task("aujourd'hui", on: date(2026, 8, 5)), task("demain", on: date(2026, 8, 6)),
    ])
    XCTAssertEqual(page.nearDays.first?.tasks.map(\.title), ["demain"])
    XCTAssertEqual(page.nearDays.flatMap(\.tasks).map(\.title), ["demain"])
  }

  /// Une tâche en retard n'est nulle part : elle est retournée dans sa liste (cf. `SmartList`).
  func testUneTacheEnRetardNapparaitPas() {
    let page = page([task("hier", on: date(2026, 8, 4))])
    XCTAssertTrue(page.nearDays.allSatisfy(\.items.isEmpty))
    XCTAssertTrue(page.monthBands.isEmpty)
  }

  func testUneTacheSansDateNapparaitPas() {
    XCTAssertTrue(page([task("un jour", on: nil)]).nearDays.allSatisfy(\.items.isEmpty))
  }

  func testUneTacheCocheeNapparaitPas() {
    let done = task("fait", on: date(2026, 8, 8))
    done.isCompleted = true
    XCTAssertTrue(page([done]).nearDays.allSatisfy(\.items.isEmpty))
  }

  // MARK: Les bandeaux de mois

  /// Au-delà de la fenêtre proche, seuls les jours QUI PORTENT quelque chose deviennent une ligne.
  func testAuDelaDeLaFenetre_seulsLesJoursPleinsDeviennentUneLigne() {
    let page = page([task("plus tard", on: date(2026, 8, 20))])
    XCTAssertEqual(page.monthBands.count, 1)
    XCTAssertEqual(page.monthBands.first?.days.count, 1)
    XCTAssertEqual(page.monthBands.first?.days.first?.tasks.map(\.title), ["plus tard"])
  }

  /// Un bandeau par mois, dans l'ordre, et les jours d'un même mois regroupés sous le leur.
  func testUnBandeauParMoisDansLordre() {
    let page = page([
      task("septembre", on: date(2026, 9, 3)),
      task("août", on: date(2026, 8, 20)),
      task("octobre", on: date(2026, 10, 1)),
      task("août bis", on: date(2026, 8, 25)),
    ])
    XCTAssertEqual(page.monthBands.map(\.name), ["Août", "Septembre", "Octobre"])
    XCTAssertEqual(page.monthBands.first?.days.flatMap(\.tasks).map(\.title), ["août", "août bis"])
  }

  /// Le mois où finit la fenêtre proche démarre juste APRÈS elle (12 août → « 13-31 ») ; les mois
  /// suivants couvrent le mois entier.
  func testPlageDuBandeau_partialPuisMoisEntiers() {
    let page = page([
      task("août", on: date(2026, 8, 20)),
      task("septembre", on: date(2026, 9, 3)),
    ])
    XCTAssertEqual(page.monthBands.map(\.rangeLabel), ["13-31", "1-30"])
  }

  /// L'année n'apparaît que quand elle apporte quelque chose — même règle que `ArchiveMonth`.
  func testNomDuMois_lAnneeNapparaitQueSiElleDiffere() {
    XCTAssertEqual(
      UpcomingPage.monthName(date(2026, 12, 1), now: now, calendar: calendar), "Décembre")
    XCTAssertEqual(
      UpcomingPage.monthName(date(2027, 1, 1), now: now, calendar: calendar), "Janvier 2027")
  }

  /// Au-delà de l'horizon, rien : c'est le plafond de chargement EventKit, il doit aussi valoir
  /// pour les tâches, sans quoi la page afficherait des jours vides de tout contexte Apple.
  func testAuDelaDeLHorizon_rien() {
    let farAway =
      calendar.date(
        byAdding: .day, value: UpcomingPage.horizonDays + 30, to: now) ?? now
    XCTAssertTrue(page([task("très loin", on: farAway)]).monthBands.isEmpty)
  }

  // MARK: Les pans du socle clavier

  /// Un pan par jour, dans l'ordre du rendu : fenêtre proche d'abord, puis les jours des bandeaux.
  /// C'est ce que ↑/↓ et ⌫ parcourent — un ordre faux ici et « la touche ne marche pas ».
  func testTaskBlocks_suiventLordreDuRendu() {
    let page = page([
      task("distante", on: date(2026, 8, 20)),
      task("proche", on: date(2026, 8, 7)),
    ])
    XCTAssertEqual(page.taskBlocks.count, page.nearDays.count + 1)
    XCTAssertEqual(page.taskBlocks.flatMap(\.tasks).map(\.title), ["proche", "distante"])
  }
}
