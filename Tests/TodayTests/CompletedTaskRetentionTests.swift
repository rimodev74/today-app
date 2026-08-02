import XCTest

@testable import Today

/// La règle qui décide qu'une tâche cochée quitte le flux. Elle était écrite DEUX fois — une dans
/// `TaskListView`, une sur `TaskItem` — et les deux divergeaient sur un cas. Elle ne vit plus qu'ici,
/// et ces tests tiennent la différence qui justifiait le doublon : avec ou sans `pageOpenedAt`.
final class CompletedTaskRetentionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)
  private var justNow: Date { now.addingTimeInterval(-0.2) }
  private var longAgo: Date { now.addingTimeInterval(-60) }

  // MARK: never — rien ne quitte jamais

  func testNever_neLaisseRienPartir() {
    for opened in [nil, now] as [Date?] {
      XCTAssertFalse(
        CompletedTaskRetention.never.hasLeftTheFlow(
          completedAt: longAgo, now: now, pageOpenedAt: opened))
    }
  }

  // MARK: timer — le seuil, quoi qu'il arrive

  func testTimer_partApresLeDelaiEtPasAvant() {
    XCTAssertFalse(
      CompletedTaskRetention.timer.hasLeftTheFlow(
        completedAt: justNow, now: now, pageOpenedAt: nil))
    XCTAssertTrue(
      CompletedTaskRetention.timer.hasLeftTheFlow(
        completedAt: longAgo, now: now, pageOpenedAt: nil))
  }

  /// Le mode minuté ignore `pageOpenedAt` : son seuil est le temps, pas la page.
  func testTimer_ignoreLOuvertureDeLaPage() {
    XCTAssertTrue(
      CompletedTaskRetention.timer.hasLeftTheFlow(
        completedAt: longAgo, now: now, pageOpenedAt: now.addingTimeInterval(-3600)))
  }

  // MARK: untilViewChange — LE cas qui justifiait deux implémentations

  /// Avec une page : ce qui a été coché AVANT son ouverture est parti, ce qui l'a été depuis reste
  /// sous les yeux — même vieux de plusieurs minutes.
  func testUntilViewChange_avecPage_compareALOuverture() {
    let opened = now.addingTimeInterval(-10)
    XCTAssertTrue(
      CompletedTaskRetention.untilViewChange.hasLeftTheFlow(
        completedAt: now.addingTimeInterval(-30), now: now, pageOpenedAt: opened))
    XCTAssertFalse(
      CompletedTaskRetention.untilViewChange.hasLeftTheFlow(
        completedAt: now.addingTimeInterval(-5), now: now, pageOpenedAt: opened))
  }

  /// Sans page (sidebar, anneaux) : on retombe sur le seuil minuté. C'est l'approximation assumée —
  /// la tenir ici évite qu'elle reparte en douce dans une seconde implémentation.
  func testUntilViewChange_sansPage_retombeSurLeSeuilMinute() {
    XCTAssertFalse(
      CompletedTaskRetention.untilViewChange.hasLeftTheFlow(
        completedAt: justNow, now: now, pageOpenedAt: nil))
    XCTAssertTrue(
      CompletedTaskRetention.untilViewChange.hasLeftTheFlow(
        completedAt: longAgo, now: now, pageOpenedAt: nil))
  }

  // MARK: les gardes portées par la tâche

  func testUneEnTeteNeQuitteJamaisLeFlux() {
    let header = TaskItem(title: "Section", isHeader: true)
    header.isCompleted = true
    header.completedAt = longAgo
    XCTAssertFalse(header.hasLeftTheFlow(.timer, now: now))
  }

  func testUneTacheAFaireNaRienQuitte() {
    XCTAssertFalse(TaskItem(title: "t").hasLeftTheFlow(.timer, now: now))
  }

  /// Cochée sans `completedAt` (état qu'aucun chemin de l'app ne produit, mais qu'une base ancienne
  /// pourrait porter) : on ne la fait pas disparaître faute de date.
  func testCocheeSansDateResteDansLeFlux() {
    let task = TaskItem(title: "t")
    task.isCompleted = true
    XCTAssertFalse(task.hasLeftTheFlow(.timer, now: now))
  }
}
