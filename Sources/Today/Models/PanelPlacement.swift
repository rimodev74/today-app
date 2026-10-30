import CoreGraphics

/// Où se pose un panneau révélé DANS la fenêtre (cf. `PagePanelHost`), à côté de ce qui l'a ouvert —
/// l'arithmétique seule, sans vue.
///
/// C'est ce que `NSPopover` faisait pour nous : se poser sous son ancre, se retourner au-dessus
/// quand la place manque, ne jamais sortir de l'écran. Le popover est parti — c'est une FENÊTRE, et
/// SwiftUI la présente depuis le layout, ce qui tue ce process (`PIEGES.md` § Fenêtres) —, ces trois
/// règles restent à tenir, et une erreur de signe s'y voit mal à l'œil.
///
/// Tous les rectangles sont dans le repère de la zone qui accueille le panneau : origine en haut à
/// gauche, comme tout repère SwiftUI.
enum PanelPlacement {
  /// Le bord de l'ancre sur lequel le panneau s'aligne. `trailing` pour une rangée : ce qui ouvre un
  /// panneau (la date, l'icône du calendrier, le •••) vit à son bord droit.
  enum Alignment: Sendable {
    case leading, trailing
  }

  /// L'écart entre l'ancre et le panneau : assez pour qu'il ne paraisse pas collé à la rangée.
  static let gap: CGFloat = 6
  /// La marge minimale entre le panneau et le bord de la zone qui l'accueille.
  static let margin: CGFloat = 8

  /// Le cadre du panneau de taille `size`, ancré à `anchor`, dans une zone de taille `bounds`.
  ///
  /// Dessous d'abord ; au-dessus si dessous déborde ; et si aucun des deux ne tient, posé au plus
  /// bas qui tienne encore — il recouvre alors son ancre, comme le ferait un popover à l'étroit.
  /// Un panneau plus grand que la zone garde son bord HAUT (ou gauche) visible : c'est là que
  /// commence ce qu'on lit.
  ///
  /// ponytail: pas de défilement interne — un panneau plus haut que la page déborde en bas. Les
  /// trois panneaux font moins de 520 pt ; la fenêtre principale ne descend pas en dessous.
  static func frame(
    of size: CGSize, anchoredTo anchor: CGRect, alignment: Alignment, in bounds: CGSize
  ) -> CGRect {
    let preferredX = alignment == .leading ? anchor.minX : anchor.maxX - size.width
    let x = clamp(preferredX, margin, bounds.width - margin - size.width)

    let below = anchor.maxY + gap
    let above = anchor.minY - gap - size.height
    let y: CGFloat
    if below + size.height <= bounds.height - margin {
      y = below
    } else if above >= margin {
      y = above
    } else {
      y = clamp(below, margin, bounds.height - margin - size.height)
    }
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }

  /// Borne `value` entre `low` et `high` ; si `high < low` (le panneau ne tient pas), `low` gagne.
  private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
    max(low, min(value, high))
  }
}

/// Quel panneau montrer quand plusieurs se déclarent ouverts à la fois, et lesquels refermer.
///
/// Ça arrive sans maladresse : un panneau ouvert sur une tâche se referme au clic GAUCHE ailleurs,
/// pas au clic droit — et le menu contextuel d'une autre tâche propose « Quand… ». Le dernier
/// ouvert l'emporte, comme un popover chasse le précédent ; les autres sont REFERMÉS, et pas
/// seulement cachés : laissés ouverts, ils réapparaîtraient sous le suivant qu'on ferme.
enum PanelStack {
  /// `open` : les identifiants des panneaux qui se déclarent ouverts, dans l'ordre de l'arbre (qui
  /// ne dit RIEN de l'ordre d'ouverture). `shown` : celui qu'on montrait jusqu'ici.
  static func resolve(open: [String], shown: String?) -> (shown: String?, closing: [String]) {
    guard let chosen = open.last(where: { $0 != shown }) ?? open.first else { return (nil, []) }
    return (chosen, open.filter { $0 != chosen })
  }
}
