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

  /// La barre de menus ne change qu'une fois par minute, sauf pendant la dernière.
  func testMenuBarText_minutesRoundedUpThenSecondsInLastMinute() {
    XCTAssertEqual(PomodoroTimer.menuBarText(25 * 60), "25 min")
    XCTAssertEqual(PomodoroTimer.menuBarText(24 * 60 + 1), "25 min")
    XCTAssertEqual(PomodoroTimer.menuBarText(24 * 60), "24 min")
    XCTAssertEqual(PomodoroTimer.menuBarText(60), "1 min")
    XCTAssertEqual(PomodoroTimer.menuBarText(59), "00:59")
    XCTAssertEqual(PomodoroTimer.menuBarText(-3), "00:00")
  }

  /// Le `didSet` d'un `@Observable` tient bien le texte stocké à jour.
  func testMenuBarText_suitRemaining() {
    let timer = PomodoroTimer()
    timer.remaining = 59
    XCTAssertEqual(timer.menuBarText, "00:59")
    timer.remaining = 600
    XCTAssertEqual(timer.menuBarText, "10 min")
  }

  // MARK: Pas de dérive — le reste vient de l'horloge, pas du nombre de ticks

  /// Un minuteur dont l'horloge est celle du test : `elapsed` avance à la main.
  private func timerWithClock(_ clock: FakeClock, seconds: TimeInterval = 25 * 60)
    -> PomodoroTimer
  {
    let timer = PomodoroTimer()
    timer.remaining = seconds  // pas `workMinutes` : il s'écrit dans les défauts
    timer.now = { clock.date }
    return timer
  }

  private final class FakeClock {
    var date = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
  }

  func testSecondsLeft_roundsUpToWholeSeconds() {
    let end = Date(timeIntervalSinceReferenceDate: 100)
    XCTAssertEqual(PomodoroTimer.secondsLeft(until: end, at: end.addingTimeInterval(-59.2)), 60)
    XCTAssertEqual(PomodoroTimer.secondsLeft(until: end, at: end.addingTimeInterval(-1)), 1)
    XCTAssertEqual(PomodoroTimer.secondsLeft(until: end, at: end), 0)
    XCTAssertEqual(PomodoroTimer.secondsLeft(until: end, at: end.addingTimeInterval(7)), 0)
  }

  /// Le défaut : dix minutes passent sans qu'un seul tick ne parte (veille, App Nap, fil occupé),
  /// puis UN tick arrive. L'ancien `remaining -= 1` en aurait retiré une seconde.
  func testTick_afterSkippedTicksReadsTheClock() {
    let clock = FakeClock()
    let timer = timerWithClock(clock)
    timer.start()
    defer { timer.reset() }

    clock.advance(600.3)
    timer.tick()
    XCTAssertEqual(timer.remaining, 25 * 60 - 600, "reste = fin − maintenant, arrondi au-dessus")
  }

  /// Un tick ordinaire, une seconde après le départ, fait lire 24:59 comme avant.
  func testTick_oneSecondAfterStartReadsOneSecondLess() {
    let clock = FakeClock()
    let timer = timerWithClock(clock)
    timer.start()
    defer { timer.reset() }

    clock.advance(1.004)  // un tick part toujours un poil APRÈS sa seconde
    timer.tick()
    XCTAssertEqual(timer.remaining, 25 * 60 - 1)
    XCTAssertEqual(timer.formattedRemaining, "24:59")
  }

  /// La pause fige le reste ; reprendre repart de ce reste, quel que soit le temps passé en pause.
  func testPauseFreezesRemainingAndResumeContinuesFromIt() {
    let clock = FakeClock()
    let timer = timerWithClock(clock)
    timer.start()
    clock.advance(300)
    timer.pause()
    XCTAssertEqual(timer.remaining, 20 * 60)

    clock.advance(3_600)  // une heure de pause
    timer.tick()  // un tick tardif sur un minuteur en pause ne doit rien changer
    XCTAssertEqual(timer.remaining, 20 * 60)

    timer.start()
    clock.advance(60.001)
    timer.tick()
    XCTAssertEqual(timer.remaining, 19 * 60, "repart du reste figé, pas de l'heure de pause")
    timer.reset()
  }

  /// Un tick sauté PAR-DESSUS la fin termine quand même la phase (`<=`, pas `==`).
  func testTick_skippedPastTheEndStillCompletesThePhase() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: PomodoroTimer.autoStartStorageKey)
    defaults.removeObject(forKey: PomodoroAlertStyle.storageKey)

    let clock = FakeClock()
    let timer = timerWithClock(clock, seconds: 60)
    timer.start()
    clock.advance(75)  // 15 s APRÈS la fin, aucun tick entre-temps
    timer.tick()
    XCTAssertEqual(timer.phase, .shortBreak)
    XCTAssertFalse(timer.isRunning, "sans enchaînement automatique, la phase suivante attend")
    XCTAssertEqual(timer.remaining, TimeInterval(timer.shortBreakMinutes * 60))
    timer.reset()
  }

  /// Enchaînement automatique : la phase neuve repart de sa durée PLEINE depuis maintenant, elle
  /// n'hérite pas du retard de la précédente.
  func testAutoStartedPhaseCountsFromItsOwnStart() {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: PomodoroTimer.autoStartStorageKey)
    defaults.removeObject(forKey: PomodoroAlertStyle.storageKey)
    defer { defaults.removeObject(forKey: PomodoroTimer.autoStartStorageKey) }

    let clock = FakeClock()
    let timer = timerWithClock(clock, seconds: 60)
    timer.start()
    clock.advance(75)
    timer.tick()
    XCTAssertEqual(timer.phase, .shortBreak)
    XCTAssertTrue(timer.isRunning)

    clock.advance(30.001)
    timer.tick()
    XCTAssertEqual(timer.remaining, TimeInterval(timer.shortBreakMinutes * 60 - 30))
    timer.reset()
  }
}
