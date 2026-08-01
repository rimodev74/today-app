import CoreGraphics

/// Réordonnancement par glissement — toute l'arithmétique, sans SwiftUI ni AppKit.
///
/// Les deux surfaces réordonnables de l'app (la page d'une liste, la sidebar) partagent le même
/// mécanisme PHYSIQUE : aucune capture d'instantané (`.onDrag`/`NSItemProvider`, qui masque la ligne
/// et en fait voler une copie bitmap), mais la vraie ligne décalée sous le curseur tandis que les
/// voisines s'écartent pour ouvrir le trou. Au relâchement, l'ordre est écrit et les décalages
/// retombent à 0 : les lignes étaient DÉJÀ à leur place, rien ne saute.
///
/// Ce fichier tient ce que les deux surfaces calculaient chacune de son côté, à l'identique et sans
/// le savoir. Il est PUR — pas de vue, pas de `@State`, pas de modèle SwiftData — donc vérifiable
/// cas par cas (cf. `ReorderTests`), ce qu'aucune des deux ne pouvait être tant que ce calcul vivait
/// dans un `struct: View`.
///
/// ## Ce qui vit ici, et ce qui n'y vit pas
///
/// Ici : **où le groupe se pose** (les politiques de visée) et **comment les lignes s'écartent**
/// (`ReorderLayout`). C'est la partie commune, et c'est aussi celle où une erreur d'indice décale
/// silencieusement une ligne.
///
/// Pas ici : **ce qu'écrire au relâchement**. Une page de liste renumérote des `sortIndex`, la
/// sidebar peut en plus RATTACHER une liste à un autre projet. Ce sont deux règles métier
/// distinctes, pas une duplication — elles restent chez leur vue.

// MARK: - Visée

/// Où le groupe tiré se posera. Deux politiques, parce que deux gestes différents :
/// une ligne se place ENTRE deux voisines, un bloc se place AVANT un autre bloc.
enum ReorderTarget {
  /// Insertion ligne à ligne, par FRONTIÈRES : le trou bascule dès le demi-recouvrement.
  ///
  /// `centers` est la séquence de repos COMPLÈTE — la ligne tirée comprise, à sa place d'origine.
  /// Ce n'est pas un oubli : son créneau sert de PIVOT. Sans lui, revenir déposer le groupe à sa
  /// place d'origine viserait un cran trop haut, et tout déplacement vers le bas serait décalé de un.
  ///
  /// L'index rendu s'interprète pourtant dans la séquence SANS le groupe, et les deux espaces se
  /// recollent d'eux-mêmes : viser sous toute la liste rend le dernier index de la séquence complète
  /// (`n - 1`), qui est exactement la fin de la séquence restante (`n - 1` éléments). Aucune
  /// correction d'indice nulle part — c'est vérifié bout en bout par
  /// `ReorderTests.testBoundaryTargetingAndLayoutAgreeOnTheEnd`.
  ///
  /// `nil` dans `centers` = ligne non mesurée (pas encore rendue) : elle ne peut pas trancher, on
  /// passe à la suivante.
  static func byBoundary(center: CGFloat, centers: [CGFloat?]) -> Int {
    for index in centers.indices {
      guard let current = centers[index] else { continue }
      // Frontière = mi-chemin entre ce centre et le suivant. Pas de suivant (fin de séquence, ou
      // plus rien de mesuré) → aucune frontière ne peut être franchie par le bas.
      let next = centers.dropFirst(index + 1).compactMap { $0 }.first
      let boundary = next.map { ($0 + current) / 2 } ?? .greatestFiniteMagnitude
      if center < boundary { return index }
    }
    return centers.count
  }

  /// Insertion bloc à bloc : le groupe se pose au DÉBUT du premier bloc dont le centre passe sous
  /// le centre transporté. Sous tous les centres → `fallback` (la fin de la séquence).
  ///
  /// Les centres sont fournis DÉJÀ corrigés du repli par l'appelant (cf. `ReorderLayout.collapse`) :
  /// un bloc situé sous le groupe tiré a remonté de ce que le groupe a perdu en se repliant, et
  /// comparer des centres non corrigés viserait le mauvais bloc dès qu'on descend.
  static func byBlockStart(
    center: CGFloat, blocks: [(insert: Int, center: CGFloat)], fallback: Int
  ) -> Int {
    for block in blocks where center < block.center { return block.insert }
    return fallback
  }
}

// MARK: - Mise en page

