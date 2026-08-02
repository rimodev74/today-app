import CoreGraphics
import SwiftData

/// Le glissement en cours sur une page de tâches : où sont les lignes, laquelle est empoignée, de
/// combien elle a bougé — et tout ce qui s'en déduit.
///
/// Type de VALEUR, sans SwiftUI : un état de vue qui vit dans le `@State` de la page. C'est le
/// pendant de `TaskFocus` pour le geste de la souris, et la même raison d'être — trois pages
/// tenaient sinon les mêmes quatre `@State` nus, avec les mêmes cinq transitions recopiées.
///
/// ## Ce qu'il ne calcule pas lui-même
///
/// L'arithmétique du réordonnancement est dans `Reorder.swift` (`ReorderTarget`, `ReorderLayout`),
/// déjà écrite et déjà vérifiée pour la page d'une liste et la sidebar. Ce type ne fait que la
/// nourrir : il n'y a pas deux façons de calculer un trou d'insertion dans cette app.
///
/// ## Ce qu'il ne décide pas
///
/// Ce qu'on ÉCRIT au relâchement ne le regarde pas. Il rend l'ordre obtenu (`dropped(in:)`) ; à la
/// page d'en tirer sa règle — renuméroter `smartOrder`, et sur « Tâches » rattacher la tâche à la
/// liste où elle a atterri. C'est la même frontière que celle posée en tête de `Reorder.swift`.
struct TaskPageReorder {
  /// Cadres des lignes dans le repère `taskPageSpace`, publiés par `measureTaskRow`.
  private(set) var frames: [PersistentIdentifier: CGRect] = [:]
  private(set) var dragging: PersistentIdentifier?
  /// Translation du geste en cours, depuis l'empoignade.
  private(set) var translation: CGSize = .zero

  init() {}

  var isDragging: Bool { dragging != nil }
  func isDragging(_ task: TaskItem) -> Bool { dragging == task.persistentModelID }

  /// Nouvelle mesure des lignes — **ignorée pendant un glissement**.
  ///
  /// Le gel n'est pas une optimisation. `frame(in:)` inclut le `.offset` appliqué aux lignes
  /// pendant le geste : réinjecter ces cadres décalés dans un calcul qui suppose les positions de
  /// REPOS boucle (décalage → cadre → décalage…), ce que SwiftUI signale par « update multiple
  /// times per frame » et que l'œil voit comme une saccade. Le layout de repos, lui, ne bouge pas
  /// d'un glissement : les cadres pris avant l'empoignade restent valides jusqu'au relâchement.
  mutating func measured(_ new: [PersistentIdentifier: CGRect]) {
    guard dragging == nil else { return }
    frames = new
  }

  mutating func begin(_ task: TaskItem) {
    dragging = task.persistentModelID
    translation = .zero
  }

  mutating func drag(_ translation: CGSize) {
    guard dragging != nil else { return }
    self.translation = translation
  }

  mutating func end() {
    dragging = nil
    translation = .zero
  }

  /// La mise en page du glissement dans `rows`, l'ordre affiché. `nil` hors glissement, ou tant que
  /// la ligne tirée n'est pas mesurée.
  func layout(in rows: [TaskItem]) -> ReorderLayout<PersistentIdentifier>? {
    guard let dragging, let dragFrame = frames[dragging],
      let origin = rows.firstIndex(where: { $0.persistentModelID == dragging })
    else { return nil }

    return ReorderLayout(
      others: rows.map(\.persistentModelID).filter { $0 != dragging },
      origin: origin,
      // Visée par frontières, sur la séquence de repos COMPLÈTE — la ligne tirée y comprise, dont
      // le créneau sert de pivot (cf. `ReorderTarget.byBoundary`).
      insert: ReorderTarget.byBoundary(
        center: dragFrame.midY + translation.height,
        centers: rows.map { frames[$0.persistentModelID]?.midY }),
      unit: dragFrame.height)
  }

  /// Le décalage de CHAQUE ligne, en un passage : la ligne tirée suit le curseur, les autres
  /// s'écartent pour ouvrir le trou. À calculer une fois par rendu — une recherche par rangée
  /// coûterait un balayage quadratique à chaque image.
  func offsets(in rows: [TaskItem]) -> [PersistentIdentifier: CGSize] {
    guard let dragging, let layout = layout(in: rows) else { return [:] }
    var result = layout.offsets().mapValues { CGSize(width: 0, height: $0) }
    result[dragging] = translation
    return result
  }

  /// Le trou d'insertion, dans le repère des cadres. `nil` s'il n'y a rien à montrer.
  func placeholder(in rows: [TaskItem]) -> CGRect? {
    guard let dragging, let dragFrame = frames[dragging], let layout = layout(in: rows),
      let top = layout.placeholderTop(frames: frames, draggedTop: dragFrame.minY)
    else { return nil }
    return CGRect(x: dragFrame.minX, y: top, width: dragFrame.width, height: dragFrame.height)
  }

  /// L'ordre obtenu si on relâchait maintenant. `nil` hors glissement.
  func dropped(in rows: [TaskItem]) -> [TaskItem]? {
    guard let dragging, let layout = layout(in: rows),
      let task = rows.first(where: { $0.persistentModelID == dragging })
    else { return nil }
    return layout.reordered([task], among: rows.filter { $0.persistentModelID != dragging })
  }
}
