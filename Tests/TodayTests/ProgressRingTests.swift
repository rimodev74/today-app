import CoreGraphics
import SwiftUI
import XCTest

@testable import Today

/// `ProgressRing` monte sa part de camembert EN PERMANENCE — c'est ce qui lui fait parcourir sa
/// valeur au lieu d'entrer et sortir de l'arbre en fondu à chaque extrémité (cf. son commentaire).
/// Toute la mise en page repose donc sur une hypothèse : à 0 %, la part ne peint rien. Sans ça, une
/// liste vide afficherait un trait parasite dans son anneau.
final class ProgressRingTests: XCTestCase {
  private static let side = 40

  /// Aire réellement peinte par la part, en pixels. On SOMME la couverture (0…1 par pixel) au lieu
  /// de compter les pixels non nuls : le rendu est anticrénelé, et compter chaque pixel de bord
  /// pour un entier gonflait l'aire de tout le périmètre (~5 % sur un disque de 40 px).
  private func paintedArea(progress: Double) -> Double {
    let side = Self.side
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.addPath(PieWedge(progress: progress).path(in: rect).cgPath)
    context.fillPath()
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    return (0..<(side * side)).reduce(into: 0.0) { total, i in
      total += Double(pixels[i]) / 255
    }
  }

  /// Aire du disque complet, référence des deux tests de proportion.
  private var discArea: Double {
    let radius = Double(Self.side) / 2
    return .pi * radius * radius
  }

  /// L'hypothèse critique : à 0 %, rien n'est peint. Le chemin existe bien (un point vers le bord,
  /// refermé) mais il est dégénéré — d'aire nulle, donc invisible une fois rempli.
  func testZeroProgress_paintsNothing() {
    XCTAssertEqual(paintedArea(progress: 0), 0)
  }

  /// À 100 %, la part couvre le disque entier — c'est elle qui remplace le `Circle().fill()` que
  /// la variante `showsFill` posait autrefois par-dessus (et qui, lui, arrivait en fondu).
  func testFullProgress_coversTheDisc() {
    XCTAssertEqual(paintedArea(progress: 1), discArea, accuracy: discArea * 0.01)
  }

  /// Entre les deux, la part suit la progression — sinon `animatableData` interpolerait vers une
  /// géométrie fausse et l'anneau mentirait pendant toute l'animation.
  func testHalfProgress_coversHalfTheDisc() {
    XCTAssertEqual(paintedArea(progress: 0.5), discArea / 2, accuracy: discArea * 0.01)
  }

  /// LE bug du clignotement, en test. Une valeur ANIMÉE sort de 0…1 dès que la courbe rebondit :
  /// sous 0 l'arc s'ouvrait à l'envers et le remplissage peignait le COMPLÉMENT de la part (disque
  /// quasi plein pour une progression négative), au-dessus de 1 il repassait par un tour complet.
  /// D'où le disque qui battait plein/vide en passant d'une liste avancée à une liste vide.
  ///
  /// Ce test échoue si le bornage de `PieWedge.path` disparaît — quelle que soit la courbe
  /// d'animation en vigueur.
  func testOvershootBelowZero_paintsNothing() {
    for progress in [-0.01, -0.15, -0.4] {
      XCTAssertEqual(
        paintedArea(progress: progress), 0,
        "une progression négative (\(progress)) ne doit rien peindre, pas le complément de la part")
    }
  }

  func testOvershootAboveOne_staysAFullDisc() {
    for progress in [1.01, 1.2, 1.5] {
      XCTAssertEqual(
        paintedArea(progress: progress), discArea, accuracy: discArea * 0.01,
        "au-delà de 1 (\(progress)), la part reste le disque plein — elle ne repart pas à zéro")
    }
  }

  /// La progression est bien ce que `animatableData` lit et écrit : c'est par elle que SwiftUI fait
  /// grandir la part image par image. Elle n'est PAS bornée — seul le tracé l'est, pour que
  /// l'interpolation garde sa continuité.
  func testAnimatableData_roundTripsProgress() {
    var wedge = PieWedge(progress: 0.25)
    XCTAssertEqual(wedge.animatableData, 0.25)
    wedge.animatableData = 0.75
    XCTAssertEqual(wedge.progress, 0.75)
  }
}
