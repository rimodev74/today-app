import AppKit
import SwiftUI

/// Ce qu'un raccourci texte déclenche DANS l'app, par opposition à ce qu'il pose sur la tâche en
/// train de s'écrire (une date, une destination). « Afficher Aujourd'hui » n'écrit rien : la frappe
/// emmène quelque part, puis la capsule se retire.
///
/// Le sigil `!` sépare les deux familles dans `TextShortcut.expansion` : `@` et `#` partent au
/// parseur de saisie rapide, `!` ne l'atteint jamais. Un raccourci reste donc une simple chaîne, et
/// les trois familles tiennent dans un seul menu.
enum AppCommand: String, CaseIterable, Identifiable {
  case show
  case all
  case today
  case upcoming
  case archive
  case pomodoroStart
  case pomodoroPause
  case pomodoroSkip
  case pomodoroShortBreak
  case pomodoroLongBreak

  var id: String { rawValue }
  var token: String { "!" + rawValue }

  var label: String {
    switch self {
    case .show: return "Afficher l'application"
    case .all: return "Afficher Tâches"
    case .today: return "Afficher Aujourd'hui"
    case .upcoming: return "Afficher À venir"
    case .archive: return "Afficher Archives"
    case .pomodoroStart: return "Lancer un pomodoro"
    case .pomodoroPause: return "Mettre le pomodoro en pause"
    case .pomodoroSkip: return "Passer à la phase suivante"
    case .pomodoroShortBreak: return "Démarrer une pause courte"
    case .pomodoroLongBreak: return "Démarrer une pause longue"
    }
  }

  /// Les mots par lesquels la palette peut trouver la commande, EN PLUS de son libellé.
  ///
  /// Nécessaire parce que trois des cinq actions du minuteur ne portent pas le mot « pomodoro » —
  /// « Passer à la phase suivante », « Démarrer une pause courte », « Démarrer une pause longue ».
  /// Sans ces mots-clés, taper « pomodoro » n'en sortait que deux sur cinq, alors que c'est
  /// précisément le mot par lequel on les cherche toutes.
  var keywords: [String] {
    isPomodoro ? ["pomodoro", "minuteur"] : []
  }

  /// L'icône de la commande dans la palette de la capsule (cf. `QuickPalette`). Les commandes de
  /// navigation empruntent celle de la page où elles emmènent — deux icônes différentes pour le
  /// même endroit se liraient comme deux destinations.
  var systemImage: String {
    if let smartList { return smartList.systemImage }
    switch self {
    case .show: return "macwindow"
    case .pomodoroStart: return "play.fill"
    case .pomodoroPause: return "pause.fill"
    case .pomodoroSkip: return "forward.fill"
    case .pomodoroShortBreak, .pomodoroLongBreak: return "cup.and.saucer.fill"
    case .all, .today, .upcoming, .archive: return "macwindow"  // couvertes par `smartList`
    }
  }

  /// Les cinq commandes du minuteur, dans l'ordre où les réglages les présentent.
  static let pomodoroCommands: [AppCommand] = [
    .pomodoroStart, .pomodoroPause, .pomodoroSkip, .pomodoroShortBreak, .pomodoroLongBreak,
  ]

  /// L'onglet à poser, ou `nil` pour « ramène l'app et ne touche à rien ».
  var smartList: SmartList? {
    switch self {
    case .show: return nil
    case .all: return .all
    case .today: return .today
    case .upcoming: return .upcoming
    case .archive: return .archive
    case .pomodoroStart, .pomodoroPause, .pomodoroSkip, .pomodoroShortBreak, .pomodoroLongBreak:
      return nil
    }
  }

  /// Les commandes du minuteur, qui ne sont PAS des commandes de navigation : elles n'emmènent nulle
  /// part et ne doivent surtout pas ramener l'app: leur seul intérêt est de lancer ou d'arrêter un
  /// Pomodoro sans quitter ce qu'on fait. C'est la pastille qui rend compte, pas la fenêtre.
  var isPomodoro: Bool { Self.pomodoroCommands.contains(self) }

  init?(token: String) {
    guard token.hasPrefix("!") else { return nil }
    self.init(rawValue: String(token.dropFirst()))
  }

  /// Le canal vers `ContentView`, seul détenteur de la sélection (un `@State` privé). Une
  /// notification et pas un objet partagé : la capsule de saisie rapide vit dans sa propre fenêtre
  /// AppKit, hors de l'arbre de vues, et n'a aucun autre moyen d'atteindre cet état.
  static let selectionNotification = Notification.Name("app.today.selectSmartList")

