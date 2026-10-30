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
/// se règle par sa propre clé (cf. `PomodoroTimer.alertSoundStorageKey`). Ils vivent dans le
/// minuteur et pas dans les commandes clavier : les boutons de la page Pomodoro et le menu de la
/// barre passent par les mêmes méthodes, et un son posé sur les seules commandes les aurait laissés
/// muets.
///
/// Des sons SYSTÈME (`/System/Library/Sounds`) : ils suivent déjà le volume d'alerte réglé par
/// l'utilisateur et ne demandent aucun fichier à embarquer, à signer, ni à faire vivre. Réglables
/// individuellement (Réglages ▸ Pomodoro ▸ Sons, cf. `SoundPickerRow`) — `defaultSoundName` ne sert
/// que tant que l'utilisateur n'a rien choisi.
enum PomodoroSound: String {
  case start
  /// `Purr` et pas `Tink` : un arrêt se dit par un son qui DESCEND, là où le clic sec de `Tink`
  /// s'entendait comme un second départ — deux sons secs de suite ne se distinguent qu'en y pensant.
  case pause
  /// Les deux pauses partagent le même son PAR DÉFAUT : pour l'oreille, c'est le MÊME événement —
  /// le travail s'arrête. Leur durée se lit à l'écran, pas au bruit.
  case rest

  var defaultSoundName: String {
    switch self {
    case .start: return "Pop"
    case .pause: return "Purr"
    case .rest: return "Submarine"
    }
  }

  static let storageKeyPrefix = "pomodoroSound_"
  var storageKey: String { Self.storageKeyPrefix + rawValue }

  var soundName: String {
    UserDefaults.standard.string(forKey: storageKey) ?? defaultSoundName
  }

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
    NSSound(named: soundName)?.play()
  }
}

/// Ce que la fin d'une étape MONTRE — l'alarme sonore, elle, se règle à part
/// (`PomodoroTimer.alertSoundStorageKey`). Repris de Desk Minder : rien, une pastille en bas de
/// l'écran, ou un écran entier qu'il faut congédier.
enum PomodoroAlertStyle: String, CaseIterable, Identifiable {
  case none
  case badge
  case fullScreen

  static let storageKey = "pomodoroPhaseEndAlert"

