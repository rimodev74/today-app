import CoreGraphics
import XCTest

@testable import Today

/// Le placement d'un panneau révélé dans la fenêtre, et l'arbitrage entre deux panneaux ouverts.
///
/// Une zone de 800 × 600, un panneau de 260 × 300, une rangée de 700 × 30 : chaque attente se lit
/// sans calculer (écart 6, marge 8).
final class PanelPlacementTests: XCTestCase {

  private let bounds = CGSize(width: 800, height: 600)
  private let panel = CGSize(width: 260, height: 300)

  private func row(y: CGFloat) -> CGRect { CGRect(x: 50, y: y, width: 700, height: 30) }

  // MARK: Vertical

  func testSitsBelowItsAnchorWhenThereIsRoom() {
    let frame = PanelPlacement.frame(
      of: panel, anchoredTo: row(y: 100), alignment: .trailing, in: bounds)

    XCTAssertEqual(frame.minY, 136, "100 + 30 de rangée + 6 d'écart")
    XCTAssertEqual(frame.size, panel, "la taille n'est jamais retouchée")
  }

  func testFlipsAboveWhenBelowWouldOverflow() {
    let frame = PanelPlacement.frame(
      of: panel, anchoredTo: row(y: 450), alignment: .trailing, in: bounds)

    XCTAssertEqual(frame.minY, 144, "450 − 6 − 300 : le bas du panneau touche presque la rangée")
    XCTAssertLessThan(frame.maxY, 450, "au-dessus, il ne recouvre pas son ancre")
  }

  /// Zone de 400 de haut. Ni dessous (236 + 300 > 392) ni dessus (200 − 306 < 8) : posé au plus
  /// bas qui tienne.
  func testOverlapsItsAnchorWhenNeitherSideFits() {
    let short = CGSize(width: 800, height: 400)
    let frame = PanelPlacement.frame(
      of: panel, anchoredTo: row(y: 200), alignment: .trailing, in: short)

    XCTAssertEqual(frame.minY, 92, "400 − 8 − 300")
    XCTAssertLessThanOrEqual(frame.maxY, short.height - PanelPlacement.margin)
  }

  func testTallerThanTheZoneKeepsItsTopVisible() {
    let tiny = CGSize(width: 800, height: 200)
    let frame = PanelPlacement.frame(
      of: panel, anchoredTo: row(y: 50), alignment: .trailing, in: tiny)

    XCTAssertEqual(frame.minY, PanelPlacement.margin, "le haut reste lisible, le bas déborde")
  }

  // MARK: Horizontal

  func testTrailingAlignsOnTheAnchorRightEdge() {
    let frame = PanelPlacement.frame(
      of: panel, anchoredTo: row(y: 100), alignment: .trailing, in: bounds)

    XCTAssertEqual(frame.maxX, 750, "bord droit de la rangée")
  }

  func testLeadingAlignsOnTheAnchorLeftEdge() {
    let button = CGRect(x: 300, y: 40, width: 20, height: 20)
    let frame = PanelPlacement.frame(of: panel, anchoredTo: button, alignment: .leading, in: bounds)

    XCTAssertEqual(frame.minX, 300)
    XCTAssertEqual(frame.minY, 66)
  }

  func testNeverLeavesTheZoneSideways() {
    let nearRight = CGRect(x: 700, y: 40, width: 20, height: 20)
    let right = PanelPlacement.frame(
      of: panel, anchoredTo: nearRight, alignment: .leading, in: bounds)
    XCTAssertEqual(right.maxX, 792, "repoussé à 8 du bord droit")

    let nearLeft = CGRect(x: 0, y: 40, width: 100, height: 20)
    let left = PanelPlacement.frame(
      of: panel, anchoredTo: nearLeft, alignment: .trailing, in: bounds)
    XCTAssertEqual(left.minX, 8, "repoussé à 8 du bord gauche")
  }

  func testWiderThanTheZoneKeepsItsLeftEdgeVisible() {
    let narrow = CGSize(width: 200, height: 600)
    let frame = PanelPlacement.frame(
      of: panel, anchoredTo: row(y: 100), alignment: .trailing, in: narrow)

    XCTAssertEqual(frame.minX, PanelPlacement.margin)
  }

  // MARK: Deux panneaux ouverts

  func testNothingOpenShowsNothing() {
    let result = PanelStack.resolve(open: [], shown: "a")
    XCTAssertNil(result.shown)
    XCTAssertEqual(result.closing, [])
  }

  func testASingleOpenPanelIsShown() {
    let result = PanelStack.resolve(open: ["a"], shown: nil)
    XCTAssertEqual(result.shown, "a")
    XCTAssertEqual(result.closing, [])
  }

  func testTheShownPanelStaysWhenAlone() {
    let result = PanelStack.resolve(open: ["a"], shown: "a")
    XCTAssertEqual(result.shown, "a")
    XCTAssertEqual(result.closing, [])
  }

  /// L'ordre de l'arbre ne dit rien de l'ordre d'ouverture : le nouveau venu gagne, qu'il soit
  /// avant ou après celui qu'on montrait.
  func testTheNewcomerWinsWhereverItSitsInTheTree() {
    for open in [["a", "b"], ["b", "a"]] {
      let result = PanelStack.resolve(open: open, shown: "a")
      XCTAssertEqual(result.shown, "b", "\(open)")
      XCTAssertEqual(result.closing, ["a"], "\(open)")
    }
  }
}
