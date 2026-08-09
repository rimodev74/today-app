import XCTest

@testable import Today

/// Ce que l'utilisateur COLLE dans les réglages. Trois formes circulent selon d'où l'on copie, et
/// aucune ne se distingue à l'œil une fois dans un champ de texte.
final class MusicPlaylistTests: XCTestCase {
  func testSpotifyURI_acceptsAPastedShareLink() {
    XCTAssertEqual(
      MusicPlaylist.spotifyURI(from: "https://open.spotify.com/playlist/37i9dQZF1DWZeKCadgRdKQ"),
      "spotify:playlist:37i9dQZF1DWZeKCadgRdKQ")
  }

  /// Le lien partagé traîne un `?si=…` de suivi, systématiquement. Gardé, il ferait partie de
  /// l'identifiant et l'URI ne désignerait plus rien.
  func testSpotifyURI_dropsTheTrackingQuery() {
    XCTAssertEqual(
      MusicPlaylist.spotifyURI(
        from: "https://open.spotify.com/playlist/37i9dQZF1DWZeKCadgRdKQ?si=abc123&pt=x"),
      "spotify:playlist:37i9dQZF1DWZeKCadgRdKQ")
  }

  /// Le cas qui casse en silence : depuis une app localisée, Spotify glisse `intl-fr` en tête du
  /// chemin. Un segment de trop, et l'URI fabriquée vaudrait `spotify:intl-fr:playlist`.
  func testSpotifyURI_skipsTheLocalePathSegment() {
    XCTAssertEqual(
      MusicPlaylist.spotifyURI(
        from: "https://open.spotify.com/intl-fr/playlist/37i9dQZF1DWZeKCadgRdKQ"),
      "spotify:playlist:37i9dQZF1DWZeKCadgRdKQ")
  }

  func testSpotifyURI_passesAnAlreadyValidURIThrough() {
    XCTAssertEqual(
      MusicPlaylist.spotifyURI(from: "  spotify:album:1DFixLWuPkv3KT3TnV35m3  "),
      "spotify:album:1DFixLWuPkv3KT3TnV35m3")
  }

  func testSpotifyURI_refusesWhatIsNotSpotify() {
    XCTAssertNil(MusicPlaylist.spotifyURI(from: ""))
    XCTAssertNil(MusicPlaylist.spotifyURI(from: "Deep Focus"))
    XCTAssertNil(MusicPlaylist.spotifyURI(from: "https://music.youtube.com/playlist?list=abc"))
    XCTAssertNil(MusicPlaylist.spotifyURI(from: "https://open.spotify.com/playlist"))
  }

  /// L'URI part en paramètre de requête, deux-points compris. Les laisser tels quels ou les encoder
  /// marche des deux côtés (vérifié contre l'endpoint le 8 août 2026) — ce que ce test tient, c'est
  /// que l'URI arrive ENTIÈRE, sans être coupée au premier deux-points.
  func testTitleLookupURL_carriesTheWholeURI() {
    let url = MusicPlaylist.titleLookupURL(for: "spotify:playlist:37i9dQZF1DWZeKCadgRdKQ")
    let text = url?.absoluteString ?? ""
    XCTAssertTrue(text.hasPrefix("https://open.spotify.com/oembed?url="), text)
    XCTAssertTrue(
      text.contains("37i9dQZF1DWZeKCadgRdKQ") && text.contains("playlist"), text)
  }

  /// Musique désigne une playlist par son NOM : rien à traduire, mais tout à échapper.
  func testLaunchCommand_quotesAMusicPlaylistName() {
    XCTAssertEqual(
      MusicPlaylist.launchCommand("Deep Focus", for: .music), "play playlist \"Deep Focus\"")
  }

  /// Un guillemet dans un nom de playlist fermerait la chaîne AppleScript, et la suite du nom
  /// deviendrait des ORDRES. C'est le seul endroit du projet où l'on coud une saisie dans une
  /// syntaxe exécutable.
  func testLaunchCommand_escapesQuotesInAName() {
    XCTAssertEqual(
      MusicPlaylist.launchCommand("Rock \"n\" Roll", for: .music),
      "play playlist \"Rock \\\"n\\\" Roll\"")
  }

  /// La bibliothèque vit encodée dans les défauts : ce qui en sort doit être ce qui y est entré,
  /// identifiants compris — c'est l'identifiant qui dit laquelle joue.
  func testLibrary_survivesARoundTrip() {
    let entries = [
      SavedPlaylist(name: "Deep Focus", link: "spotify:playlist:abc", app: .spotify),
      SavedPlaylist(name: "", link: "Chill", app: .music),
    ]
    XCTAssertEqual(SavedPlaylist.decode(SavedPlaylist.encode(entries)), entries)
  }

  /// Une clé jamais écrite, ou du contenu illisible : une bibliothèque vide, pas un plantage.
  func testLibrary_decodesGarbageAsEmpty() {
    XCTAssertTrue(SavedPlaylist.decode(Data()).isEmpty)
    XCTAssertTrue(SavedPlaylist.decode(Data("pas du JSON".utf8)).isEmpty)
  }

  func testLaunchCommand_isNilWithoutAPlaylist() {
    XCTAssertNil(MusicPlaylist.launchCommand("", for: .spotify))
    XCTAssertNil(MusicPlaylist.launchCommand("   ", for: .music))
    // Un nom de playlist Musique collé dans le champ alors que Spotify est sélectionné : rien à
    // lancer plutôt qu'un ordre bancal — Today reprendra simplement la lecture en cours.
    XCTAssertNil(MusicPlaylist.launchCommand("Deep Focus", for: .spotify))
  }
}
