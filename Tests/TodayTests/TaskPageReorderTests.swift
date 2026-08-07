import SwiftData
import XCTest

@testable import Today

/// Le moteur du glissement d'une page de tâches : ce qu'il gèle, ce qu'il vise, ce qu'il rend.
///
/// Ces règles ne se voient pas à l'écran quand elles sont justes, et se lisent comme « le glisser
/// est cassé » quand elles ne le sont pas. Trois d'entre elles ont chacune coûté un aller-retour de
/// vérification manuelle : le gel des cadres, le gel de la séquence, et la visée par frontières.
final class TaskPageReorderTests: XCTestCase {
  /// Trois lignes de 20 pt de haut, empilées : centres à 10, 30 et 50.
  private func rows() -> [TaskItem] {
    [TaskItem(title: "a"), TaskItem(title: "b"), TaskItem(title: "c")]
  }

  private func frames(_ rows: [TaskItem]) -> [TaskRowKey: CGRect] {
    var result: [TaskRowKey: CGRect] = [:]
    for (index, task) in rows.enumerated() {
      result[.task(task.persistentModelID)] = CGRect(
        x: 0, y: CGFloat(index) * 20, width: 100, height: 20)
    }
    return result
  }

  private func armed(_ rows: [TaskItem], grabbing index: Int) -> TaskPageReorder {
    var reorder = TaskPageReorder()
    reorder.measured(frames(rows))
    reorder.begin(rows[index], in: rows)
    return reorder
  }

  // MARK: Ce qui VOYAGE — une ligne, ou un bloc entier

  /// Cinq lignes, pour avoir de la place de part et d'autre d'un groupe de deux.
  private func longRows() -> [TaskItem] {
    ["a", "b", "c", "d", "e"].map { TaskItem(title: $0) }
  }

  /// Un groupe part d'un bloc : la ligne empoignée EN TÊTE, ses passagères derrière. C'est ce que
  /// fait une en-tête de section, qui emporte les tâches qui la suivent.
  private func armedGroup(_ rows: [TaskItem], grabbing range: Range<Int>) -> TaskPageReorder {
    var reorder = TaskPageReorder()
    reorder.measured(frames(rows))
    reorder.begin(Array(rows[range]), in: rows)
    return reorder
  }

  /// La distinction que la page utilise pour estomper le reste d'un bloc : la ligne TIRÉE suit le
  /// curseur, ses passagères sont EMPORTÉES. Les confondre montrerait la pilule et la rangée.
  func testTheGrabbedRowAndItsPassengersAreDistinct() {
    let rows = longRows()
    let reorder = armedGroup(rows, grabbing: 1..<3)

    XCTAssertTrue(reorder.isDragging(rows[1]), "la ligne empoignée est celle qu'on tire")
    XCTAssertFalse(reorder.isDragging(rows[2]), "une passagère n'est pas la ligne tirée")
    XCTAssertTrue(reorder.carries(rows[2]), "mais elle est bien emportée")
    XCTAssertFalse(reorder.carries(rows[3]), "et une voisine ne l'est pas")
  }

  /// **Tout le groupe suit le curseur.** Une passagère laissée à son décalage d'écartement se
  /// détacherait du bloc qu'elle est censée accompagner.
  func testEveryCarriedRowFollowsTheCursor() {
    let rows = longRows()
    var reorder = armedGroup(rows, grabbing: 0..<2)
    reorder.drag(CGSize(width: 0, height: 45))

    let offsets = reorder.offsets()
    XCTAssertEqual(offsets[.task(rows[0].persistentModelID)]?.height, 45)
    XCTAssertEqual(offsets[.task(rows[1].persistentModelID)]?.height, 45)
  }

  /// **La place libérée est celle du groupe ENTIER**, pas de la seule ligne tirée : `others` doit
  /// l'écarter en bloc, sinon une passagère se retrouve comptée deux fois et l'ordre obtenu la
  /// duplique ou la perd.
  func testTheWholeGroupIsRemovedFromTheRemainingRows() {
    let rows = longRows()
    var reorder = armedGroup(rows, grabbing: 0..<2)
    // Assez bas pour viser après « d » : centres à 10, 30, 50, 70, 90.
    reorder.drag(CGSize(width: 0, height: 65))

    let dropped = reorder.dropped()?.map(\.title)
    XCTAssertEqual(dropped?.count, rows.count, "aucune ligne ne doit être perdue ni dupliquée")
    XCTAssertEqual(dropped, ["c", "d", "a", "b", "e"])
  }

