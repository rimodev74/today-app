import XCTest

@testable import Today

/// Le formatage des durées. `DayCapacityTests` couvrait ce coin par ricochet ; la barre de
/// capacité partie, `Estimate` reste (menu « Durée… » d'une tâche) et garde ses propres tests.
final class EstimateTests: XCTestCase {
  func testLabel_rendNilQuandRienNestEstime() {
    XCTAssertNil(Estimate.label(0))
    XCTAssertNil(Estimate.label(-30))
  }

  func testLabel_ecritLesTroisFormes() {
    XCTAssertEqual(Estimate.label(45), "45 min")
    XCTAssertEqual(Estimate.label(120), "2 h")
    XCTAssertEqual(Estimate.label(90), "1 h 30")
  }

  /// Chaque préréglage doit savoir s'écrire : un choix du menu qui rendrait `nil` afficherait un
  /// bouton au titre vide.
  func testChaquePresetSaitSecrire() {
    for minutes in Estimate.presets {
      XCTAssertNotNil(Estimate.label(minutes), "\(minutes) min ne s'écrit pas")
    }
  }
}