  /// Le relais pour la fenêtre qui n'existe pas encore. `activate` peut RECRÉER la fenêtre
  /// principale (elle avait été fermée au bouton rouge) : la notification part alors avant que la
  /// `ContentView` neuve ne se soit abonnée, et se perdrait. Elle la lit à son apparition.
  ///
  /// Une `SidebarSelection` et plus seulement une `SmartList` : la palette de la capsule sait
  /// désormais ouvrir l'app sur un DOSSIER ou une LISTE (⌘↩), pas seulement sur une vue.
  @MainActor static var pendingSelection: SidebarSelection?

  @MainActor func run() {
    if isPomodoro { return runPomodoro() }
    activate()
    guard let smartList else { return }
    Self.reveal(.smartList(smartList), activating: false)
  }

  /// Ramène l'app et l'ouvre SUR un élément précis — ce que `!today` faisait pour une vue, étendu à
  /// n'importe quelle destination de la barre latérale.
  ///
  /// `activating` distingue les deux appelants : `run` a déjà activé l'app avant de savoir où aller
  /// (elle active même quand il n'y a nulle part où aller, cf. `!show`), la capsule non.
  @MainActor static func reveal(_ selection: SidebarSelection, activating: Bool = true) {
    pendingSelection = selection
    if activating { AppCommand.show.run() }
    NotificationCenter.default.post(name: selectionNotification, object: nil)
  }

  /// Le minuteur, piloté au clavier. `PomodoroTimer.shared` et pas l'instance de l'environnement :
  /// la frappe part d'un gestionnaire Carbon (cf. `GlobalHotKey`), qui n'a aucun accès à l'arbre de
  /// vues — et doit répondre même quand la fenêtre principale a été fermée au bouton rouge.
  @MainActor private func runPomodoro() {
    let timer = PomodoroTimer.shared
    switch self {
    case .pomodoroStart:
      timer.startWork()
      HUDWindow.show(
        "Pomodoro · " + timer.formattedRemaining, systemImage: "play.fill", tint: .red)
    case .pomodoroPause:
      timer.pause()
      HUDWindow.show(
        "Pomodoro en pause · " + timer.formattedRemaining, systemImage: "pause.fill")
    case .pomodoroShortBreak:
      timer.begin(.shortBreak)
      HUDWindow.show(
        "Pause courte · " + timer.formattedRemaining, systemImage: "cup.and.saucer.fill",
        tint: .blue)
    case .pomodoroLongBreak:
      timer.begin(.longBreak)
      HUDWindow.show(
        "Pause longue · " + timer.formattedRemaining, systemImage: "cup.and.saucer.fill",
        tint: .blue)
    case .pomodoroSkip:
      timer.advancePhase()
      HUDWindow.show(
        timer.phase.label + " · " + timer.formattedRemaining, systemImage: "forward.fill")
    case .show, .all, .today, .upcoming, .archive:
      break
    }
  }

  /// Ramène Today au premier plan, exactement comme un clic sur son icône du Dock — y compris quand
  /// la fenêtre a été fermée au bouton rouge.
  @MainActor private func activate() {
    NSApp.activate(ignoringOtherApps: true)
    // Les fenêtres hors sujet s'écartent d'elles-mêmes : la capsule de saisie rapide et le
    // `MenuBarExtra` sont sans bordure, donc jamais `canBecomeMain`.
    guard let window = NSApp.windows.first(where: \.canBecomeMain) else {
      // Fermée au bouton rouge, la fenêtre ne SURVIT PAS dans `NSApp.windows` : SwiftUI la détruit,
      // il n'y a rien à ramener, il faut la recréer. Seul AppKit sait remonter une scène
      // `WindowGroup`, et le clic Dock est son unique déclencheur public — d'où la demande
      // d'ouverture sur notre propre bundle, qui le rejoue pour de vrai (LaunchServices envoie le
      // reopen, AppKit exécute son comportement par défaut, SwiftUI rouvre).
      // Appeler `applicationShouldHandleReopen` à la main ne suffit PAS : le délégué SwiftUI répond
      // « oui, comportement par défaut » à un AppKit qui n'écoute pas — la fenêtre ne revenait jamais.
      NSWorkspace.shared.openApplication(
        at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
      return
    }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    } else {
      window.makeKeyAndOrderFront(nil)
    }
  }
}
