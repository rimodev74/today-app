import CoreGraphics
import XCTest

@testable import Today

/// L'arithmétique du réordonnancement, cas par cas.
///
/// Elle vivait dans deux `struct: View`, mêlée à `@State` et `@Query` : la seule façon de la
/// vérifier était de lancer l'app et de glisser des lignes à la main. D'où l'absence de tests sur ce
/// qui est, de loin, le code le plus intriqué de l'app — et la réticence à y toucher.
///
/// Les scénarios ci-dessous sont écrits en hauteurs rondes (lignes de 20 pt à partir de 100) pour
/// que chaque attente se lise sans calculer.
final class ReorderTests: XCTestCase {

  // MARK: Décalage des voisines

  /// Une ligne déplacée vers le BAS : celles qu'elle enjambe remontent d'une hauteur, les autres ne
  /// bougent pas. C'est tout le mécanisme, dans son cas le plus simple.
  func testMovingDownLiftsOnlyTheRowsCrossed() {
    // others = [A, B, C, D], le groupe venait de la place 1 et se pose en 3.
    let layout = ReorderLayout(
      others: ["A", "B", "C", "D"], origin: 1, insert: 3, unit: 20, collapse: 0)

    XCTAssertEqual(layout.shift(at: 0), 0, "au-dessus de l'intervalle : immobile")
    XCTAssertEqual(layout.shift(at: 1), -20, "enjambée : remonte")
    XCTAssertEqual(layout.shift(at: 2), -20, "enjambée : remonte")
    XCTAssertEqual(layout.shift(at: 3), 0, "au-delà du point de dépôt : immobile")
  }

  /// Symétrique, vers le HAUT : les lignes enjambées descendent.
  func testMovingUpPushesOnlyTheRowsCrossed() {
    let layout = ReorderLayout(
      others: ["A", "B", "C", "D"], origin: 3, insert: 1, unit: 20, collapse: 0)

    XCTAssertEqual(layout.shift(at: 0), 0)
    XCTAssertEqual(layout.shift(at: 1), 20, "enjambée : descend")
    XCTAssertEqual(layout.shift(at: 2), 20, "enjambée : descend")
    XCTAssertEqual(layout.shift(at: 3), 0)
  }

  /// Reposé à sa place : rien ne bouge. Le cas qui doit retomber à zéro exactement, sinon le drop
  /// produit un saut visible.
  func testDroppingBackHomeMovesNothing() {
    let layout = ReorderLayout(
      others: ["A", "B", "C"], origin: 1, insert: 1, unit: 20, collapse: 0)
    XCTAssertEqual(layout.offsets(), ["A": 0, "B": 0, "C": 0])
  }

  /// Un groupe qui SE REPLIE (en-tête qui emmène son bloc, projet qui emmène ses listes) libère de
  /// la hauteur : tout ce qui était sous lui remonte, même sans changer de place.
  func testCollapseLiftsEverythingBelowEvenWithoutMoving() {
    // Le groupe reste à sa place (origin == insert) mais se replie de 60 pt.
    let layout = ReorderLayout(
      others: ["A", "B", "C"], origin: 1, insert: 1, unit: 20, collapse: 60)

    XCTAssertEqual(layout.shift(at: 0), 0, "au-dessus du groupe : rien à voir avec le repli")
    XCTAssertEqual(layout.shift(at: 1), -60, "sous le groupe : remonte du repli")
    XCTAssertEqual(layout.shift(at: 2), -60)
  }

  /// Les deux termes se CUMULENT, et c'est là que les deux implémentations pouvaient diverger :
  /// une ligne sous le groupe ET enjambée par le déplacement subit les deux.
  func testCollapseAndGapAddUp() {
    let layout = ReorderLayout(
      others: ["A", "B", "C", "D"], origin: 1, insert: 3, unit: 20, collapse: 60)

    XCTAssertEqual(layout.shift(at: 0), 0, "ni sous le groupe, ni enjambée")
    XCTAssertEqual(layout.shift(at: 1), -80, "repli (-60) + écartement (-20)")
    XCTAssertEqual(layout.shift(at: 2), -80)
    XCTAssertEqual(layout.shift(at: 3), -60, "sous le groupe, mais pas enjambée : repli seul")
  }

  func testOffsetsCoverEveryRemainingRow() {
    let layout = ReorderLayout(
      others: ["A", "B", "C"], origin: 0, insert: 2, unit: 10, collapse: 0)
    XCTAssertEqual(layout.offsets(), ["A": -10, "B": -10, "C": 0])
  }

