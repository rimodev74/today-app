import Foundation

/// Le lecteur que Today pilote. Le `rawValue` est le nom ADRESSABLE par AppleScript (celui qu'on
/// écrit dans `tell application "…"`), les autres propriétés sont ce qu'on affiche — les deux
/// diffèrent pour Musique, dont l'app s'appelle « Music » quelle que soit la langue du système.
enum MusicApp: String, CaseIterable, Identifiable, Codable {
  case spotify = "Spotify"
  case music = "Music"

  var id: String { rawValue }

  var label: String { self == .spotify ? "Spotify" : "Musique" }

  /// Les deux lecteurs ne désignent pas une playlist de la même façon, et c'est irréductible :
  /// Spotify la désigne par une URI qu'on COLLE, Musique par un nom qu'on CHOISIT dans sa
  /// bibliothèque. La colonne est la même, ce qu'on y met change — d'où son titre porté ici.
  var linkColumn: String { self == .spotify ? "Lien Spotify" : "Playlist Musique" }

  var playlistPrompt: String {
    self == .spotify ? "https://open.spotify.com/playlist/…" : "Deep Focus"
  }
}

/// Une playlist enregistrée : le lien qu'on colle UNE fois, nommé pour être rechoisi ensuite d'un
/// menu. Même patron de stockage que `TextShortcut` — `Codable` dans les défauts, pas un `@Model` :
/// c'est un réglage d'une poignée de lignes, et un `@Model` aurait coûté une montée de schéma, une
/// étape de migration et une fixture (cf. `TodaySchema.swift`) pour ranger deux chaînes.
struct SavedPlaylist: Codable, Identifiable, Hashable {
  var id = UUID()
  /// Ce qu'on lit dans le menu. Renseigné TOUT SEUL depuis Spotify quand le lien se résout, parce
  /// que le nom qu'on donnerait à la main est déjà celui que Spotify connaît.
  var name: String = ""
  /// Un lien Spotify, ou un nom de playlist Musique — cf. `MusicApp.linkColumn`.
  var link: String = ""
  /// Le lecteur pour lequel elle a un sens. Un lien Spotify ne veut rien dire pour Musique : sans ce
  /// champ, le menu mélangerait des entrées dont la moitié ne pourrait pas jouer.
  var app: MusicApp
}

extension SavedPlaylist {
  static let storageKey = "pomodoroMusicLibrary"

  static func decode(_ data: Data) -> [SavedPlaylist] {
    (try? JSONDecoder().decode([SavedPlaylist].self, from: data)) ?? []
  }

  static func encode(_ playlists: [SavedPlaylist]) -> Data {
    (try? JSONEncoder().encode(playlists)) ?? Data()
  }
}

/// Ce que l'utilisateur écrit dans les réglages, traduit en ordre AppleScript.
enum MusicPlaylist {
  /// L'ordre qui LANCE la playlist réglée, ou `nil` s'il n'y en a pas (auquel cas Today se contente
  /// de reprendre la lecture en cours — c'est le comportement par défaut, et il suffit souvent).
  static func launchCommand(_ raw: String, for app: MusicApp) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    switch app {
    case .spotify:
      guard let uri = spotifyURI(from: text) else { return nil }
      return "play track \"\(escaped(uri))\""
    case .music:
      return "play playlist \"\(escaped(text))\""
    }
  }

  /// Les trois formes qu'on peut avoir sous la main, ramenées à celle que Spotify sait lancer.
  ///
  /// `play track` attend une URI de PISTE d'après son dictionnaire — mais une URI de playlist y
  /// passe aussi, et lance la playlist (vérifié le 8 août 2026 sur Spotify : « Deep Focus » démarre).
  /// C'est ce qui évite d'avoir à demander une piste ET un contexte à l'utilisateur.
  static func spotifyURI(from raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    // Déjà une URI : rien à traduire. C'est ce que donne « Copier l'URI Spotify » (menu ⌥).
    if text.hasPrefix("spotify:") { return text }

    guard let url = URL(string: text), url.host?.hasSuffix("spotify.com") == true else {
      return nil
    }
    // `intl-fr` : Spotify glisse la langue en tête du chemin des liens copiés depuis une app
    // localisée. Un segment de trop, et l'URI fabriquée ne désigne plus rien — silencieusement.
    let parts = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
    guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    // Le genre n'est pas restreint à « playlist » : album, artiste et piste se lancent pareil, et
    // les refuser n'aurait protégé de rien — Spotify sait dire lui-même qu'une URI ne mène nulle part.
    return "spotify:\(parts[0]):\(parts[1])"
  }

  /// L'adresse qui rend le NOM de ce qu'un lien Spotify désigne.
  ///
  /// `oembed` est l'endpoint PUBLIC de Spotify : ni compte développeur, ni jeton, ni quota. C'est
  /// tout ce qui le sépare de l'API web, qui aurait exigé les trois pour lister des playlists —
  /// écarté le 8 août 2026 pour ce prix-là (cf. `ROADMAP.md`).
  ///
  /// L'URI `spotify:…` y passe telle quelle, deux-points non encodés compris (vérifié le même jour,
  /// dans les deux formes) : rien à ré-assembler vers une URL `open.spotify.com`.
  static func titleLookupURL(for uri: String) -> URL? {
    var components = URLComponents(string: "https://open.spotify.com/oembed")
    components?.queryItems = [URLQueryItem(name: "url", value: uri)]
    return components?.url
  }

  /// Un nom de playlist est écrit par l'utilisateur : il peut contenir un guillemet, qui fermerait
  /// la chaîne AppleScript et ferait du reste du nom des ORDRES. Échappé, donc, comme partout où
  /// l'on coud une valeur dans une syntaxe.
  static func escaped(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
