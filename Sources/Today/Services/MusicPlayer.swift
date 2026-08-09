import AppKit
import Foundation
import SwiftUI

/// La musique d'une session de travail : elle joue tant qu'un pomodoro de TRAVAIL tourne, descend
/// jusqu'au silence avant l'alarme, et se tait pendant les pauses.
///
/// Par AppleScript, et pas par une lecture intégrée. Spotify et Musique exposent déjà `play`,
/// `pause` et `sound volume` : l'utilisateur choisit sa playlist là où il la choisit d'habitude, et
/// Today n'a NI lien à stocker, NI flux à décoder, NI vue à héberger. Le chemin YouTube a été écarté
/// pour cette dernière raison avant tout : une `WKWebView` demande une fenêtre, or on joue justement
/// quand la fenêtre de Today est fermée — et ordonner une fenêtre est la famille de plantages non
/// résolue de ce projet (cf. `CLAUDE.md`, « une vue HORS-PROCESS de WebKit »).
@MainActor
final class MusicPlayer {
  /// Un singleton pour la même raison que `PomodoroTimer.shared` : il est atteint depuis le minuteur,
  /// qui l'est lui-même depuis un gestionnaire Carbon sans accès à l'arbre de vues.
  static let shared = MusicPlayer()

  static let enabledKey = "pomodoroMusicEnabled"
  static let appKey = "pomodoroMusicApp"
  static let volumeKey = "pomodoroMusicVolume"
  static let fadeKey = "pomodoroMusicFadeSeconds"
  static let selectionKey = "pomodoroMusicSelection"
  /// L'ancien réglage : UN lien, saisi à même les Réglages. Remplacé par la bibliothèque le 8 août
  /// 2026, mais toujours LU quand celle-ci est vide — sans quoi un lien posé avant la mise à jour
  /// disparaîtrait au premier lancement, sans un mot.
  static let legacyPlaylistKey = "pomodoroMusicPlaylist"
  static let defaultVolume = 70
  static let defaultFadeSeconds = 6

  /// Un test ne pilote pas le lecteur de qui le lance — même garde, et pour la même raison, que
  /// `PomodoroSound.play()`.
  private static let isTesting = NSClassFromString("XCTestCase") != nil

  /// Quatre pas par seconde. En dessous, la descente s'entend par MARCHES au lieu de s'entendre
  /// comme un fondu : à un pas par seconde, chaque palier retire ~17 % d'un coup.
  private static let fadeStepsPerSecond = 4

  /// Un aller-retour Apple Event est SYNCHRONE : depuis le fil qui dessine, il le gèle le temps que
  /// l'autre app réponde. Une file, donc — et SÉRIE, parce que l'ordre des ordres compte :
  /// « remettre le volume » puis « jouer » ne veut pas dire la même chose à l'envers.
  private let queue = DispatchQueue(label: "com.ryanmonnier.Today.music")

  private var fade: Timer?
  private var fadeStep = 0
  private var reportedFailure = false

  /// La playlist DÉJÀ lancée, telle qu'elle était écrite dans les réglages. Ce n'est pas un booléen
  /// pour une raison : il porte deux règles au lieu d'une. Une session ne relance sa playlist qu'au
  /// premier travail — sans quoi le premier morceau reviendrait toutes les 25 minutes, et les pauses
  /// couperaient la playlist au lieu de la suspendre. Et la changer en cours de session la relance,
  /// puisque le texte retenu ne correspond plus.
  private var launchedPlaylist: String?

  var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

  var fadeSeconds: Int {
    UserDefaults.standard.object(forKey: Self.fadeKey) as? Int ?? Self.defaultFadeSeconds
  }

  private var volume: Int {
    UserDefaults.standard.object(forKey: Self.volumeKey) as? Int ?? Self.defaultVolume
  }

  /// Le lien de la playlist CHOISIE dans la bibliothèque, ou celui de l'ancien réglage tant qu'aucune
  /// playlist n'a été enregistrée. Vide = rien à lancer, Today se contente de reprendre la lecture.
  private var playlistLink: String {
    let defaults = UserDefaults.standard
    // `Data` vide = clé JAMAIS écrite → l'ancien réglage. Une bibliothèque vidée à la main, elle,
    // s'encode en « [] » : elle ne retombe donc pas sur un lien que l'utilisateur croyait effacé.
    // Même distinction que `TextShortcut.decode`, et pour la même raison.
    let data = defaults.data(forKey: SavedPlaylist.storageKey) ?? Data()
    guard !data.isEmpty else { return defaults.string(forKey: Self.legacyPlaylistKey) ?? "" }
    let library = SavedPlaylist.decode(data)
    let selection = UUID(uuidString: defaults.string(forKey: Self.selectionKey) ?? "")
    return library.first { $0.id == selection }?.link ?? ""
  }