  // MARK: Bornes

  /// Un index de dépôt hors bornes ne doit jamais atteindre un `others[insert]`. Borné à la
  /// construction, pour que ni la visée ni les vues n'aient à y penser.
  func testIndicesAreClampedAtConstruction() {
    let high = ReorderLayout(others: ["A", "B"], origin: 99, insert: 99, unit: 10)
    XCTAssertEqual(high.insert, 2)
    XCTAssertEqual(high.origin, 2)

    let low = ReorderLayout(others: ["A", "B"], origin: -5, insert: -5, unit: 10)
    XCTAssertEqual(low.insert, 0)
    XCTAssertEqual(low.origin, 0)
  }

  /// Une séquence vide ne doit rien produire de spécial — le cas d'une liste dont on tire l'unique
  /// ligne.
  func testEmptyRemainderIsHarmless() {
    let layout = ReorderLayout(others: [String](), origin: 0, insert: 0, unit: 20, collapse: 0)
    XCTAssertEqual(layout.offsets(), [:])
    XCTAssertEqual(layout.placeholderTop(frames: [:], draggedTop: 100), 100)
  }

  // MARK: Trou d'insertion

  private var frames: [String: CGRect] {
    [
      "A": CGRect(x: 0, y: 100, width: 200, height: 20),
      "B": CGRect(x: 0, y: 120, width: 200, height: 20),
      "C": CGRect(x: 0, y: 140, width: 200, height: 20),
    ]
  }

  /// En tête de séquence, le trou se cale au-dessus de tout — y compris au-dessus du groupe tiré
  /// quand c'est lui qui occupait déjà la première place.
  func testPlaceholderAtTopOfList() {
    let layout = ReorderLayout(others: ["A", "B", "C"], origin: 0, insert: 0, unit: 20)
    XCTAssertEqual(layout.placeholderTop(frames: frames, draggedTop: 80), 80)
    XCTAssertEqual(layout.placeholderTop(frames: frames, draggedTop: 300), 100)
  }

  /// Ailleurs, il s'ancre au bas de la ligne qui le précède — DÉCALÉE, puisqu'elle a déjà bougé.
  func testPlaceholderFollowsTheShiftedRowAbove() {
    // Groupe venu de 0, posé en 2 : A et B remontent de 20. Le trou suit B.
    let layout = ReorderLayout(others: ["A", "B", "C"], origin: 0, insert: 2, unit: 20)
    // B repose à 120, remonte de 20 → 100, et fait 20 de haut → le trou démarre à 120.
    XCTAssertEqual(layout.placeholderTop(frames: frames, draggedTop: 0), 120)
  }

  /// Les lignes NON MESURÉES (tâches archivées, présentes dans l'ordre mais pas rendues) sont
  /// enjambées : sans ce recul, déposer juste après une tâche cochée faisait disparaître le trou.
  func testPlaceholderSkipsUnmeasuredRows() {
    var sparse = frames
    sparse["C"] = nil  // C existe dans l'ordre mais n'est pas rendue
    let layout = ReorderLayout(others: ["A", "B", "C"], origin: 0, insert: 3, unit: 20)
    // Recule de C (non mesurée) jusqu'à B : repose à 120, remonte de 20 → 100, + 20 → 120.
    XCTAssertEqual(layout.placeholderTop(frames: sparse, draggedTop: 0), 120)
  }

  /// Rien de mesuré du tout : pas de trou à dessiner, plutôt qu'un rectangle à une position inventée.
  func testPlaceholderIsAbsentWhenNothingAboveIsMeasured() {
    let layout = ReorderLayout(others: ["A", "B"], origin: 0, insert: 2, unit: 20)
    XCTAssertNil(layout.placeholderTop(frames: [:], draggedTop: 0))
  }

  // MARK: Visée ligne à ligne

  /// Centres de repos de quatre lignes de 20 pt : 110, 130, 150, 170. Frontières : 120, 140, 160.
  private let centers: [CGFloat?] = [110, 130, 150, 170]

