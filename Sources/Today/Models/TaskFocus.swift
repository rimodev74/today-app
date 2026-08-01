import SwiftData

/// Ce qu'une page de tâches désigne : la ligne SÉLECTIONNÉE (surbrillance lavande) et, le cas
/// échéant, celle ouverte en ÉDITION. Éditer implique sélectionner ; jamais deux lignes à la fois.
///
/// Les trois pages qui affichent des tâches — une liste, « Aujourd'hui », « Tâches » — pilotaient
/// chacune deux `@State` nus et recopiaient les cinq mêmes transitions. Elles étaient encore
/// d'accord, mais rien ne les y tenait : la première évolution un peu ambitieuse (sélection
/// multiple, annulation, navigation au clavier) devait s'écrire trois fois — ou deux, et la
/// troisième page devenait subtilement différente sans que personne ne le voie.
///
/// Type de VALEUR et non un objet observable : c'est un état de vue, il vit dans le `@State` de la
/// page qui l'affiche et meurt avec elle. Rien à partager entre pages — au contraire, chacune garde
/// sa propre sélection.
///
/// ## Ce qu'il ne fait pas
///
/// Il n'ouvre AUCUNE transaction animée. SwiftUI anime la transition d'un `@State` selon la
/// transaction ouverte au moment de L'ÉCRITURE ; or l'écriture d'un `@State` de type valeur n'a lieu
/// qu'au retour de la méthode mutante, hors de portée d'un `withAnimation` posé à l'intérieur. La
/// courbe reste donc chez l'appelant, à côté du reste de son geste — et chaque méthode dit laquelle
/// lui revient.
///
/// Il ne connaît pas non plus le premier répondeur AppKit ni la saisie rapide : ce sont des effets
/// de bord propres à chaque page, qui les enchaînent après la transition.
struct TaskFocus: Equatable {
  private(set) var selected: PersistentIdentifier?
  private(set) var editing: PersistentIdentifier?

  init() {}

  /// Rien de désigné. La garde de `dismiss` — et ce que les pages testent avant d'ouvrir une
  /// transaction pour rien.
  var isIdle: Bool { selected == nil && editing == nil }

  /// Une ligne est désignée, et aucune carte n'est ouverte. L'état où ⌫ appartient à la SÉLECTION :
  /// carte ouverte, la touche revient au champ de texte qui a le focus.
  var hasIdleSelection: Bool { selected != nil && editing == nil }

  func isSelected(_ task: TaskItem) -> Bool { selected == task.persistentModelID }
  func isEditing(_ task: TaskItem) -> Bool { editing == task.persistentModelID }

  /// Clic sur une ligne : elle devient la sélection, et toute édition en cours se referme.
  /// Courbe attendue : `taskSelectFade` — la surbrillance doit apparaître tout de suite.
  mutating func select(_ task: TaskItem) {
    editing = nil
    selected = task.persistentModelID
  }

  /// Clic sur une ligne DÉJÀ sélectionnée : sa carte d'édition s'ouvre (renommage façon Finder).
  /// Courbe attendue : `taskFlow`.
  mutating func edit(_ task: TaskItem) { edit(id: task.persistentModelID) }

  /// La même chose, par identité : une ligne qu'on vient de créer n'est rendue qu'au tour de boucle
  /// suivant, et c'est son identifiant — pas son instance — qu'on a mis de côté en attendant.
  mutating func edit(id: PersistentIdentifier) {
    selected = id
    editing = id
  }

  /// Retire la surbrillance sans rien fermer d'autre : le focus part ailleurs qu'à une ligne (le
  /// champ « Nouvelle tâche »), et laisser la lavande allumée derrière se lirait comme deux focus
  /// concurrents. Courbe attendue : `taskSelectFade`.
  mutating func deselect() { selected = nil }

  /// Fermeture demandée par une ligne précise (validation de son champ). Sans effet si ce n'est pas
  /// elle qui était ouverte — une ligne ne referme jamais la carte d'une autre.
  /// Courbe attendue : `taskFlow`.
  mutating func endEditing(_ task: TaskItem) {
    guard editing == task.persistentModelID else { return }
    editing = nil
    selected = nil
  }

  /// Fermeture globale : Échap, ou clic dans le vide de la page.
  /// Courbe attendue : `taskFlow`.
  ///
  /// Les appelants s'en gardent en amont avec `isIdle`/`isEditing(_:)` plutôt que de lire un
  /// résultat ici : ce qu'il faut éviter n'est pas la mutation (déjà idempotente) mais la
  /// TRANSACTION ANIMÉE autour d'elle. Les pages appellent depuis un moniteur qui voit TOUS les
  /// clics de la fenêtre ; ouvrir une transaction et résigner le focus à chaque appui plaçait une
  /// démission de premier répondeur ENTRE le mouseDown et le mouseUp du contrôle visé, lequel
  /// perdait le suivi de son propre clic — il fallait cliquer deux fois.
  mutating func dismiss() {
    editing = nil
    selected = nil
  }

  /// La ligne quitte la page : supprimée, ou déplacée vers une autre liste. Le focus cesse de la
  /// désigner, sans toucher à une éventuelle autre ligne désignée.
  mutating func forget(_ task: TaskItem) {
    if selected == task.persistentModelID { selected = nil }
    if editing == task.persistentModelID { editing = nil }
  }
}
