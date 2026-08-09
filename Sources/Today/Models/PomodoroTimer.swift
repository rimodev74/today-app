import AppKit
import Foundation
import Observation

enum PomodoroPhase: Equatable {
  case work
  case shortBreak
  case longBreak

  var label: String {
    switch self {
    case .work: return "Travail"
    case .shortBreak: return "Pause courte"
    case .longBreak: return "Pause longue"
    }
  }
}

/// Les retours sonores des GESTES du minuteur — distincts de l'alarme de fin de phase, qui, elle,
/// se règle (cf. `PomodoroTimer.alertSoundStorageKey`). Ils vivent dans le minuteur et pas dans les
/// commandes clavier : les boutons de la page Pomodoro et le menu de la barre passent par les mêmes
/// méthodes, et un son posé sur les seules commandes les aurait laissés muets.
///
/// Des sons SYSTÈME (`/System/Library/Sounds`) : ils suivent déjà le volume d'alerte réglé par
/// l'utilisateur et ne demandent aucun fichier à embarquer, à signer, ni à faire vivre.
enum PomodoroSound: String {
  case start = "Pop"
  /// `Purr` et pas `Tink` : un arrêt se dit par un son qui DESCEND, là où le clic sec de `Tink`
  /// s'entendait comme un second départ — deux sons secs de suite ne se distinguent qu'en y pensant.
  case pause = "Purr"
  /// Les deux pauses partagent le même son : pour l'oreille, c'est le MÊME événement — le travail
  /// s'arrête. Leur durée se lit à l'écran, pas au bruit.
  case rest = "Submarine"

  /// Le son d'une phase qu'on OUVRE. La règle tient en une ligne, et c'est elle qui garantit que
  /// pause courte et pause longue ne divergeront pas le jour où l'une des deux gagne un chemin.
  static func starting(_ phase: PomodoroPhase) -> PomodoroSound {
    switch phase {
    case .work: return .start
    case .shortBreak, .longBreak: return .rest
    }
  }

  /// `swift test` lance et arrête le minuteur des dizaines de fois : 237 tests qui font « pop »
  /// n'apprennent rien à personne et couvrent la seule chose qu'on écoute, la sortie du test.
  private static let isTesting = NSClassFromString("XCTestCase") != nil

  func play() {
    guard !Self.isTesting else { return }
    NSSound(named: rawValue)?.play()
  }
}

@Observable
/// Isolé au fil principal : le `Timer` est ajouté à `RunLoop.main` (cf. `start`), donc `tick()` n'a
/// jamais lieu ailleurs, et l'objet est lu par des vues SwiftUI. L'annotation écrit cette réalité.
@MainActor
final class PomodoroTimer {
  /// L'unique minuteur de l'app. Un singleton parce qu'il est atteint de DEUX côtés : l'arbre de
  /// vues (par l'environnement, cf. `TodayApp`) et les raccourcis clavier globaux, qui partent d'un
  /// gestionnaire Carbon sans aucun accès à cet arbre (cf. `AppCommand`).
  static let shared = PomodoroTimer()

  static let sessionsBeforeLongBreak = 4

  private static let workMinutesKey = "pomodoroWorkMinutes"
  private static let shortBreakMinutesKey = "pomodoroShortBreakMinutes"
  private static let longBreakMinutesKey = "pomodoroLongBreakMinutes"
  static let autoStartStorageKey = "pomodoroAutoStartNextPhase"
  static let alertSoundStorageKey = "pomodoroAlertSoundName"
  static let defaultAlertSound = "Glass"
  // Sons système macOS (~/System/Library/Sounds), les mêmes que Réglages Système > Son.
  static let availableSounds = [
    "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
    "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
  ]

  var phase: PomodoroPhase = .work
  var remaining: TimeInterval
  var isRunning = false
  private(set) var completedWorkSessions = 0

  /// Une session ENGAGÉE : lancée au moins une fois et pas encore remise à zéro. En pause, elle
  /// l'est toujours — c'est ce qui la distingue du repos, et `isRunning` ne sait pas le dire.
  /// La barre de menus s'en sert pour garder le temps affiché pendant une pause : sans ça, mettre
  /// en pause faisait DISPARAÎTRE le compte à rebours, ce qui se lit comme « c'est fini ».
  private(set) var hasStarted = false

  var workMinutes: Int {
    didSet { UserDefaults.standard.set(workMinutes, forKey: Self.workMinutesKey) }
  }
  var shortBreakMinutes: Int {
    didSet { UserDefaults.standard.set(shortBreakMinutes, forKey: Self.shortBreakMinutesKey) }
  }
  var longBreakMinutes: Int {
    didSet { UserDefaults.standard.set(longBreakMinutes, forKey: Self.longBreakMinutesKey) }
  }

  var formattedRemaining: String {
    let total = max(0, Int(remaining))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  @ObservationIgnored private var timer: Timer?

  init() {
    let defaults = UserDefaults.standard
    let work = defaults.object(forKey: Self.workMinutesKey) as? Int ?? 25
    workMinutes = work
    shortBreakMinutes = defaults.object(forKey: Self.shortBreakMinutesKey) as? Int ?? 5
    longBreakMinutes = defaults.object(forKey: Self.longBreakMinutesKey) as? Int ?? 15
    remaining = TimeInterval(work * 60)
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    hasStarted = true
    // Le son suit la PHASE lancée, pas le geste : « démarrer une pause courte » et « démarrer une
    // pause longue » passent tous deux par ici et sonnent donc pareil, ce qui est demandé.
    PomodoroSound.starting(phase).play()
    let newTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      // Le timer est ajouté à `RunLoop.main` juste en dessous : ce bloc ne part JAMAIS d'ailleurs
      // que du fil principal. `Timer` ne sait pas l'exprimer dans son type (sa fermeture est
      // `@Sendable`), on l'affirme donc ici, à l'endroit exact où l'invariant est établi.
      MainActor.assumeIsolated { self?.tick() }
    }
    // .common (pas .default) : continue de tick pendant le tracking du menu (menu bar ouvert, resize, etc.)
    RunLoop.main.add(newTimer, forMode: .common)
    timer = newTimer
    syncMusic()
  }

