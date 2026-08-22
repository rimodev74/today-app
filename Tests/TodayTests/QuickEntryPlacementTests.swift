import CoreGraphics
import XCTest

@testable import Today

/// Le placement de la barre de la capsule, cas par cas.
///
/// Ces calculs vivaient dans `QuickEntryWindow`, mêlés à `NSPanel` et `NSScreen` : la seule façon de
/// les vérifier était d'ouvrir la capsule et de regarder. Une erreur de signe entre les repères de
/// Cocoa (origine en bas) et le décalage de la fenêtre au-dessus de sa barre s'y voit très mal.
///
/// Nombres du vrai panneau (770 × 620, barre de 650 × 56 à 56pt du haut) et un écran rond de
/// 2000 × 1000 à l'origine, pour que chaque attente se lise sans calculer.
final class QuickEntryPlacementTests: XCTestCase {

  private let placement = QuickEntryPlacement(
    panelSize: CGSize(width: 770, height: 620), barWidth: 650, barHeight: 56, topInset: 56)
  private let visible = CGRect(x: 0, y: 0, width: 2000, height: 1000)

  // MARK: Le décalage fenêtre ↔ barre

  /// La fenêtre descend 536pt sous le centre de sa barre : 620 de haut, moins 56 de retrait et 28 de
  /// demi-barre. C'est ce décalage qui empêche de simplement centrer le cadre.
  func testPanelOriginSitsWellBelowTheBarItCarries() {
    let origin = placement.panelOrigin(barCenter: CGPoint(x: 1000, y: 500))

    XCTAssertEqual(origin.x, 615, "centrée en largeur : 1000 − 770/2")
    XCTAssertEqual(origin.y, -36, "500 + 28 + 56 − 620 : la fenêtre déborde SOUS l'écran")
  }

  func testBarCenterIsTheExactInverseOfPanelOrigin() {
    for center in [CGPoint(x: 1000, y: 500), CGPoint(x: -240, y: 1980), CGPoint(x: 0, y: 0)] {
      let frame = CGRect(
        origin: placement.panelOrigin(barCenter: center), size: placement.panelSize)

      XCTAssertEqual(placement.barCenter(ofPanel: frame), center, "aller-retour sans perte")
    }
  }

  // MARK: La fraction d'écran

  /// Le défaut : 0,5 / 0,5 pose la barre au centre de la zone utile, dans les DEUX sens.
  func testHalfHalfCentersTheBar() {
    let center = placement.barCenter(fraction: CGPoint(x: 0.5, y: 0.5), in: visible)

    XCTAssertEqual(center, CGPoint(x: 1000, y: 500))
  }

  /// Une zone utile décalée (l'écran secondaire vit à des coordonnées négatives) : la fraction se
  /// lit DANS elle, pas depuis l'origine globale.
  func testFractionIsReadInsideTheVisibleFrameNotFromTheGlobalOrigin() {
    let offscreen = CGRect(x: -479, y: 1329, width: 2560, height: 1410)

    let center = placement.barCenter(fraction: CGPoint(x: 0.5, y: 0.5), in: offscreen)

    XCTAssertEqual(center, CGPoint(x: 801, y: 2034))
  }

  /// La barre doit tenir EN ENTIER : une fraction prise sur un écran large ne peut pas la pousser
  /// dehors sur un plus étroit. 0,98 sur 2000pt viserait 1960, soit 635 hors du bord droit.
  func testFractionIsClampedSoTheWholeBarStaysOnScreen() {
    let center = placement.barCenter(fraction: CGPoint(x: 0.98, y: 0.99), in: visible)

    XCTAssertEqual(center.x, 1675, "2000 − 650/2")
    XCTAssertEqual(center.y, 972, "1000 − 56/2")
  }

  /// Écran plus étroit que la barre : les bornes se croisent. Le milieu est le moins faux des
  /// placements — surtout pas une borne, qui collerait la barre à un bord au hasard.
  func testABarWiderThanTheScreenLandsInTheMiddle() {
    let narrow = CGRect(x: 100, y: 0, width: 400, height: 1000)

    let center = placement.barCenter(fraction: CGPoint(x: 0, y: 0.5), in: narrow)

    XCTAssertEqual(center.x, 300, "le milieu de 400pt, pas un bord")
  }

  /// Une fraction trafiquée dans les défauts (`defaults write … "{nan, nan}"`) ne doit pas traverser
  /// le calcul : `setFrameOrigin` d'un NaN rend la capsule introuvable, et rien dans l'app ne permet
  /// alors de la rattraper. Elle retombe au centre, c'est-à-dire au défaut.
  func testANonFiniteFractionFallsBackToTheCenter() {
    let center = placement.barCenter(
      fraction: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), in: visible)

    XCTAssertEqual(center, CGPoint(x: 1000, y: 500))
  }

  func testFractionRoundTripsThroughBarCenter() {
    let center = placement.barCenter(fraction: CGPoint(x: 0.25, y: 0.75), in: visible)

    XCTAssertEqual(placement.fraction(barCenter: center, in: visible), CGPoint(x: 0.25, y: 0.75))
  }

  /// Un écran de taille nulle n'existe pas, mais `visibleFrame` peut le rendre le temps d'un
  /// changement de configuration : pas de division par zéro, pas de fraction écrite.
  func testNoFractionFromAnEmptyScreen() {
    XCTAssertNil(placement.fraction(barCenter: .zero, in: .zero))
  }

  // MARK: L'aimant de ⌘

  func testSnapPullsBothAxesWhenBothAreClose() {
    let snapped = placement.snappedToCenter(
      barCenter: CGPoint(x: 1040, y: 460), in: visible, within: 60)

    XCTAssertEqual(snapped, CGPoint(x: 1000, y: 500))
  }

  /// Les deux axes sont INDÉPENDANTS : c'est ce qui permet de centrer en largeur seule, en gardant
  /// la hauteur qu'on avait choisie.
  func testEachAxisSnapsOnItsOwn() {
    let snapped = placement.snappedToCenter(
      barCenter: CGPoint(x: 1040, y: 200), in: visible, within: 60)

    XCTAssertEqual(snapped.x, 1000, "proche en largeur : collée")
    XCTAssertEqual(snapped.y, 200, "loin en hauteur : intacte")
  }

  /// Au-delà du seuil l'aimant lâche — sinon ⌘ deviendrait un bouton « au centre » et on ne pourrait
  /// plus rien poser près du milieu sans l'y coller.
  func testSnapReleasesBeyondTheThreshold() {
    let far = CGPoint(x: 1060, y: 440)

    XCTAssertEqual(placement.snappedToCenter(barCenter: far, in: visible, within: 60), far)
  }
}
