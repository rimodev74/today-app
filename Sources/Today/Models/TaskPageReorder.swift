import Foundation
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
  ///
  /// Clés en `TaskRowKey` et non en identités de tâche : une page peut intercaler des rangées qui
  /// ne sont pas des tâches (le champ « Nouvelle tâche » d'un bloc) et qui occupent pourtant de la
  /// hauteur. Les pages qui n'ont que des tâches n'émettent que des `.task`.
  private(set) var frames: [TaskRowKey: CGRect] = [:]

  /// Ce qui VOYAGE : la ligne empoignée, et ce qu'elle emporte.
  ///
  /// Une tâche voyage seule ; une EN-TÊTE de section emporte tout son bloc. C'est la seule chose
  /// que la page d'une liste savait faire et que ce moteur ignorait — au prix d'un second moteur
  /// entier, écrit à côté, qui a fini par diverger sur des sujets sans rapport (son conteneur, ses
  /// lectures SwiftData). D'où la généralisation ici plutôt qu'une troisième implémentation.
  ///
  /// **Le PREMIER élément est celui qui suit le curseur** : c'est lui qu'on mesure, lui dont le
  /// créneau sert de pivot, et lui dont la hauteur est l'unité d'écartement. Les suivants ne font
  /// que l'accompagner. Ils doivent être CONTIGUS dans `rows` — `ReorderLayout` suppose que la
  /// place laissée par le groupe est d'un seul tenant.
  private(set) var dragged: [PersistentIdentifier] = []

  /// La ligne empoignée — celle qui suit le curseur.
  var dragging: PersistentIdentifier? { dragged.first }
  /// Translation du geste en cours, depuis l'empoignade.
  private(set) var translation: CGSize = .zero
  /// La séquence de lignes FIGÉE à l'empoignade, pour le CALCUL.
  ///
  /// Une vue intelligente ne stocke pas son ordre : elle le recalcule (filtre, tri, regroupement) à
  /// chaque rendu, donc à chaque image du geste. Le calcul s'appuie donc sur cette copie, prise une
  /// fois, et pas sur une liste qui pourrait changer sous lui — exactement comme les CADRES sont
  /// gelés, et pour la même raison.
  ///
  /// Ce que la page RÉAFFICHE, en revanche, reste sa séquence vivante : rendre celle-ci pendant le
  /// geste puis rebasculer sur celle-là au relâchement ferait deux mouvements simultanés, et la
  /// rangée déposée partirait à l'opposé avant de revenir.
  private(set) var rows: [TaskItem] = []

  /// La séquence PHYSIQUE figée à l'empoignade : TOUT ce qui occupe de la hauteur, dans l'ordre
  /// d'affichage — les tâches et les rangées « Nouvelle tâche ».
  ///
  /// Vide = la page n'a que des tâches, et les deux mises en page se confondent. C'est le cas des
  /// quatre pages intelligentes ; seule la page d'une liste intercale des champs.
  private(set) var physicalRows: [TaskRowKey] = []

  init() {}

  var isDragging: Bool { !dragged.isEmpty }

  /// Cette ligne est-elle celle qu'on TIRE ? Vrai pour la seule ligne qui suit le curseur — pas
  /// pour celles qu'elle emporte, qui restent à leur place et s'estompent (cf. `carries`).
  func isDragging(_ task: TaskItem) -> Bool { dragging == task.persistentModelID }

  /// Cette ligne est-elle EMPORTÉE par le glissement en cours ? Vrai pour la ligne tirée comme
  /// pour ses passagères. C'est ce que regarde une page pour estomper le reste d'un bloc pendant
  /// que son en-tête voyage.
  func carries(_ task: TaskItem) -> Bool { dragged.contains(task.persistentModelID) }

  /// La tâche empoignée, tant que le geste dure. Une page en a besoin au relâchement : ce qu'elle
  /// écrit dépend d'OÙ cette tâche-là a atterri, pas seulement de l'ordre obtenu.
  var draggedTask: TaskItem? { rows.first { $0.persistentModelID == dragging } }

  /// Tout ce qui voyage, dans l'ordre d'affichage.
  var draggedTasks: [TaskItem] {
    let carried = Set(dragged)
    return rows.filter { carried.contains($0.persistentModelID) }
  }

  /// Où en est le CENTRE de la ligne tirée, dans le repère des cadres. `nil` hors glissement.
  ///
  /// C'est le point qu'une page compare aux bandes de ses sections pour savoir sur QUOI on lâche —
  /// la seule question à laquelle l'ordre des lignes ne répond pas, quand la section visée est vide.
  /// Le calcul est déjà celui de `layout()`, sorti ici pour ne pas être réécrit à l'identique.
  var draggedCenterY: CGFloat? {
    guard let dragging, let frame = frames[.task(dragging)] else { return nil }
    return frame.midY + translation.height
  }

  /// Nouvelle mesure des lignes — **ignorée pendant un glissement**.
  ///
  /// Le gel n'est pas une optimisation. `frame(in:)` inclut le `.offset` appliqué aux lignes
  /// pendant le geste : réinjecter ces cadres décalés dans un calcul qui suppose les positions de
  /// REPOS boucle (décalage → cadre → décalage…), ce que SwiftUI signale par « update multiple
  /// times per frame » et que l'œil voit comme une saccade. Le layout de repos, lui, ne bouge pas
  /// d'un glissement : les cadres pris avant l'empoignade restent valides jusqu'au relâchement.
  mutating func measured(_ new: [TaskRowKey: CGRect]) {
    guard !isDragging else { return }
    frames = new
  }

  /// **Le seul point d'entrée d'un glissement.** Empoigne au premier mouvement, puis suit.
  ///
  /// Les pages appelaient `begin` puis `drag` chacune de leur côté, avec le même `if` en tête.
  /// Deux lignes recopiées, c'est déjà deux occasions de diverger — et l'ordre des deux appels
  /// n'est pas anodin : empoigner APRÈS avoir suivi perdrait la première translation.
  mutating func track(_ task: TaskItem, by translation: CGSize, in rows: [TaskItem]) {
    track([task], by: translation, in: rows)
  }

  /// La variante qui emporte un groupe (une en-tête et son bloc). `carrying.first` est la ligne
  /// empoignée ; un appel avec un groupe vide ne fait rien plutôt que d'armer un geste sans sujet.
  mutating func track(
    _ carrying: [TaskItem], by translation: CGSize, in rows: [TaskItem],
    physical: [TaskRowKey] = []
  ) {
    guard !carrying.isEmpty else { return }
    if !isDragging { begin(carrying, in: rows, physical: physical) }
    drag(translation)
  }

  mutating func begin(_ task: TaskItem, in rows: [TaskItem]) {
    begin([task], in: rows)
  }

  /// `physical` : la séquence complète des lignes qui occupent de la hauteur, champs compris. À
  /// omettre quand la page n'a que des tâches — les deux mises en page se confondent alors.
  mutating func begin(_ carrying: [TaskItem], in rows: [TaskItem], physical: [TaskRowKey] = []) {
    dragged = carrying.map(\.persistentModelID)
    translation = .zero
    self.rows = rows
    physicalRows = physical
  }

  mutating func drag(_ translation: CGSize) {
    guard isDragging else { return }
    self.translation = translation
  }

  mutating func end() {
    dragged = []
    translation = .zero
    rows = []
    physicalRows = []
  }

  /// La mise en page du glissement dans `rows`, l'ordre affiché. `nil` hors glissement, ou tant que
  /// la ligne tirée n'est pas mesurée.
  func layout() -> ReorderLayout<TaskRowKey>? {
    guard let dragging, let dragFrame = frames[.task(dragging)],
      let origin = rows.firstIndex(where: { $0.persistentModelID == dragging })
    else { return nil }

    // `others` écarte TOUT le groupe, pas seulement la ligne tirée : c'est la place laissée d'un
    // seul tenant que `ReorderLayout` réinsère. `origin`, lui, reste l'index de la LIGNE TIRÉE dans
    // la séquence complète — pour un groupe contigu, c'est aussi le rang de la place qu'il libère.
    let carried = Set(dragged)

    // Visée par frontières, sur la séquence de repos COMPLÈTE — le groupe y compris, dont le
    // créneau sert de pivot (cf. `ReorderTarget.byBoundary`).
    let raw = ReorderTarget.byBoundary(
      center: dragFrame.midY + translation.height,
      centers: rows.map { frames[.task($0.persistentModelID)]?.midY })

    return ReorderLayout(
      others: rows.filter { !carried.contains($0.persistentModelID) }
        .map { TaskRowKey.task($0.persistentModelID) },
      origin: origin,
      insert: insertIndex(from: raw, carried: carried),
      unit: dragFrame.height)
  }

  /// La mise en page des lignes PHYSIQUES — celle qui produit les décalages visibles.
  ///
  /// **Deux espaces d'index, et c'est délibéré.** `layout()` raisonne en TÂCHES : c'est là que le
  /// trou d'insertion s'ancre et que l'ordre s'écrit. Un trou calé sous un champ « Nouvelle tâche »
  /// se poserait un cran trop bas (le champ est invisible pendant le transport), et `sortIndex` ne
  /// numérote que des tâches. Mais les DÉCALAGES, eux, doivent compter toutes les lignes qui
  /// occupent de la hauteur, champs compris : c'est cette uniformité qui donne au champ la même
  /// continuité qu'aux autres au relâchement, sans traitement séparé.
  ///
  /// Le dépôt visé est le MÊME dans les deux espaces — on le traduit par l'IDENTITÉ de la ligne
  /// devant laquelle on se pose, jamais par un calcul d'indices. Les deux séquences ont le même
  /// ordre relatif ; c'est tout ce qu'il faut, et ça reste vrai quels que soient les champs
  /// intercalés.
  ///
  /// Sans séquence physique, il n'y a qu'un espace : on rend la mise en page des tâches telle
  /// quelle. Les quatre pages intelligentes sont dans ce cas.
  func rowLayout() -> ReorderLayout<TaskRowKey>? {
    guard let tasks = layout() else { return nil }
    guard !physicalRows.isEmpty else { return tasks }
    guard let dragging, let dragFrame = frames[.task(dragging)] else { return nil }

    let carried = Set(dragged.map(TaskRowKey.task))
    let others = physicalRows.filter { !carried.contains($0) }
    guard let origin = physicalRows.firstIndex(of: .task(dragging)) else { return nil }

    let insert =
      tasks.insert < tasks.others.count
      ? (others.firstIndex(of: tasks.others[tasks.insert]) ?? others.count)
      : others.count

    return ReorderLayout(others: others, origin: origin, insert: insert, unit: dragFrame.height)
  }

  /// Traduit le rang rendu par `byBoundary` — qui compte dans la séquence COMPLÈTE — vers celui
  /// qu'attend `ReorderLayout`, qui compte dans `others`.
  ///
  /// Pour UNE ligne tirée, les deux espaces se recollent d'eux-mêmes : son propre créneau sert de
  /// pivot, et l'index maximal (`n`) tombe pile sur la fin des `n − 1` restantes. C'est ce que
  /// documente `ReorderTarget.byBoundary`, et c'est vrai — mais **seulement pour k = 1**. Pour un
  /// groupe de `k` lignes, tout rang situé après le groupe compte encore ses `k` créneaux alors
  /// qu'`others` n'en a plus aucun : il dépasse de `k − 1` (le pivot, lui, reste dû).
  ///
  /// Sans cette correction, tirer un bloc de deux lignes de trois crans vers le bas l'envoyait tout
  /// en bas de la liste — l'index dépassait, `ReorderLayout` le bornait à la fin, et le bloc
  /// atterrissait ailleurs que là où on le voyait. Trouvé par le test, pas à l'écran.
  private func insertIndex(from raw: Int, carried: Set<PersistentIdentifier>) -> Int {
    let before = rows.prefix(raw).reduce(into: 0) {
      if carried.contains($1.persistentModelID) { $0 += 1 }
    }
    return raw - max(before - 1, 0)
  }

  /// Le décalage de CHAQUE ligne, en un passage : la ligne tirée suit le curseur, les autres
  /// s'écartent pour ouvrir le trou. À calculer une fois par rendu — une recherche par rangée
  /// coûterait un balayage quadratique à chaque image.
  /// Sur la mise en page PHYSIQUE : un champ « Nouvelle tâche » s'écarte comme une ligne de tâche,
  /// parce qu'il occupe de la hauteur comme elle (cf. `rowLayout`).
  func offsets() -> [TaskRowKey: CGSize] {
    guard let layout = rowLayout() else { return [:] }
    var result = layout.offsets().mapValues { CGSize(width: 0, height: $0) }
    // Tout le groupe suit le curseur, pas seulement la ligne tirée. Une page qui estompe ses
    // passagères (cf. `carries`) ne le verra pas ; une page qui les montre, si.
    for id in dragged { result[.task(id)] = translation }
    return result
  }

  /// Le trou d'insertion, dans le repère des cadres. `nil` s'il n'y a rien à montrer.
  func placeholder() -> CGRect? {
    guard let dragging, let dragFrame = frames[.task(dragging)], let layout = layout(),
      let top = layout.placeholderTop(frames: frames, draggedTop: dragFrame.minY)
    else { return nil }
    return CGRect(x: dragFrame.minX, y: top, width: dragFrame.width, height: dragFrame.height)
  }

  /// L'ordre obtenu si on relâchait maintenant. `nil` hors glissement.
  func dropped() -> [TaskItem]? {
    guard let layout = layout() else { return nil }
    let carried = Set(dragged)
    let moving = rows.filter { carried.contains($0.persistentModelID) }
    guard !moving.isEmpty else { return nil }
    return layout.reordered(moving, among: rows.filter { !carried.contains($0.persistentModelID) })
  }
}
