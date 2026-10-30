import AppKit
import XCTest

@testable import Today

/// La couleur d'un projet vit dans la même colonne qu'avant (`Project.colorRaw`) : ces tests tiennent
/// qu'une base d'avant se relit telle quelle, et que la couleur libre fait l'aller-retour.
final class ProjectColorTests: XCTestCase {
  func testLaPaletteSeRelitCommeAvant() {
    for palette in PaletteColor.allCases {
      XCTAssertEqual(ProjectColor(raw: palette.rawValue), .palette(palette))
      XCTAssertEqual(ProjectColor.palette(palette).raw, palette.rawValue)
    }
  }

  func testLaCouleurLibreFaitLAllerRetour() {
    XCTAssertEqual(ProjectColor(raw: "#3A7BD5"), .custom(0x3A7BD5))
    XCTAssertEqual(ProjectColor.custom(0x3A7BD5).raw, "#3A7BD5")
    XCTAssertEqual(ProjectColor.custom(0x00000F).raw, "#00000F")
  }

  func testUneValeurIllisibleNeDonneAucuneCouleur() {
    XCTAssertNil(ProjectColor(raw: ""))
    XCTAssertNil(ProjectColor(raw: "3A7BD5"))
    XCTAssertNil(ProjectColor(raw: "#3A7BD"))
    XCTAssertNil(ProjectColor(raw: "#GGGGGG"))
    XCTAssertNil(ProjectColor(raw: "magenta"))
  }

  func testLeProjetLitEtEcritLaColonne() {
    let project = Project(title: "P")
    project.color = .custom(0x112233)
    XCTAssertEqual(project.colorRaw, "#112233")
    XCTAssertEqual(project.color, .custom(0x112233))
    project.colorRaw = "green"
    XCTAssertEqual(project.color, .palette(.green))
  }

  /// Une couleur sombre choisie en clair doit rester visible en sombre : plus lumineuse, même teinte.
  func testLaVarianteSombreEstPlusLumineuseEtGardeSaTeinte() {
    let navy: UInt32 = 0x1A2B5C
    let dark = ProjectColor.darkVariant(of: navy)
    func hsb(_ hex: UInt32) -> (CGFloat, CGFloat) {
      let c = NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
      var h: CGFloat = 0
      var b: CGFloat = 0
      c.getHue(&h, saturation: nil, brightness: &b, alpha: nil)
      return (h, b)
    }
    XCTAssertGreaterThan(hsb(dark).1, hsb(navy).1)
    XCTAssertGreaterThanOrEqual(hsb(dark).1, 0.54)
    XCTAssertEqual(hsb(dark).0, hsb(navy).0, accuracy: 0.02)
  }

  func testHexDUneNSColor() {
    XCTAssertEqual(
      ProjectColor.hex(of: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)), 0xFF8000)
  }

  // Les deux tests d'origine, gardés (adaptés au type `ProjectColor`).

  func testColor_roundTripsThroughRawValue() {
    let project = Project(title: "Refonte")
    XCTAssertNil(project.color, "un projet neuf n'a pas de teinte : il suit l'accent système")

    project.color = .palette(.purple)
    XCTAssertEqual(project.colorRaw, "purple")
    XCTAssertEqual(project.color, .palette(.purple))

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
