import XCTest

@testable import Today

/// L'ordre manuel des vues intelligentes : ce qu'on a posé à la main passe avant ce que la règle
/// automatique range.
///
/// La règle vaut surtout par ce qu'elle promet à une base EXISTANTE : personne n'a jamais glissé
/// quoi que ce soit, tout vaut 0, et l'ordre affiché doit être exactement celui d'avant. Un défaut
/// mal choisi ici aurait rebattu 86 tâches réelles au premier lancement, sans rien casser de
/// visible au compilateur.
final class SmartOrderTests: XCTestCase {
  private func task(_ title: String, priority: Priority = .none, smartOrder: Int = 0) -> TaskItem {
    let item = TaskItem(title: title)
    item.priority = priority
    item.smartOrder = smartOrder
    return item
  }

  /// Le cas de toutes les bases d'avant : rien n'a été posé, la règle automatique gouverne seule.
  func testUntouchedTasksKeepTheAutomaticOrder() {
    let basse = task("basse")
    let haute = task("haute", priority: .high)

    XCTAssertEqual(SmartList.today.sort([basse, haute]).map(\.title), ["haute", "basse"])
  }

  /// Ce qui compte : l'ordre manuel bat la priorité, sinon glisser ne servirait à rien sur une
  /// page où une tâche « importante » remonterait aussitôt.
  func testManualOrderBeatsPriority() {
    let haute = task("haute", priority: .high, smartOrder: 2)
    let basse = task("basse", smartOrder: 1)

    XCTAssertEqual(SmartList.today.sort([haute, basse]).map(\.title), ["basse", "haute"])
  }

  /// Une tâche qui ARRIVE sur la page n'a jamais été posée : elle se range après celles qui l'ont
  /// été, à l'endroit que la règle automatique lui donne — elle ne s'invite pas en tête.
  func testNewcomersLandAfterWhatWasPlacedByHand() {
    let posee = task("posée", smartOrder: 1)
    let arrivante = task("arrivante", priority: .high)

    XCTAssertEqual(SmartList.today.sort([arrivante, posee]).map(\.title), ["posée", "arrivante"])
  }

  /// Poser un ordre l'écrit sur TOUTE la séquence : sans ça les voisines de la tâche déplacée
  /// garderaient 0 et repartiraient au tri automatique, donc devant elle.
  func testStampingNumbersTheWholeSequenceFromOne() {
    let a = task("a")
    let b = task("b")
    let c = task("c")

    TaskItem.stampSmartOrder([c, a, b])

    XCTAssertEqual([c.smartOrder, a.smartOrder, b.smartOrder], [1, 2, 3])
    XCTAssertEqual(SmartList.today.sort([a, b, c]).map(\.title), ["c", "a", "b"])
  }

  /// 0 est réservé à « jamais posée » : une tâche posée en tête ne doit pas le recevoir, sinon
  /// elle retomberait dans le tri automatique au tour suivant.
  func testStampingNeverAssignsZero() {
    let a = task("a")
    TaskItem.stampSmartOrder([a])
    XCTAssertNotEqual(a.smartOrder, 0)
  }
}
