import XCTest

@testable import Today

/// La teinte d'un projet ne vit pas dans le modèle : c'est un `rawValue` en base, relu par une
/// propriété calculée. Ce test tient les deux bouts de cette traduction — le seul endroit où une
/// faute de frappe dans le `rawValue` passerait inaperçue jusqu'au prochain lancement.
final class ProjectColorTests: XCTestCase {
  func testColor_roundTripsThroughRawValue() {
    let project = Project(title: "Refonte")
    XCTAssertNil(project.color, "un projet neuf n'a pas de teinte : il suit l'accent système")

    project.color = .purple
    XCTAssertEqual(project.colorRaw, "purple")
    XCTAssertEqual(project.color, .purple)

    project.color = nil
    XCTAssertNil(
      project.colorRaw, "revenir « Par défaut » doit VIDER la colonne, pas y laisser \"\"")
  }

  func testColor_fromUnknownRawValue_isNil() {
    let project = Project(title: "Refonte")
    project.colorRaw = "turquoise-fluo"
    XCTAssertNil(
      project.color, "une teinte retirée de la palette retombe sur l'accent, sans planter")
  }
}
