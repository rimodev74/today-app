import XCTest

@testable import Today

/// La règle qui décide qu'une tâche cochée quitte le flux. Elle était écrite DEUX fois — une dans
/// `TaskListView`, une sur `TaskItem` — et les deux divergeaient sur un cas. Elle ne vit plus qu'ici,
/// et ne dépend plus que de deux dates : la coche et l'instant présent.
final class CompletedTaskRetentionTests: XCTestCase {
  /// Un midi, pour que « le début du jour » ne tombe ni sur l'une ni sur l'autre des bornes testées.
  private let now = Calendar.current.date(
    bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_000_000))!
  private var justNow: Date { now.addingTimeInterval(-0.2) }
  private var longAgo: Date { now.addingTimeInterval(-60) }

  // MARK: never — rien ne quitte jamais

  func testNever_neLaisseRienPartir() {
    XCTAssertFalse(
      CompletedTaskRetention.never.hasLeftTheFlow(
        completedAt: now.addingTimeInterval(-86_400 * 7), now: now))
  }

  // MARK: timer — le seuil, quoi qu'il arrive

  func testTimer_partApresLeDelaiEtPasAvant() {
    XCTAssertFalse(CompletedTaskRetention.timer.hasLeftTheFlow(completedAt: justNow, now: now))
    XCTAssertTrue(CompletedTaskRetention.timer.hasLeftTheFlow(completedAt: longAgo, now: now))
  }

  // MARK: untilNextDay — le calendrier, pas la navigation

  /// Tout ce qui a été coché AUJOURD'HUI reste sous les yeux, même à l'aube et même vieux de
  /// plusieurs heures : c'est ce qui distingue ce mode de l'ancien, qui vidait la page dès qu'on en
  /// changeait.
  func testUntilNextDay_cocheeAujourdhui_reste() {
    let startOfDay = Calendar.current.startOfDay(for: now)
    XCTAssertFalse(
      CompletedTaskRetention.untilNextDay.hasLeftTheFlow(completedAt: justNow, now: now))
    XCTAssertFalse(
      CompletedTaskRetention.untilNextDay.hasLeftTheFlow(completedAt: startOfDay, now: now))
  }

  /// Une seconde avant minuit suffit : la borne est le début du jour, pas 24 h glissantes.
  func testUntilNextDay_cocheeHier_estPartie() {
    let startOfDay = Calendar.current.startOfDay(for: now)
    XCTAssertTrue(
      CompletedTaskRetention.untilNextDay.hasLeftTheFlow(
        completedAt: startOfDay.addingTimeInterval(-1), now: now))
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
