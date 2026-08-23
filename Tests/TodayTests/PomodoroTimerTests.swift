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

  /// L'écran plein est le point de passage : il arrête le minuteur MÊME avec l'enchaînement
  /// automatique, sinon son bouton « Commencer la pause » n'aurait plus rien à ouvrir.
  func testFullScreenAlertSuspendsAutoStartAfterWork() {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: PomodoroTimer.autoStartStorageKey)
    defaults.set(PomodoroAlertStyle.fullScreen.rawValue, forKey: PomodoroAlertStyle.storageKey)

    let timer = PomodoroTimer()
    timer.phase = .work
    timer.isRunning = true
    timer.handlePhaseCompletion()
    XCTAssertFalse(timer.isRunning, "le plein écran suspend l'enchaînement après un travail")

    // Fin de PAUSE : personne à interrompre, l'enchaînement reprend ses droits.
    timer.isRunning = true
    timer.phase = .shortBreak
    timer.handlePhaseCompletion()
    XCTAssertTrue(timer.isRunning, "une fin de pause n'ouvre pas d'écran plein")

    // Pastille : purement décorative, elle ne touche pas au minuteur.
    defaults.set(PomodoroAlertStyle.badge.rawValue, forKey: PomodoroAlertStyle.storageKey)
    timer.isRunning = true
    timer.phase = .work
    timer.handlePhaseCompletion()
    XCTAssertTrue(timer.isRunning, "la pastille laisse l'enchaînement automatique intact")

    defaults.removeObject(forKey: PomodoroTimer.autoStartStorageKey)
    defaults.removeObject(forKey: PomodoroAlertStyle.storageKey)
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

  /// La même contrainte de largeur DANS l'état pause : c'est un second format, avec son glyphe.
  /// Elle change de largeur entre marche et pause, et c'est voulu — ça n'arrive qu'à ce moment-là,
  /// pas à chaque seconde.
  func testMenuBarTimerImage_pausedWidthIsAlsoStable() {
    let timer = PomodoroTimer()
    let widths = Set(
      stride(from: 0, through: timer.workMinutes * 60 + 59, by: 37).map { total in
        timer.remaining = TimeInterval(total)
        return MenuBarTimerImage.make(timer.formattedRemaining, paused: true).size.width
      }
    )

    XCTAssertEqual(
      widths.count, 1,
      "toutes les images ⏸ MM:SS doivent avoir la même largeur, trouvé : \(widths.sorted())")
  }

  /// Les deux pauses doivent sonner PAREIL, et le travail autrement — c'est la demande, et c'est la
  /// seule chose vérifiable d'un son sans l'écouter.
  func testBothBreaksShareTheSameSound() {
    XCTAssertEqual(PomodoroSound.starting(.shortBreak), PomodoroSound.starting(.longBreak))
    XCTAssertEqual(PomodoroSound.starting(.work), .start)
    XCTAssertNotEqual(PomodoroSound.starting(.work), PomodoroSound.starting(.shortBreak))
    // Trois sons distincts : deux qui se ressemblent rendraient les trois états indiscernables.
    XCTAssertEqual(Set([PomodoroSound.start, .pause, .rest]).count, 3)
  }

  /// Les sons sont des sons SYSTÈME : un nom qui ne correspond à rien ne lève pas, il ne joue rien.
  /// Le test attrape la faute de frappe que le compilateur laisse passer.
  func testEverySoundExistsOnThisSystem() {
    for sound in [PomodoroSound.start, .pause, .rest] {
      XCTAssertNotNil(
        NSSound(named: sound.defaultSoundName),
        "son système introuvable : \(sound.defaultSoundName)")
    }
  }

  /// Ce que la barre de menus lit pour décider d'afficher l'heure ou son icône. La PAUSE ne remet
  /// pas au repos — c'est tout l'objet de cette propriété, et le défaut qu'elle corrige.
  func testHasStartedSurvivesPauseAndFallsOnlyOnReset() {
    let timer = PomodoroTimer()
    XCTAssertFalse(timer.hasStarted, "un minuteur jamais lancé est au repos")

    timer.start()
    XCTAssertTrue(timer.hasStarted)

    timer.pause()
    XCTAssertTrue(timer.hasStarted, "en pause, la session reste engagée")
    XCTAssertFalse(timer.isRunning)

    // Une phase qui s'achève sans enchaînement automatique laisse elle aussi le temps affiché.
    timer.handlePhaseCompletion()
    XCTAssertTrue(timer.hasStarted)

    timer.reset()
    XCTAssertFalse(timer.hasStarted, "seule la remise à zéro rend la barre à son icône")
  }
}
