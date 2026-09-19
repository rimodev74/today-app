import Foundation
import Observation

/// Ce qu'un glissement change à CHAQUE IMAGE sur la page d'une liste : la translation sous le
/// curseur, le décalage de chaque autre ligne, et le trou d'insertion.
///
/// Le pendant de `TaskPageReorder` pour le moteur PROPRE de cette page — pas son remplaçant : le
/// calcul (`ListPageView.dragState`) reste là-bas, parce qu'il connaît les blocs, les en-têtes et
/// les champs « Nouvelle tâche » de cette page-là. Ce type ne transporte QUE le résultat.
///
/// ## Pourquoi il existe
///
/// Exactement la même raison que la classe observée de `TaskPageReorder`, et le même chiffre
/// derrière : ces trois valeurs vivaient dans le `@State` de la page, donc chaque image du geste
/// invalidait un corps qui reconstruit toutes les rangées. **14,8 ms par image sur 23 lignes**
/// (mesuré le 19 septembre 2026), et le défaut revenait à chaque fonctionnalité ajoutée à la page
/// ou à `TaskRow` — tout ce qu'on ajoute tombe sinon dans le chemin de l'image.
///
/// **Règle à tenir : la page ne le lit JAMAIS depuis son `body`.** Elle l'ÉCRIT depuis le geste,
/// et seuls les deux modificateurs qui en ont besoin le lisent — celui qui décale une rangée et
/// celui qui dessine le trou.
@MainActor @Observable
final class ListDragMotion {
  /// La translation brute : ce que suit la ligne empoignée (et tout son bloc).
  private(set) var translation: CGSize = .zero
  /// L'écartement vertical des AUTRES lignes, champs « Nouvelle tâche » compris.
  private(set) var offsets: [TaskRowKey: CGFloat] = [:]
  /// Le trou d'insertion, dans le repère de la liste.
  private(set) var placeholder: CGRect?

  init() {}

  /// Les trois d'un coup, et chacune n'est écrite que si elle a CHANGÉ : réécrire une valeur
  /// identique invalide quand même ses lecteurs, et c'est l'invalidation qui coûte.
  func update(translation: CGSize, offsets: [TaskRowKey: CGFloat], placeholder: CGRect?) {
    if self.translation != translation { self.translation = translation }
    if self.offsets != offsets { self.offsets = offsets }
    if self.placeholder != placeholder { self.placeholder = placeholder }
  }

  func clear() {
    update(translation: .zero, offsets: [:], placeholder: nil)
  }

  /// Le décalage d'UNE ligne. `lifted` = elle fait partie du groupe tiré, elle suit donc le
  /// curseur en 2D au lieu de s'écarter verticalement.
  func offset(of key: TaskRowKey, lifted: Bool) -> CGSize {
    lifted ? translation : CGSize(width: 0, height: offsets[key] ?? 0)
  }
}