  /// Le groupe reste d'un seul tenant, et dans son ordre — un bloc déposé en désordre serait pire
  /// que pas de déplacement du tout.
  func testTheGroupStaysContiguousAndOrdered() {
    let rows = longRows()
    var reorder = armedGroup(rows, grabbing: 2..<5)
    reorder.drag(CGSize(width: 0, height: -45))

    let dropped = reorder.dropped()?.map(\.title)
    XCTAssertEqual(dropped, ["c", "d", "e", "a", "b"])
  }

  /// Le cas dégénéré, qui est celui des trois pages simples : un groupe d'UNE ligne se comporte
  /// exactement comme avant la généralisation.
  func testASingleRowBehavesAsBefore() {
    let rows = longRows()
    var solo = armedGroup(rows, grabbing: 1..<2)
    var legacy = armed(rows, grabbing: 1)
    solo.drag(CGSize(width: 0, height: 45))
    legacy.drag(CGSize(width: 0, height: 45))

    XCTAssertEqual(solo.dropped()?.map(\.title), legacy.dropped()?.map(\.title))
    XCTAssertEqual(solo.offsets().count, legacy.offsets().count)
  }

  // MARK: Deux espaces — les lignes physiques, et les tâches seules

  /// Une page de liste miniature : deux blocs, chacun terminé par sa rangée « Nouvelle tâche ».
  /// Cinq lignes physiques de 20 pt (centres 10, 30, 50, 70, 90), mais seulement TROIS tâches.
  ///
  ///     .task(a)   0..20
  ///     .task(b)   20..40
  ///     .field(A)  40..60
  ///     .task(c)   60..80
  ///     .field(B)  80..100
  private func pageWithFields() -> (
    tasks: [TaskItem], physical: [TaskRowKey], frames: [TaskRowKey: CGRect]
  ) {
    let tasks = ["a", "b", "c"].map { TaskItem(title: $0) }
    let physical: [TaskRowKey] = [
      .task(tasks[0].persistentModelID), .task(tasks[1].persistentModelID), .field("A"),
      .task(tasks[2].persistentModelID), .field("B"),
    ]
    var frames: [TaskRowKey: CGRect] = [:]
    for (index, key) in physical.enumerated() {
      frames[key] = CGRect(x: 0, y: CGFloat(index) * 20, width: 100, height: 20)
    }
    return (tasks, physical, frames)
  }

  private func armedPage() -> (TaskPageReorder, [TaskItem]) {
    let page = pageWithFields()
    var reorder = TaskPageReorder()
    reorder.measured(page.frames)
    reorder.begin([page.tasks[0]], in: page.tasks, physical: page.physical)
    // « a » descend sous « b » : centre 10 + 25 = 35, au-delà de la frontière a|b (20).
    reorder.drag(CGSize(width: 0, height: 25))
    return (reorder, page.tasks)
  }

  /// **Un champ s'écarte comme une tâche.** C'est tout l'objet du second espace : il occupe de la
  /// hauteur, donc une ligne qui le traverse doit le pousser. Le laisser immobile ouvrirait un trou
  /// d'une hauteur de ligne de moins que celle qu'on transporte.
  func testACreationFieldStepsAsideLikeATask() {
    let (reorder, _) = armedPage()
    let offsets = reorder.offsets()

    XCTAssertEqual(offsets[.field("A")]?.height, -20, "le champ du bloc traversé remonte")
    XCTAssertEqual(offsets[.field("B")]?.height, 0, "celui d'un bloc non traversé ne bouge pas")
  }

  /// L'ordre ÉCRIT, lui, ne connaît que les tâches : `sortIndex` n'en numérote pas d'autres, et un
  /// champ n'a rien à faire dans la séquence persistée.
  func testTheWrittenOrderIgnoresFields() {
    let (reorder, tasks) = armedPage()

    XCTAssertEqual(reorder.dropped()?.map(\.title), ["b", "a", "c"])
    XCTAssertEqual(reorder.dropped()?.count, tasks.count, "aucun champ ne s'invite dans l'ordre")
  }