/// La mise en page d'un réordonnancement EN COURS : de combien chaque ligne restante se décale, et
/// où se dessine le trou d'insertion.
///
/// Deux termes se cumulent, et ils sont indépendants l'un de l'autre :
///
/// - **le repli** (`collapse`) — un groupe qui voyage réduit à sa seule première ligne (une en-tête
///   qui emmène son bloc, un projet qui emmène ses listes) libère de la hauteur. TOUTES les lignes
///   qui étaient sous lui remontent d'autant. Vaut 0 quand le groupe ne se replie pas (une tâche
///   seule, une liste seule) et le terme disparaît alors de lui-même : aucun cas particulier ;
/// - **l'écartement** (`unit`) — les lignes situées ENTRE l'ancienne place du groupe et sa nouvelle
///   glissent d'une hauteur de groupe, dans le sens qui ouvre le trou. Celles hors de cet intervalle
///   ne bougent pas.
///
/// C'est cette formulation « positions de repos + décalage » — et non un ré-empilement contigu — qui
/// rend le calcul indifférent au TYPE des lignes traversées. Une tâche, une en-tête, un champ
/// « Nouvelle tâche », une rangée « + Nouvelle liste » : seule compte leur POSITION dans la
/// séquence. C'est aussi ce qui garantit la continuité au drop — la position affichée pendant le
/// glissement EST la position réelle une fois l'ordre écrit, donc le décalage retombe à 0 sans saut.
struct ReorderLayout<Key: Hashable> {
  /// Les lignes restantes, dans l'ordre d'affichage. Le groupe tiré n'y est pas.
  let others: [Key]
  /// Index, dans `others`, de la place qu'occupait le groupe avant l'empoignade.
  let origin: Int
  /// Index, dans `others`, où il se posera. Toujours dans `0...others.count`.
  let insert: Int
  /// Hauteur de ce qui VOYAGE (la première ligne du groupe) : ce dont les voisines s'écartent.
  let unit: CGFloat
  /// Hauteur que le groupe PERD en se repliant sous le curseur. 0 s'il ne se replie pas.
  let collapse: CGFloat

  /// Les deux index sont bornés ICI, une fois pour toutes. Chaque appelant le faisait de son côté
  /// (`min(insert, others.count)`), donc chacun pouvait l'oublier — et un `others[insert]` en aval
  /// n'aurait rien pardonné.
  init(others: [Key], origin: Int, insert: Int, unit: CGFloat, collapse: CGFloat = 0) {
    self.others = others
    self.origin = min(max(origin, 0), others.count)
    self.insert = min(max(insert, 0), others.count)
    self.unit = unit
    self.collapse = collapse
  }

  /// Décalage vertical de la ligne d'index `index` dans `others`.
  func shift(at index: Int) -> CGFloat {
    let fold: CGFloat = index >= origin ? -collapse : 0
    let gap: CGFloat
    if insert < origin, (insert..<origin).contains(index) {
      gap = unit
    } else if insert > origin, (origin..<insert).contains(index) {
      gap = -unit
    } else {
      gap = 0
    }
    return fold + gap
  }

  /// Le décalage de CHAQUE ligne restante, en un seul passage — la forme qu'attendent les vues,
  /// qui interrogent ensuite par clé à chaque rangée rendue. Un `firstIndex(of:)` par rangée
  /// coûterait un balayage quadratique à chaque image de glissement.
  func offsets() -> [Key: CGFloat] {
    var map: [Key: CGFloat] = [:]
    for (index, key) in others.enumerated() { map[key] = shift(at: index) }
    return map
  }

  /// Haut du trou d'insertion, dans le repère où les cadres ont été mesurés.
  ///
  /// Ancré au BAS de la dernière ligne MESURÉE au-dessus du trou — « mesurée », parce que toutes ne
  /// le sont pas : une page de liste garde dans `others` les tâches archivées, qui ne sont pas
  /// rendues et n'ont donc pas de cadre. Sans ce recul, déposer juste après une tâche cochée faisait
  /// disparaître le trou.
  ///
  /// `draggedTop` = haut de repos du groupe tiré. Il n'entre en jeu qu'en tête de séquence, où le
  /// trou doit se placer au-dessus de TOUT — y compris au-dessus du groupe lui-même quand c'est lui
  /// qui occupait déjà la première place.
  func placeholderTop(frames: [Key: CGRect], draggedTop: CGFloat) -> CGFloat? {
    guard insert > 0 else {
      let topmost = others.compactMap { frames[$0]?.minY }.min() ?? draggedTop
      return min(topmost, draggedTop)
    }
    guard
      let index = (0..<insert).reversed().first(where: { frames[others[$0]] != nil }),
      let frame = frames[others[index]]
    else { return nil }
    return frame.minY + shift(at: index) + frame.height
  }

  /// L'ordre atteint : le groupe réinséré parmi les autres. Aux vues d'en tirer ce qu'elles
  /// persistent (une renumérotation de `sortIndex`, et pour la sidebar un changement de parent).
  ///
  /// Générique sur l'élément et pas sur `Key` : une page de liste vise en `RowKey` (qui compte les
  /// champs « Nouvelle tâche ») mais écrit en `TaskItem`. Les deux espaces ont le même ordre relatif,
  /// c'est tout ce que cette méthode demande.
  func reordered<Element>(_ dragged: [Element], among elements: [Element]) -> [Element] {
    var result = elements
    result.insert(contentsOf: dragged, at: min(insert, result.count))
    return result
  }
}