  private var app: MusicApp {
    MusicApp(rawValue: UserDefaults.standard.string(forKey: Self.appKey) ?? "") ?? .spotify
  }

  /// Lance la playlist réglée au premier travail d'une session, puis REPREND la lecture aux
  /// suivants. Sans playlist réglée, ne fait que reprendre : c'est le cas par défaut, et il suffit
  /// à qui choisit sa musique dans son lecteur avant de s'y mettre.
  func play() {
    cancelFade()
    guard isEnabled else { return }
    let wanted = playlistLink
    if launchedPlaylist != wanted, let launch = MusicPlaylist.launchCommand(wanted, for: app) {
      launchedPlaylist = wanted
      // Le lecteur se met AU PREMIER PLAN en recevant l'ordre de lancement, et sa fenêtre saute
      // devant celle où l'on travaille juste au moment où le pomodoro démarre. On note donc qui
      // avait le focus AVANT d'envoyer — après, c'est déjà trop tard, c'est lui qui l'a.
      send(
        "set sound volume to \(volume)", launch,
        thenRestoringFocusTo: NSWorkspace.shared.frontmostApplication?.processIdentifier)
      return
    }
    send("set sound volume to \(volume)", "play")
  }

  /// Les playlists de Musique, pour le menu des réglages. Vide quand Musique est fermée : ALLER LA
  /// LANCER pour lire une liste serait un effet de bord que personne n'a demandé — le champ texte
  /// reste là pour ce cas, et c'est pour ça que le menu ne le remplace pas.
  ///
  /// Spotify n'a pas d'équivalent : son dictionnaire AppleScript n'expose que `application` et
  /// `track` (vérifié le 8 août 2026), donc AUCUN accès à la bibliothèque. Ne pas chercher plus loin
  /// de ce côté — la seule voie serait son API web, avec compte développeur, OAuth et quota.
  func musicPlaylistNames() async -> [String] {
    guard !Self.isTesting else { return [] }
    let source = """
      if application "Music" is running then
        tell application "Music" to get name of every user playlist
      end if
      """
    return await withCheckedContinuation { continuation in
      queue.async {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        // Musique fermée : le script ne rend rien, et `numberOfItems` vaut 0 sur un descripteur qui
        // n'est pas une liste. Pas d'échec à signaler — il n'y a simplement rien à proposer.
        guard let result, result.numberOfItems > 0 else {
          continuation.resume(returning: [])
          return
        }
        // AppleScript indexe ses listes à partir de 1.
        continuation.resume(
          returning: (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue })
      }
    }
  }

  /// Le nom de ce qu'un lien Spotify désigne, ou `nil` s'il ne désigne rien (l'endpoint rend 404 sur
  /// un identifiant inventé — vérifié). Sert au champ des réglages à dire ce qu'il a compris.
  nonisolated static func spotifyTitle(for uri: String) async -> String? {
    guard let url = MusicPlaylist.titleLookupURL(for: uri),
      let (data, response) = try? await URLSession.shared.data(from: url),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["title"] as? String
  }

  /// Repart de la playlist au prochain `play()`. Appelé par la remise à zéro du minuteur, qui est
  /// justement le geste qui dit « nouvelle session » — les pauses d'une même session, elles, doivent
  /// reprendre la playlist là où le fondu l'avait laissée.
  func rewindPlaylist() {
    launchedPlaylist = nil
  }

  /// Met en pause et REMET le volume. Le fondu ne doit rien laisser derrière lui : sans cette
  /// remise, la lecture suivante repartirait de zéro et la musique passerait pour cassée.
  func stop() {
    cancelFade()
    guard isEnabled else { return }
    send("pause", "set sound volume to \(volume)")
  }

