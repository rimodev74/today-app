import SwiftData
import XCTest

@testable import Today

/// Les cibles du « Déplacer vers… », lues une fois par page puis écartées par rangée. Ces tests
/// tiennent ce que le menu faisait avant (groupement par projet, ordre de première apparition,
/// listes libres en dernier) et l'égalité dont `TaskRow: Equatable` dépend.
final class MoveTargetsTests: XCTestCase {
  private var context: ModelContext!

  override func setUpWithError() throws {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    context = ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  private func project(_ title: String) -> Project {
    let project = Project(title: title)
    context.insert(project)
    return project
  }

  private func list(_ title: String, in project: Project? = nil) -> TodoList {
    let list = TodoList(title: title, project: project)
    context.insert(list)
    return list
  }

  private func groups(_ targets: MoveTargets) -> [String] {
    targets.byProject.map { group in
      "\(group.project ?? "-"):" + group.lists.map(\.title).joined(separator: ",")
    }
  }

  func testGroupeParProjetListesLibresEnDernier() {
    let a = project("A")
    let b = project("B")
    let lists = [list("libre1"), list("a1", in: a), list("b1", in: b), list("a2", in: a)]
    let targets = MoveTargetIndex(lists).excluding(nil)
    XCTAssertEqual(groups(targets), ["A:a1,a2", "B:b1", "-:libre1"])
  }

  func testLaListeDeLaTacheEstEcartee() {
    let a = project("A")
    let lists = [list("a1", in: a), list("a2", in: a), list("libre")]
    let targets = MoveTargetIndex(lists).excluding(lists[0].persistentModelID)
    XCTAssertEqual(targets.lists.map(\.title), ["a2", "libre"])
    XCTAssertEqual(groups(targets), ["A:a2", "-:libre"])
  }

  /// Écarter la première liste d'un projet change quel projet apparaît en premier : l'ordre suit
  /// les listes PROPOSÉES, comme avant (le groupement se faisait après le filtre).
  func testLOrdreDesProjetsSuitLesListesProposees() {
    let a = project("A")
    let b = project("B")
    let a1 = list("a1", in: a)
    let b1 = list("b1", in: b)
    let a2 = list("a2", in: a)
    let index = MoveTargetIndex([a1, b1, a2])
    XCTAssertEqual(groups(index.excluding(nil)), ["A:a1,a2", "B:b1"])
    XCTAssertEqual(groups(index.excluding(a1.persistentModelID)), ["B:b1", "A:a2"])
  }

  func testUnProjetDontToutesLesListesSontEcarteesDisparait() {
    let a = project("A")
    let a1 = list("a1", in: a)
    let libre = list("libre")
    let targets = MoveTargetIndex([a1, libre]).excluding(a1.persistentModelID)
    XCTAssertEqual(groups(targets), ["-:libre"])
  }

  func testIsEmptyQuandIlNeResteQueLaListeDeLaTache() {
    let only = list("seule")
    let index = MoveTargetIndex([only])
    XCTAssertTrue(index.excluding(only.persistentModelID).isEmpty)
    XCTAssertFalse(index.excluding(nil).isEmpty)
    XCTAssertTrue(MoveTargetIndex([]).excluding(nil).isEmpty)
  }

  /// `TaskRow.==` : même index et même liste écartée ⇒ égal ; sinon la rangée doit se rejouer.
  func testEgaliteSuitLesIdentifiantsEtLaListeEcartee() {
    let one = list("un")
    let two = list("deux")
    let index = MoveTargetIndex([one, two])
    XCTAssertEqual(index.excluding(one.persistentModelID), index.excluding(one.persistentModelID))
    XCTAssertNotEqual(
      index.excluding(one.persistentModelID), index.excluding(two.persistentModelID))
    // Un index reconstruit sur les mêmes listes vaut le précédent (la page le refait à chaque rendu).
    XCTAssertEqual(
      MoveTargetIndex([one, two]).excluding(nil), MoveTargetIndex([one, two]).excluding(nil))
    // Une liste de plus : les rangées doivent le voir.
    XCTAssertNotEqual(
      MoveTargetIndex([one, two]).excluding(nil), MoveTargetIndex([one]).excluding(nil))
  }
}
