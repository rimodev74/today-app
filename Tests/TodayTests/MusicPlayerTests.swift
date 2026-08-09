import XCTest

@testable import Today

/// La seule arithmétique de `MusicPlayer` : tout le reste part en AppleScript vers une autre app et
/// ne se vérifie qu'avec un lecteur ouvert.
final class MusicPlayerTests: XCTestCase {
  func testFadedVolume_startsFullAndReachesSilence() {
    XCTAssertEqual(MusicPlayer.fadedVolume(80, step: 0, of: 24), 80)
    XCTAssertEqual(MusicPlayer.fadedVolume(80, step: 24, of: 24), 0)
  }

  /// Le fondu DESCEND, du premier pas au dernier. Une division entière mal placée le ferait remonter
  /// ou plafonner — c'est le seul défaut que cette fonction peut avoir.
  func testFadedVolume_decreasesMonotonically() {
    let steps = 24
    var previous = MusicPlayer.fadedVolume(70, step: 0, of: steps)
    for step in 1...steps {
      let volume = MusicPlayer.fadedVolume(70, step: step, of: steps)
      XCTAssertLessThanOrEqual(volume, previous)
      previous = volume
    }
  }

  /// Deux bords qui n'arrivent jamais par l'interface (le pas de fondu est borné à 3…15 s) mais
  /// qu'un appel futur pourrait produire : ni volume négatif, ni division par zéro.
  func testFadedVolume_clampsOutOfRangeInput() {
    XCTAssertEqual(MusicPlayer.fadedVolume(70, step: 99, of: 24), 0)
    XCTAssertEqual(MusicPlayer.fadedVolume(70, step: 1, of: 0), 0)
  }
}
