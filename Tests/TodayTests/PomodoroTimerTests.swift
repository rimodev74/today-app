import XCTest

@testable import Today

/// `PomodoroTimer` est isolé au fil principal (son `Timer` vit sur `RunLoop.main`) : les tests
/// s'y placent aussi, plutôt que de contourner l'isolation qu'on vient de rendre vérifiable.
@MainActor
final class PomodoroTimerTests: XCTestCase {
  func testAdvancePhase_triggersLongBreakEveryFourthWorkSession() {
    let timer = PomodoroTimer()

    for _ in 0..<3 {
      timer.phase = .work
      timer.advancePhase()
      XCTAssertEqual(timer.phase, .shortBreak)
    }

    timer.phase = .work
    timer.advancePhase()
    XCTAssertEqual(
      timer.phase, .longBreak, "la 4e session de travail doit déclencher une pause longue")

    timer.advancePhase()
    XCTAssertEqual(timer.phase, .work, "une pause (courte ou longue) revient toujours au travail")
  }

  func testHandlePhaseCompletion_pausesUnlessAutoStartIsEnabled() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: PomodoroTimer.autoStartStorageKey)

    let timer = PomodoroTimer()
    timer.phase = .work
    timer.isRunning = true
    timer.handlePhaseCompletion()
    XCTAssertEqual(timer.phase, .shortBreak)
    XCTAssertFalse(
      timer.isRunning, "sans le réglage auto-start, la phase suivante doit rester en pause")

    defaults.set(true, forKey: PomodoroTimer.autoStartStorageKey)
    timer.isRunning = true
    timer.phase = .work
    timer.handlePhaseCompletion()
    XCTAssertTrue(
      timer.isRunning, "avec le réglage auto-start actif, la phase suivante démarre automatiquement"
    )

    defaults.removeObject(forKey: PomodoroTimer.autoStartStorageKey)
  }

  // Le label de la barre de menu ne doit jamais changer de largeur : sinon toute la barre
  // de menu se décale à chaque seconde (les status items sont alignés à droite).
  func testMenuBarTimerImage_widthIsIdenticalForEveryDigitCombination() {
    let timer = PomodoroTimer()
    let widths = Set(
      stride(from: 0, through: timer.workMinutes * 60 + 59, by: 37).map { total in
        timer.remaining = TimeInterval(total)
        return MenuBarTimerImage.make(timer.formattedRemaining).size.width
      }
    )

    XCTAssertEqual(
      widths.count, 1,
      "toutes les images MM:SS doivent avoir la même largeur, trouvé : \(widths.sorted())")
  }
}