  /// Le cas des quatre pages intelligentes : sans séquence physique, il n'y a qu'un espace et les
  /// deux mises en page sont la même. C'est ce qui leur permet d'ignorer complètement ce mécanisme.
  func testWithoutAPhysicalSequenceBothLayoutsAreTheSame() {
    let rows = rows()
    var reorder = armed(rows, grabbing: 0)
    reorder.drag(CGSize(width: 0, height: 25))

    XCTAssertEqual(reorder.rowLayout()?.others, reorder.layout()?.others)
    XCTAssertEqual(reorder.rowLayout()?.insert, reorder.layout()?.insert)
  }

  // MARK: Un BLOC qui voyage — visée bloc à bloc, et repli

  /// Deux blocs de section, cinq lignes de 20 pt (centres 10, 30, 50, 70, 90) :
  ///
  ///     hA (en-tête)  0..20     ┐ bloc A
  ///     a1           20..40     │
  ///     a2           40..60     ┘
  ///     hB (en-tête) 60..80     ┐ bloc B
  ///     b1           80..100    ┘
  private func blocks() -> [TaskItem] {
    [
      TaskItem(title: "hA", isHeader: true), TaskItem(title: "a1"), TaskItem(title: "a2"),
      TaskItem(title: "hB", isHeader: true), TaskItem(title: "b1"),
    ]
  }

  /// Empoigne le bloc A (en-tête + ses deux tâches). Le bloc B est le seul candidat : son pavé
  /// s'étend de 60 à 100, centre 80, dont on retire le repli du bloc tiré (60 − 20 = 40) puisqu'il
  /// est SOUS lui. Frontière effective : 40.
  private func armedBlock(_ rows: [TaskItem]) -> TaskPageReorder {
    var reorder = TaskPageReorder()
    reorder.measured(frames(rows))
    reorder.begin(
      Array(rows[0..<3]), in: rows,
      blocks: .init(candidates: [.init(insert: 0, center: 40)], collapse: 40))
    return reorder
  }

  /// **On se pose au DÉBUT d'un bloc, jamais au milieu.** Le bloc A passe sous le bloc B d'un seul
  /// tenant : il ne peut pas s'insérer entre `hB` et `b1`.
  func testABlockLandsAtTheStartOfAnotherBlock() {
    let rows = blocks()
    var reorder = armedBlock(rows)
    reorder.drag(CGSize(width: 0, height: 45))  // centre 10 + 45 = 55, au-delà de 40

    XCTAssertEqual(reorder.dropped()?.map(\.title), ["hB", "b1", "hA", "a1", "a2"])
  }

  /// Sous la frontière du bloc candidat, rien ne bouge — même en ayant déjà traversé des tâches.
  /// C'est toute la différence avec une visée ligne à ligne.
  func testStayingAboveTheBlockBoundaryKeepsTheOrder() {
    let rows = blocks()
    var reorder = armedBlock(rows)
    reorder.drag(CGSize(width: 0, height: 20))  // centre 30, sous 40

    XCTAssertEqual(reorder.dropped()?.map(\.title), ["hA", "a1", "a2", "hB", "b1"])
  }

  /// **Le repli, à lui seul, fait remonter ce qui était dessous.** Dès l'empoignade et sans avoir
  /// bougé d'un point : le bloc se réduit à son en-tête, les 40 pt de ses tâches sont rendus.
  func testFoldingAloneLiftsWhatWasBelow() {
    let rows = blocks()
    var reorder = armedBlock(rows)
    reorder.drag(.zero)

    XCTAssertEqual(reorder.offsets()[.task(rows[3].persistentModelID)]?.height, -40)
  }

  /// Et quand le bloc passe dessous, les deux termes s'ajoutent : le repli (40) plus l'écartement
  /// d'une hauteur d'en-tête (20).
  func testFoldingAndSteppingAsideAddUp() {
    let rows = blocks()
    var reorder = armedBlock(rows)
    reorder.drag(CGSize(width: 0, height: 45))

    XCTAssertEqual(reorder.offsets()[.task(rows[3].persistentModelID)]?.height, -60)
    XCTAssertEqual(reorder.offsets()[.task(rows[4].persistentModelID)]?.height, -60)
  }

  // MARK: Ce qui est gelé

  /// **Le gel des cadres.** `frame(in:)` inclut le décalage appliqué aux lignes tirées : accepter
  /// une nouvelle mesure en cours de geste, c'est réinjecter le décalage dans le calcul qui le
  /// produit. La boucle se voit à l'écran comme une saccade.
  func testMeasurementsAreIgnoredWhileDragging() {
    let rows = rows()
    var reorder = armed(rows, grabbing: 0)
    let before = reorder.frames

    reorder.measured([:])

    XCTAssertEqual(
      reorder.frames.count, before.count, "une mesure en cours de geste doit être ignorée")
  }

