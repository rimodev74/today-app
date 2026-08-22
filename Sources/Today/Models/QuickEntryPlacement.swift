import CoreGraphics

/// Où se pose la BARRE de la capsule de saisie rapide — l'arithmétique seule, sans fenêtre.
///
/// Tout ici corrige le même décalage : la fenêtre déborde largement la barre — 60pt de chaque côté
/// pour le verre et son ombre, ~500 vers le bas pour les résultats. C'est la barre qu'on place, et
/// jamais le cadre : centrer le cadre poserait la barre très au-dessus du milieu de l'écran.
///
/// Sortie de `QuickEntryWindow` parce qu'elle y faisait cinq calculs de rectangles qu'on ne pouvait
/// vérifier qu'en ouvrant la capsule à l'œil — et qu'une erreur de signe s'y voit mal.
struct QuickEntryPlacement {
  let panelSize: CGSize
  let barWidth: CGFloat
  let barHeight: CGFloat
  /// L'écart entre le haut de la fenêtre et celui de la barre.
  let topInset: CGFloat

  /// L'origine du panneau qui pose le centre de la barre à l'endroit voulu, et l'inverse.
  func panelOrigin(barCenter: CGPoint) -> CGPoint {
    CGPoint(
      x: barCenter.x - panelSize.width / 2,
      y: barCenter.y + barHeight / 2 + topInset - panelSize.height)
  }

  func barCenter(ofPanel frame: CGRect) -> CGPoint {
    CGPoint(x: frame.midX, y: frame.maxY - topInset - barHeight / 2)
  }

  /// La barre à sa fraction de la zone utile, bornée pour y tenir EN ENTIER : une fraction prise sur
  /// un 5K pousserait la barre hors d'un écran plus étroit.
  func barCenter(fraction: CGPoint, in visible: CGRect) -> CGPoint {
    CGPoint(
      x: clamp(
        visible.minX + visible.width * fraction.x,
        visible.minX + barWidth / 2, visible.maxX - barWidth / 2),
      y: clamp(
        visible.minY + visible.height * fraction.y,
        visible.minY + barHeight / 2, visible.maxY - barHeight / 2))
  }

  /// La fraction qu'occupe un centre de barre dans la zone utile. C'est ELLE qu'on enregistre, et pas
  /// des points : la barre doit revenir au même endroit relatif sur l'écran où l'on travaille, quelle
  /// que soit sa taille.
  func fraction(barCenter: CGPoint, in visible: CGRect) -> CGPoint? {
    guard visible.width > 0, visible.height > 0 else { return nil }
    return CGPoint(
      x: (barCenter.x - visible.minX) / visible.width,
      y: (barCenter.y - visible.minY) / visible.height)
  }

  /// L'aimant de ⌘. Les deux axes sont INDÉPENDANTS : on centre en largeur seule, en hauteur seule,
  /// ou les deux d'un même geste — c'est ce qui en fait une aide au placement plutôt qu'un bouton
  /// « au centre ».
  func snappedToCenter(barCenter: CGPoint, in visible: CGRect, within distance: CGFloat) -> CGPoint
  {
    CGPoint(
      x: abs(barCenter.x - visible.midX) < distance ? visible.midX : barCenter.x,
      y: abs(barCenter.y - visible.midY) < distance ? visible.midY : barCenter.y)
  }

  /// Le milieu est le moins faux des placements dans les deux cas où il n'y a rien à borner : des
  /// bornes croisées (écran plus étroit que la barre) et une valeur non finie.
  ///
  /// Le second n'arrive que d'une fraction trafiquée dans les défauts — mais un NaN traverserait tout
  /// le calcul jusqu'à `setFrameOrigin`, et la capsule deviendrait introuvable sans aucun moyen de la
  /// rattraper depuis l'app. Le seul verrou est ici : c'est par où passent TOUTES les fractions lues.
  private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
    guard value.isFinite, low <= high else { return (low + high) / 2 }
    return min(max(value, low), high)
  }
}