  func testBoundaryTargetingPicksTheSlotUnderTheCursor() {
    XCTAssertEqual(ReorderTarget.byBoundary(center: 105, centers: centers), 0, "au-dessus de tout")
    XCTAssertEqual(
      ReorderTarget.byBoundary(center: 119, centers: centers), 0, "avant la 1re frontière")
    XCTAssertEqual(ReorderTarget.byBoundary(center: 121, centers: centers), 1, "après")
    XCTAssertEqual(ReorderTarget.byBoundary(center: 141, centers: centers), 2)
    XCTAssertEqual(
      ReorderTarget.byBoundary(center: 400, centers: centers), 3,
      "sous tout : le DERNIER index de la séquence complète — cf. le pivot ci-dessous")
  }

  /// Le pivot : la ligne tirée reste dans la séquence à sa place d'origine, et c'est ce qui fait
  /// qu'on peut la reposer exactement là où on l'a prise.
  func testBoundaryTargetingReturnsHomeWhenBarelyMoved() {
    // La ligne d'index 1 (centre 130) à peine bougée vise sa propre place.
    XCTAssertEqual(ReorderTarget.byBoundary(center: 130, centers: centers), 1)
  }

  /// Le pivot, bout en bout — le raisonnement qui justifie de viser sur la séquence COMPLÈTE alors
  /// qu'on écrit dans celle sans le groupe. Quatre lignes, on tire la 2e (index 1) tout en bas :
  /// la visée rend 3, or la séquence restante n'a que 3 éléments — 3 y désigne donc la fin. Les deux
  /// espaces se recollent exactement, sans correction d'indice nulle part.
  func testBoundaryTargetingAndLayoutAgreeOnTheEnd() {
    let index = ReorderTarget.byBoundary(center: 400, centers: centers)
    let layout = ReorderLayout(
      others: ["A", "C", "D"], origin: 1, insert: index, unit: 20, collapse: 0)

    XCTAssertEqual(layout.insert, 3, "la fin de la séquence restante")
    XCTAssertEqual(layout.reordered(["B"], among: ["A", "C", "D"]), ["A", "C", "D", "B"])
  }

  /// Une ligne non mesurée ne peut pas trancher : la frontière se calcule avec la suivante qui l'est.
  func testBoundaryTargetingSkipsUnmeasuredRows() {
    let sparse: [CGFloat?] = [110, nil, 150, 170]
    // Frontière de la ligne 0 = mi-chemin avec le prochain centre MESURÉ (150) → 130.
    XCTAssertEqual(ReorderTarget.byBoundary(center: 129, centers: sparse), 0)
    XCTAssertEqual(ReorderTarget.byBoundary(center: 131, centers: sparse), 2)
  }

  func testBoundaryTargetingOnEmptySequence() {
    XCTAssertEqual(ReorderTarget.byBoundary(center: 100, centers: []), 0)
  }

  // MARK: Visée bloc à bloc

  func testBlockTargetingLandsAtTheStartOfABlock() {
    let blocks = [(insert: 0, center: CGFloat(120)), (insert: 3, center: CGFloat(200))]
    XCTAssertEqual(
      ReorderTarget.byBlockStart(center: 100, blocks: blocks, fallback: 6), 0,
      "au-dessus du 1er bloc")
    XCTAssertEqual(
      ReorderTarget.byBlockStart(center: 150, blocks: blocks, fallback: 6), 3,
      "entre les deux : au début du second")
    XCTAssertEqual(
      ReorderTarget.byBlockStart(center: 300, blocks: blocks, fallback: 6), 6,
      "sous tous les centres : à la fin")
  }

  func testBlockTargetingWithNoBlocksFallsBack() {
    XCTAssertEqual(ReorderTarget.byBlockStart(center: 100, blocks: [], fallback: 4), 4)
  }

  // MARK: Ordre obtenu

  func testReorderedInsertsTheWholeGroup() {
    let layout = ReorderLayout(others: ["A", "B", "D"], origin: 2, insert: 2, unit: 20)
    XCTAssertEqual(
      layout.reordered(["C1", "C2"], among: ["A", "B", "D"]), ["A", "B", "C1", "C2", "D"])
  }

  /// L'espace de visée peut compter plus de lignes que l'espace d'écriture (une page de liste vise
  /// en incluant les champs « Nouvelle tâche », mais n'écrit que des tâches) : la réinsertion se
  /// borne alors sur la séquence reçue, pas sur celle qui a servi à viser.
  func testReorderedClampsToTheSequenceItIsGiven() {
    let layout = ReorderLayout(others: ["A", "B", "C", "D", "E"], origin: 0, insert: 5, unit: 20)
    XCTAssertEqual(layout.reordered(["X"], among: ["A", "B"]), ["A", "B", "X"])
  }
}
