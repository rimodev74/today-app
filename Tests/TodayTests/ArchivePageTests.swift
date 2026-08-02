import XCTest

@testable import Today

/// Ce que la page « Archives » présente. Ce calcul se refaisait à chaque lecture d'une propriété
/// calculée de la vue, six fois par rendu, et ne se vérifiait qu'en cliquant.
final class ArchivePageTests: XCTestCase {
  private let calendar = Calendar(identifier: .gregorian)
  /// 2 août 2026 — l'année « courante » des étiquettes de mois.
  private let now = date(2026, 8, 2)

  private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var components = DateComponents()
    (components.year, components.month, components.day, components.hour) = (y, m, d, 9)
    return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
  }
  private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { Self.date(y, m, d) }

  private func done(_ title: String, at completedAt: Date) -> TaskItem {
    let task = TaskItem(title: title)
    task.isCompleted = true
    task.completedAt = completedAt
    return task
  }

  private func page(_ tasks: [TaskItem]) -> ArchivePage {
    ArchivePage(tasks: tasks, now: now, calendar: calendar)
  }

  // MARK: Le périmètre

  func testSeulesLesTachesCocheesEntrent() {
    let page = page([done("faite", at: date(2026, 7, 10)), TaskItem(title: "à faire")])
    XCTAssertEqual(page.tasks.map(\.title), ["faite"])
  }

  /// Une en-tête ne se coche pas ; si une base en portait une cochée, elle n'est pas une archive.
  func testUneEnTeteNestJamaisUneArchive() {
    let header = TaskItem(title: "Section", isHeader: true)
    header.isCompleted = true
    header.completedAt = date(2026, 7, 10)
    XCTAssertTrue(page([header]).isEmpty)
  }

  func testPageVide() {
    XCTAssertTrue(page([]).isEmpty)
    XCTAssertTrue(page([]).months.isEmpty)
    XCTAssertTrue(page([]).blocks.isEmpty)
  }

  // MARK: L'ordre

  /// La plus récemment cochée en tête — c'est ce que la page annonce.
  func testLaPlusRecenteEnTete() {
    let page = page([
      done("vieille", at: date(2026, 5, 3)),
      done("récente", at: date(2026, 7, 28)),
      done("moyenne", at: date(2026, 6, 15)),
    ])
    XCTAssertEqual(page.tasks.map(\.title), ["récente", "moyenne", "vieille"])
  }

  func testUnMoisParGroupeDuPlusRecentAuPlusAncien() {
    let page = page([
      done("mai", at: date(2026, 5, 3)),
      done("juillet a", at: date(2026, 7, 28)),
      done("juillet b", at: date(2026, 7, 2)),
    ])
    XCTAssertEqual(page.months.map(\.label), ["Juillet", "Mai"])
    XCTAssertEqual(page.months.first?.tasks.map(\.title), ["juillet a", "juillet b"])
  }

  // MARK: L'étiquette de mois

  /// L'année n'apparaît que quand elle apporte quelque chose.
  func testLAnneeNapparaitQueSiElleDiffere() {
    let page = page([
      done("cette année", at: date(2026, 7, 1)), done("l'an passé", at: date(2025, 7, 1)),
    ])
    XCTAssertEqual(page.months.map(\.label), ["Juillet", "Juillet 2025"])
  }

  // MARK: Les pans du socle clavier

  /// Un pan par mois, dans l'ordre affiché : c'est ce que ↑/↓ parcourt et ce que ⌫ vise.
  func testBlocksSuiventLordreAffiche() {
    let page = page([done("mai", at: date(2026, 5, 3)), done("juillet", at: date(2026, 7, 28))])
    XCTAssertEqual(page.blocks.count, 2)
    XCTAssertEqual(page.blocks.flatMap(\.tasks).map(\.title), ["juillet", "mai"])
  }

  // MARK: Le regroupement partagé avec le dépliant d'une page de liste

  /// `ArchiveMonth.group` prend des tâches DÉJÀ choisies : il ne refiltre pas. C'est ce qui permet
  /// au dépliant d'une liste de l'utiliser avec son propre périmètre sans réécrire le groupement.
  func testGroupNeRefiltrePas() {
    let months = ArchiveMonth.group(
      [done("faite", at: date(2026, 7, 10)), TaskItem(title: "à faire")],
      now: now, calendar: calendar)
    XCTAssertEqual(months.flatMap(\.tasks).count, 2)
  }

  /// Une tâche cochée sans date de complétion ne fait pas planter le groupement — elle atterrit
  /// dans un mois lointain plutôt que de casser le tri.
  func testUneArchiveSansDateNeCassePasLeGroupement() {
    let orphan = TaskItem(title: "sans date")
    orphan.isCompleted = true
    let page = page([orphan, done("datée", at: date(2026, 7, 10))])
    XCTAssertEqual(page.tasks.count, 2)
    XCTAssertEqual(page.months.count, 2)
  }
}