  /// Le réglage vu du minuteur. `@AppStorage` n'existe que dans une vue — même clé, même défaut.
  /// `.none` par défaut : le son seul, comme avant ce réglage.
  static var current: PomodoroAlertStyle {
    UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .none
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .none: return "Rien"
    case .badge: return "Pastille"
    case .fullScreen: return "Plein écran"
    }
  }

  /// L'écran plein PREND LA MAIN : il suspend l'enchaînement automatique, et c'est son bouton qui
  /// ouvre la phase suivante — sinon ce bouton mentirait, la suite tournant déjà derrière lui.
  ///
  /// Seulement après un TRAVAIL : une fin de pause n'a personne à interrompre, elle se contente de
  /// la pastille. Lue des deux côtés — le minuteur pour s'arrêter, la fenêtre pour choisir quoi
  /// montrer — d'où une règle et pas deux conditions jumelles.
  func takesOver(after finished: PomodoroPhase) -> Bool {
    self == .fullScreen && finished == .work
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
  var remaining: TimeInterval {
    didSet {
      let text = Self.menuBarText(remaining)
      if text != menuBarText { menuBarText = text }
    }
  }
  /// Ce que la barre de menus affiche, STOCKÉ et réécrit seulement quand il change. Lire
  /// `remaining` depuis l'étiquette redessinait l'icône du `NSStatusItem` chaque seconde : un bloc
  /// de ~10 ms sur le fil principal toutes les secondes de la session, soit une image perdue par
  /// seconde pendant toute animation (mesuré le 29 octobre 2026). Les minutes suffisent à un coup
  /// d'œil ; les secondes ne reviennent que pendant la dernière minute.
  private(set) var menuBarText = ""
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
  /// L'instant où la phase en cours finit — la VÉRITÉ du temps restant, `remaining` n'en est que
  /// l'affichage. Décompter `remaining -= 1` à chaque tick faisait dériver le minuteur dès qu'un
  /// tick était retardé ou sauté (App Nap, fil principal occupé, veille) : chaque seconde perdue
  /// l'était pour de bon. `nil` tant que rien ne tourne.
  @ObservationIgnored private var endDate: Date?
  /// L'horloge, injectable : un test fait passer dix minutes sans les attendre.
  @ObservationIgnored var now: () -> Date = Date.init
  /// Tient App Nap à distance tant que le minuteur tourne. Sans elle, macOS regroupe et retarde les
  /// ticks d'une app qu'il juge inactive — pas de quoi fausser le temps (la date de fin suffit) mais
  /// assez pour figer le compte à rebours à l'écran.
  @ObservationIgnored private var activity: NSObjectProtocol?

  init() {
    let defaults = UserDefaults.standard
    let work = defaults.object(forKey: Self.workMinutesKey) as? Int ?? 25
    workMinutes = work
    shortBreakMinutes = defaults.object(forKey: Self.shortBreakMinutesKey) as? Int ?? 5
    longBreakMinutes = defaults.object(forKey: Self.longBreakMinutesKey) as? Int ?? 15
    remaining = TimeInterval(work * 60)
    menuBarText = Self.menuBarText(remaining)
  }

  /// Minutes ARRONDIES AU-DESSUS (« 25 min » pendant toute la première minute d'une session de 25),
  /// puis « 00:59 » … « 00:00 » pendant la dernière.
  static func menuBarText(_ remaining: TimeInterval) -> String {
    let total = max(0, Int(remaining))
    return total < 60 ? String(format: "00:%02d", total) : "\((total + 59) / 60) min"
  }

  /// Le temps restant avant `end`, en secondes ENTIÈRES arrondies au-dessus : « 24:59 » dure toute la
  /// seconde qui suit le premier tick, comme le décompte par pas de 1 qu'il remplace. Pure, donc
  /// testable sans attendre.
  static func secondsLeft(until end: Date, at now: Date) -> TimeInterval {
    max(0, end.timeIntervalSince(now).rounded(.up))
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    hasStarted = true
    // La date de fin se pose AVANT de fabriquer le `Timer` : ses ticks tombent à `création + k`, donc
    // juste APRÈS `fin − (N − k)`, et l'arrondi au-dessus donne alors exactement `N − k`. Dans
    // l'autre ordre chaque tick lirait une seconde de trop.
    endDate = now().addingTimeInterval(remaining)
    // `AllowingIdleSystemSleep` : on veut des ticks à l'heure, pas un Mac qui ne dort plus tant
    // qu'un enchaînement automatique tourne sans personne devant.
    activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep, reason: "Minuteur Pomodoro")
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
  ///
  /// `syncingMusic: false` quand l'appelant a déjà tu la musique et que la suite la resynchronise :
  /// la fin d'une phase (cf. `handlePhaseCompletion`).
  private func halt(syncingMusic: Bool = true) {
    // Le reste se FIGE à l'instant de l'arrêt : sans date de fin, plus rien ne le fera avancer.
    if let endDate { remaining = Self.secondsLeft(until: endDate, at: now()) }
    endDate = nil
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    isRunning = false
    timer?.invalidate()
    timer = nil
    if syncingMusic { syncMusic() }
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
    // Enchaînement automatique : le minuteur tourne toujours et la phase neuve repart de sa durée
    // pleine, d'ici.
    if isRunning { endDate = now().addingTimeInterval(remaining) }
    syncMusic()
  }

  /// Un tick lit l'horloge, il ne compte pas : un tick retardé ou sauté donne le même temps restant
  /// qu'un tick à l'heure. Interne et pas privé, pour qu'un test le joue avec une horloge fausse.
  func tick() {
    guard let endDate else { return }
    let previous = remaining
    // Jamais en arrière : un recalage de l'horloge système ne doit pas faire remonter le compte.
    let left = min(previous, Self.secondsLeft(until: endDate, at: now()))
    if left != previous { remaining = left }
    // Le fondu s'amorce UNE fois par phase, quand le reste TRAVERSE le seuil : `previous > seuil`
    // et `left <= seuil`. Le franchissement, et pas l'égalité — un tick sauté (veille, fil occupé)
    // ne tombe plus pile sur la seconde et le fondu n'aurait jamais lieu —, et ni une reprise
    // sous le seuil ni une phase plus courte que le fondu ne le déclenchent : le reste y est déjà
    // en dessous, rien ne le traverse. Un simple `<=` repartirait du volume plein à chaque tick.
    let fade = MusicPlayer.shared.fadeSeconds
    if phase == .work, previous > TimeInterval(fade), left <= TimeInterval(fade) {
      MusicPlayer.shared.fadeOut()
    }
    // `<=` : si un tick est sauté par-dessus la fin, la phase finit quand même au suivant.
    if left <= 0 {
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
    let finished = phase
    let alert = PomodoroAlertStyle.current
    // L'arrêt se décide AVANT d'ouvrir la phase suivante, pas après. Dans l'autre ordre,
    // `advancePhase` voyait un minuteur encore en marche et, si la phase suivante était un travail,
    // relançait la musique — que `halt` coupait aussitôt : un play puis un pause audibles à chaque
    // fin de pause, sur l'écran plein comme sans enchaînement automatique.
    if alert.takesOver(after: finished)
      || !UserDefaults.standard.bool(forKey: Self.autoStartStorageKey)
    {
      // L'alarme vient de sonner : elle EST le signal, rien à ajouter derrière. La musique est déjà
      // tue (plus haut) et `advancePhase` la resynchronise sur un minuteur arrêté.
      halt(syncingMusic: false)
    }
    // `advancePhase` resynchronise la musique : avec l'enchaînement automatique, le minuteur tourne
    // toujours et personne n'appellera `start()` — c'est donc là que le travail retrouve sa musique.
    advancePhase()
    PomodoroAlertWindow.announce(
      alert, finished: finished, next: phase, duration: formattedRemaining,
      onStart: { [weak self] in self?.start() })
  }

  private func duration(for phase: PomodoroPhase) -> TimeInterval {
    switch phase {
    case .work: return TimeInterval(workMinutes * 60)
    case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
    case .longBreak: return TimeInterval(longBreakMinutes * 60)
    }
  }
}
