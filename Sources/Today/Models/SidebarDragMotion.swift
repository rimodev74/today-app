import Foundation
import Observation

/// Ce qu'un glissement dans la barre latérale change à CHAQUE IMAGE : la translation sous le
/// curseur, le décalage de chaque autre ligne, et le trou d'insertion.
///
/// Le pendant de `ListDragMotion` pour la barre latérale. Pas le même type : celui-là est clé par
/// `TaskRowKey` (lignes de tâches), la sidebar a ses propres lignes (projets, listes, rangée « + »)
/// — d'où la clé en paramètre. Le calcul (`SidebarView.dragLayout`) reste dans la vue, qui seule sait
/// quelles lignes forment le groupe tiré et où il a le droit de se poser ; ce type ne transporte
/// que le résultat.
///
/// ## Pourquoi il existe
///
/// La translation vivait dans un `@State` de `SidebarView`, lu par `dragLayout()` depuis le corps :
/// chaque image du geste invalidait donc le corps qui construit TOUTES les rangées (projets, listes,
/// menus contextuels, palettes), pour ne déplacer en vérité que quelques lignes. Même défaut, même
/// remède que sur les pages de tâches (cf. `ListDragMotion` pour la mesure).
///
/// **Règle à tenir : la vue ne le lit JAMAIS depuis son `body`.** Elle l'ÉCRIT depuis le geste, et
/// seuls les deux modificateurs qui en ont besoin le lisent — celui qui décale une rangée et celui
/// qui dessine le trou.
@MainActor @Observable
final class SidebarDragMotion<Key: Hashable> {
  /// La translation brute : ce que suit la ligne empoignée (et tout son bloc).
  private(set) var translation: CGSize = .zero
  /// L'écartement vertical des AUTRES lignes.
  private(set) var offsets: [Key: CGFloat] = [:]
  /// Le trou d'insertion, dans le repère de la sidebar.
  private(set) var placeholder: CGRect?

  init() {}

  /// Les trois d'un coup, et chacune n'est écrite que si elle a CHANGÉ : réécrire une valeur
  /// identique invalide quand même ses lecteurs, et c'est l'invalidation qui coûte.
  func update(translation: CGSize, offsets: [Key: CGFloat], placeholder: CGRect?) {
    if self.translation != translation { self.translation = translation }
    if self.offsets != offsets { self.offsets = offsets }
    if self.placeholder != placeholder { self.placeholder = placeholder }
  }

  func clear() {
    update(translation: .zero, offsets: [:], placeholder: nil)
  }

  /// Le décalage d'UNE ligne. `lifted` = elle fait partie du groupe tiré : elle suit le curseur en
  /// 2D au lieu de s'écarter verticalement.
  func offset(of key: Key, lifted: Bool) -> CGSize {
    lifted ? translation : CGSize(width: 0, height: offsets[key] ?? 0)
  }
}