  /// Descend jusqu'au silence, puis met en pause. C'est ce qui laisse l'alarme de fin de phase
  /// arriver dans le silence : sonnée par-dessus la musique, elle passe dessous et ne s'entend pas.
  func fadeOut() {
    cancelFade()
    guard isEnabled else { return }
    fadeStep = 0
    let timer = Timer(
      timeInterval: 1 / Double(Self.fadeStepsPerSecond), repeats: true
    ) { [weak self] _ in
      // Ajouté à `RunLoop.main` juste en dessous : ce bloc ne part jamais d'ailleurs que du fil
      // principal, ce que le type de `Timer` ne sait pas exprimer (cf. `PomodoroTimer.start`).
      MainActor.assumeIsolated { self?.stepFade() }
    }
    // .common, comme le tick du minuteur : un menu ouvert ne doit pas figer le fondu à mi-course.
    RunLoop.main.add(timer, forMode: .common)
    fade = timer
  }

  private func stepFade() {
    let steps = max(1, fadeSeconds * Self.fadeStepsPerSecond)
    fadeStep += 1
    guard fadeStep < steps else {
      stop()  // dernier pas : le silence est atteint, on met en pause et on rend son volume
      return
    }
    send("set sound volume to \(Self.fadedVolume(volume, step: fadeStep, of: steps))")
  }

  /// Le volume d'un pas de fondu. Sortie en fonction pure parce que c'est la seule arithmétique du
  /// fichier, et la seule chose qui se vérifie sans lecteur ouvert. `nonisolated` pour cette raison
  /// exacte : elle ne touche à rien du fil principal, et un test n'a pas à s'y placer pour l'appeler.
  nonisolated static func fadedVolume(_ full: Int, step: Int, of steps: Int) -> Int {
    guard steps > 0 else { return 0 }
    return max(0, full - full * min(step, steps) / steps)
  }

  private func cancelFade() {
    fade?.invalidate()
    fade = nil
  }

  /// `thenRestoringFocusTo` rend le premier plan à qui l'avait, une fois l'ordre passé. Un
  /// identifiant de process et pas l'objet : `NSRunningApplication` n'est pas `Sendable`, et il
  /// traverserait deux isolations pour arriver ici.
  ///
  /// Seul le LANCEMENT d'une playlist en a besoin — mesuré le 9 août 2026 : `play` tout court,
  /// `pause` et les pas du fondu ne réveillent aucune fenêtre. Aucune façon de lancer une playlist
  /// sans ce passage devant n'a été trouvée : `open -g` sur l'URI (qui, lui, n'active rien) se
  /// contente d'AFFICHER la playlist — lecteur en pause, il ne la lance pas.
  ///
  /// ponytail: le lecteur passe donc devant un court instant avant de rendre la main. C'est
  /// visible, et c'est le plafond de l'approche.
  private func send(_ commands: String..., thenRestoringFocusTo previous: pid_t? = nil) {
    guard !Self.isTesting else { return }
    let name = app.rawValue
    // `is running` en garde : adresser un Apple Event à une app fermée la LANCERAIT. Personne n'a
    // demandé à ce qu'un pomodoro ouvre Spotify, et jouer suppose de toute façon une playlist déjà
    // choisie — sans elle, « play » n'aurait rien à reprendre.
    let source = """
      if application "\(name)" is running then
        tell application "\(name)"
          \(commands.joined(separator: "\n      "))
        end tell
      end if
      """
    queue.async {
      var error: NSDictionary?
      NSAppleScript(source: source)?.executeAndReturnError(&error)
      // Juste derrière l'ordre, sans délai : vérifié, le focus rendu tient (le lecteur ne le
      // reprend pas une seconde fois).
      if let previous {
        Task { @MainActor in NSRunningApplication(processIdentifier: previous)?.activate() }
      }
      guard let error else { return }
      let number = error[NSAppleScript.errorNumber] as? Int ?? 0
      Task { @MainActor in self.report(number, app: name) }
    }
  }

  /// L'échec le plus probable est aussi le seul que l'utilisateur puisse corriger : l'automatisation
  /// refusée. macOS ne pose la question qu'UNE fois, et après un refus tout redevient silencieux —
  /// sans ce mot, la musique « ne marche pas » sans que rien n'explique pourquoi. Le journal système
  /// ne remonterait rien non plus (cf. `CLAUDE.md`), d'où la pastille.
  ///
  /// Une seule fois par lancement : le fondu envoie une vingtaine d'ordres, qui échoueraient tous.
  private func report(_ errorNumber: Int, app name: String) {
    guard !reportedFailure else { return }
    reportedFailure = true
    let message =
      errorNumber == -1743
      ? "Autorisez Today à contrôler \(name) dans Réglages ▸ Confidentialité ▸ Automatisation"
      : "Musique : \(name) n'a pas répondu"
    HUDWindow.show(message, systemImage: "music.note", tint: .orange)
  }
}