  /// La musique suit une règle UNIQUE — elle joue si et seulement si un travail est en cours — et
  /// les trois chemins qui touchent à l'un des deux termes passent tous par ici. Décidée au coup par
  /// coup dans `start`, `halt` et `advancePhase`, elle aurait divergé au premier chemin ajouté :
  /// c'est le même raisonnement que `PomodoroSound.starting(_:)`, un cran plus haut.
  private func syncMusic() {
    if isRunning, phase == .work {
      MusicPlayer.shared.play()
    } else {
      MusicPlayer.shared.stop()
    }
  }

  /// Le GESTE « mettre en pause » : il sonne. Muet si rien ne tournait — sans cette garde, une
  /// combinaison frappée deux fois sonnait deux fois pour un seul arrêt.
  func pause() {
    guard isRunning else { return }
    halt()
    PomodoroSound.pause.play()
  }

  /// L'arrêt MÉCANIQUE, sans un bruit. Séparé du geste parce que trois chemins arrêtent le minuteur
  /// sans que l'utilisateur ait demandé une pause : la remise à zéro, l'ouverture d'une autre phase,
  /// et la fin d'une phase — cette dernière a déjà son alarme, un « clic » de pause juste derrière
  /// s'entendait comme un bug.
  private func halt() {
    isRunning = false
    timer?.invalidate()
    timer = nil
    syncMusic()
  }

  func reset() {
    halt()
    phase = .work
    completedWorkSessions = 0
    remaining = duration(for: .work)
    hasStarted = false  // retour au repos : la barre de menus reprend son icône
    // Une session neuve reprend sa playlist au début. C'est ici et nulle part ailleurs : les pauses
    // d'une même session doivent la retrouver là où le fondu l'avait laissée.
    MusicPlayer.shared.rewindPlaylist()
  }

  /// Bascule sur une phase et la lance depuis sa durée PLEINE. C'est ce que veut dire « démarrer une
  /// pause courte » : pas reprendre un compte à rebours entamé, mais en ouvrir un neuf.
  func begin(_ phase: PomodoroPhase) {
    halt()  // silencieux : c'est le `start()` qui suit qui annonce la phase ouverte
    self.phase = phase
    remaining = duration(for: phase)
    start()
  }

  /// « Lancer un pomodoro » : reprendre le travail en cours s'il y en a un, en ouvrir un sinon.
  /// Sans cette distinction, la commande jetterait les 18 minutes déjà faites de celui qu'on venait
  /// de mettre en pause — c'est le seul cas où relancer et recommencer ne sont pas la même chose.
  func startWork() {
    if phase == .work {
      start()
    } else {
      begin(.work)
    }
  }

  func advancePhase() {
    switch phase {
    case .work:
      completedWorkSessions += 1
      phase =
        completedWorkSessions.isMultiple(of: Self.sessionsBeforeLongBreak)
        ? .longBreak : .shortBreak
    case .shortBreak, .longBreak:
      phase = .work
    }
    remaining = duration(for: phase)
    syncMusic()
  }

  private func tick() {
    guard remaining > 0 else { return }
    remaining -= 1
    // Le fondu s'amorce UNE fois par phase, à la seconde exacte : `remaining` décroît de 1 en 1
    // depuis un entier, l'égalité est donc atteinte pile une fois. Un `<=` la rejouerait à chaque
    // tick, et chaque relance repartirait du volume plein — la musique remonterait en escalier.
    if phase == .work, Int(remaining) == MusicPlayer.shared.fadeSeconds {
      MusicPlayer.shared.fadeOut()
    }
    if remaining <= 0 {
      handlePhaseCompletion()
    }
  }

  // Sépare de `tick()` pour être testable sans attendre un vrai `Timer`.
  func handlePhaseCompletion() {
    // La musique se tait AVANT l'alarme. Le fondu l'a normalement déjà fait ; pas quand la phase est
    // plus courte que le fondu, ni quand la musique vient d'être activée en cours de phase.
    MusicPlayer.shared.stop()
    let soundName =
      UserDefaults.standard.string(forKey: Self.alertSoundStorageKey) ?? Self.defaultAlertSound
    NSSound(named: soundName)?.play()
    // `advancePhase` resynchronise la musique : avec l'enchaînement automatique, le minuteur tourne
    // toujours et personne n'appellera `start()` — c'est donc là que le travail retrouve sa musique.
    advancePhase()
    if !UserDefaults.standard.bool(forKey: Self.autoStartStorageKey) {
      halt()  // l'alarme vient de sonner : elle EST le signal, rien à ajouter derrière
    }
  }

  private func duration(for phase: PomodoroPhase) -> TimeInterval {
    switch phase {
    case .work: return TimeInterval(workMinutes * 60)
    case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
    case .longBreak: return TimeInterval(longBreakMinutes * 60)
    }
  }
}