  /// **Le gel de la séquence.** Une vue intelligente recalcule ses lignes à chaque rendu ; le
  /// calcul du geste, lui, s'appuie sur la copie prise à l'empoignade — pas sur une liste qui
  /// pourrait changer sous lui.
  func testTheSequenceIsFrozenAtGrab() {
    let rows = rows()
    var reorder = armed(rows, grabbing: 0)

    XCTAssertEqual(reorder.rows.map(\.title), ["a", "b", "c"])
    reorder.end()
    XCTAssertTrue(reorder.rows.isEmpty, "hors geste, il n'y a rien à figer")
  }

  // MARK: Où la ligne se pose

  func testDroppingWithoutMovingKeepsTheOrder() {
    let rows = rows()
    var reorder = armed(rows, grabbing: 0)
    reorder.drag(.zero)

    XCTAssertEqual(reorder.dropped()?.map(\.title), ["a", "b", "c"])
  }

  /// Descendre d'un cran : il faut franchir la FRONTIÈRE entre deux lignes, pas seulement effleurer
  /// la suivante. Ici la ligne « a » (centre 10) doit dépasser 20 pour passer sous « b ».
  func testDraggingPastTheBoundaryMovesOneStep() {
    let rows = rows()
    var reorder = armed(rows, grabbing: 0)

    reorder.drag(CGSize(width: 0, height: 5))
    XCTAssertEqual(reorder.dropped()?.map(\.title), ["a", "b", "c"], "sous la frontière : rien")

    reorder.drag(CGSize(width: 0, height: 15))
    XCTAssertEqual(reorder.dropped()?.map(\.title), ["b", "a", "c"])
  }

  func testDraggingToTheBottomPutsTheRowLast() {
    let rows = rows()
    var reorder = armed(rows, grabbing: 0)
    reorder.drag(CGSize(width: 0, height: 100))

    XCTAssertEqual(reorder.dropped()?.map(\.title), ["b", "c", "a"])
  }

  func testDraggingToTheTopPutsTheRowFirst() {
    let rows = rows()
    var reorder = armed(rows, grabbing: 2)
    reorder.drag(CGSize(width: 0, height: -100))

    XCTAssertEqual(reorder.dropped()?.map(\.title), ["c", "a", "b"])
  }

  // MARK: Les décalages, c'est-à-dire ce que l'œil voit

  /// La ligne tirée suit le curseur ; les lignes traversées s'écartent d'une hauteur de ligne pour
  /// ouvrir le trou. C'est ce qui fait que l'affiché EST le résultat, donc que rien ne saute au
  /// relâchement.
  func testNeighboursStepAsideByOneRow() {
    let rows = rows()
    var reorder = armed(rows, grabbing: 0)
    reorder.drag(CGSize(width: 0, height: 25))

    let offsets = reorder.offsets()
    XCTAssertEqual(
      offsets[.task(rows[0].persistentModelID)]?.height, 25, "la ligne tirée suit le curseur")
    XCTAssertEqual(
      offsets[.task(rows[1].persistentModelID)]?.height, -20, "la traversée remonte d'un cran")
    XCTAssertEqual(
      offsets[.task(rows[2].persistentModelID)]?.height, 0, "hors du trajet : immobile")
  }

  // MARK: Hors geste

  func testNothingIsComputedOutsideAGesture() {
    var reorder = TaskPageReorder()
    reorder.measured(frames(rows()))

    XCTAssertFalse(reorder.isDragging)
    XCTAssertTrue(reorder.offsets().isEmpty)
    XCTAssertNil(reorder.placeholder())
    XCTAssertNil(reorder.dropped())
  }

  /// Une ligne empoignée mais jamais mesurée (hors écran, pas encore rendue) ne peut rien calculer.
  /// Elle ne doit pas pour autant faire échouer le reste : le geste se contente de ne rien faire.
  func testAnUnmeasuredRowComputesNothing() {
    let rows = rows()
    var reorder = TaskPageReorder()
    reorder.begin(rows[0], in: rows)
    reorder.drag(CGSize(width: 0, height: 30))

    XCTAssertTrue(reorder.offsets().isEmpty)
    XCTAssertNil(reorder.dropped())
  }
}
