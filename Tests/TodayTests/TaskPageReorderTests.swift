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

  private func frames(_ rows: [TaskItem]) -> [PersistentIdentifier: CGRect] {
    var result: [PersistentIdentifier: CGRect] = [:]
    for (index, task) in rows.enumerated() {
      result[task.persistentModelID] = CGRect(x: 0, y: CGFloat(index) * 20, width: 100, height: 20)
    }
    return result
  }

  private func armed(_ rows: [TaskItem], grabbing index: Int) -> TaskPageReorder {
    var reorder = TaskPageReorder()
    reorder.measured(frames(rows))
    reorder.begin(rows[index], in: rows)
    return reorder
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

  /// **Le gel de la séquence.** Une vue intelligente recalcule ses lignes à chaque rendu. Si le
  /// geste suivait ce recalcul, les cadres mesurés et les rangées affichées parleraient de deux
  /// listes différentes.
  func testTheSequenceIsFrozenAtGrab() {
    let rows = rows()
    var reorder = armed(rows, grabbing: 0)

    XCTAssertEqual(reorder.rows(live: []).map(\.title), ["a", "b", "c"])
    reorder.end()
    XCTAssertEqual(reorder.rows(live: []).map(\.title), [], "hors geste, c'est la liste vivante")
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
    XCTAssertEqual(offsets[rows[0].persistentModelID]?.height, 25, "la ligne tirée suit le curseur")
    XCTAssertEqual(
      offsets[rows[1].persistentModelID]?.height, -20, "la traversée remonte d'un cran")
    XCTAssertEqual(offsets[rows[2].persistentModelID]?.height, 0, "hors du trajet : immobile")
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
