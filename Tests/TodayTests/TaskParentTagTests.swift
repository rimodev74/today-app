import XCTest

@testable import Today

/// Ce que la pastille de provenance DIT, et surtout ce qu'elle tait.
///
/// La règle qui compte : la boîte de réception ne se dit pas. C'est le rangement par défaut de
/// toute tâche non classée — l'annoncer sur chaque ligne d'« Aujourd'hui » ne distingue rien. Elle
/// vivait à quatre exemplaires dans quatre vues, donc invérifiable autrement qu'en cliquant sur
/// quatre onglets.
final class TaskParentTagTests: XCTestCase {

  // MARK: Ce qui se dit

  /// La LISTE nomme, le projet teinte. Le calcul recopié dans les vues disait l'inverse : les trois
  /// listes d'un même projet annonçaient toutes le même mot, donc ne se distinguaient pas — c'est
  /// pourtant tout ce qu'on demande à une pastille de provenance.
  func testTheListNamesAndTheProjectTints() {
    let project = Project(title: "Refonte site")
    project.color = .blue
    let list = TodoList(title: "Maquettes", project: project)
    let tag = TaskParentTag(of: TaskItem(title: "Appeler le client", list: list))

    XCTAssertEqual(tag?.title, "Maquettes")
    XCTAssertEqual(tag?.color, .blue)
  }

  /// Une liste hors projet ne porte pas de couleur à elle : la pastille se peint en gris.
  func testListOutsideAProjectHasNoTint() {
    let tag = TaskParentTag(
      of: TaskItem(title: "Relire le devis", list: TodoList(title: "Clients")))

    XCTAssertEqual(tag?.title, "Clients")
    XCTAssertNil(tag?.color)
  }

  /// Un projet sans couleur choisie ne teinte rien — la liste reste nommée.
  func testProjectWithoutColourStillNamesItsList() {
    let list = TodoList(title: "Courses", project: Project(title: "Maison"))
    let tag = TaskParentTag(of: TaskItem(title: "Passer chez Léa", list: list))

    XCTAssertEqual(tag?.title, "Courses")
    XCTAssertNil(tag?.color)
  }

  // MARK: Ce qui se tait

  /// LA raison d'être de ce type.
  func testInboxSaysNothing() {
    let inbox = TodoList(title: "Boîte de réception")
    inbox.isInbox = true

    XCTAssertNil(TaskParentTag(of: TaskItem(title: "Sortir le chien", list: inbox)))
  }

  func testTaskWithoutAListSaysNothing() {
    XCTAssertNil(TaskParentTag(of: TaskItem(title: "Tâche libre")))
  }

  func testAnUnnamedListSaysNothing() {
    XCTAssertNil(TaskParentTag(of: TaskItem(title: "Sans rattachement", list: TodoList(title: ""))))
  }

  /// Un projet au titre vide ne fait pas taire la pastille : c'est la liste qui nomme.
  func testProjectWithoutATitleChangesNothing() {
    let list = TodoList(title: "Maquettes", project: Project(title: ""))

    XCTAssertEqual(TaskParentTag(of: TaskItem(title: "Cadrage", list: list))?.title, "Maquettes")
  }
}
