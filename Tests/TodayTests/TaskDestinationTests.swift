import SwiftData
import XCTest

@testable import Today

/// Une tâche rattachée à un projet SANS liste : elle vit dans l'Inbox, « Tâches » la montre avec la
/// pastille du projet, la page du projet aussi — et la ranger dans une vraie liste efface le lien.
final class TaskDestinationTests: XCTestCase {
  private var context: ModelContext!
  private var inbox: TodoList!
  private var project: Project!
  private var list: TodoList!

  override func setUpWithError() throws {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    context = ModelContext(try ModelContainer(for: schema, configurations: config))
    inbox = TodoList(title: "Tâches")
    inbox.isInbox = true
    project = Project(title: "Zen Sauna")
    project.color = .palette(.blue)
    list = TodoList(title: "Chantier", project: project)
    for model in [inbox!, list!] as [any PersistentModel] { context.insert(model) }
    context.insert(project)
  }

  private func task(_ title: String, in list: TodoList) -> TaskItem {
    let task = TaskItem(title: title, list: list)
    context.insert(task)
    return task
  }

  func testFilingToAProjectLeavesTheListForTheInbox() {
    let task = task("Devis", in: list)
    task.file(to: .project(project), in: context)

    XCTAssertTrue(task.list?.isInbox == true)
    XCTAssertTrue(task.inboxProject === project)
    XCTAssertTrue(task.project === project)
  }

  func testFilingIntoARealListDropsTheProject() {
    let task = task("Devis", in: inbox)
    task.file(to: .project(project), in: context)
    task.file(to: .list(list), in: context)

    XCTAssertTrue(task.list === list)
    XCTAssertNil(task.inboxProject)
    XCTAssertTrue(task.project === project, "le projet se lit désormais par la liste")
  }

  func testTheTasksPageShowsAttachedTasksFlatWithTheProjectPill() {
    let loose = task("Idée", in: inbox)
    let attached = task("Devis", in: inbox)
    attached.file(to: .project(project), in: context)
    let filed = task("Plan", in: list)

    let page = AllTasksPage.build(tasks: [loose, attached, filed])

    XCTAssertEqual(Set(page.tasks.map(\.title)), ["Idée", "Devis"])
    XCTAssertEqual(TaskParentTag(of: attached)?.title, "Zen Sauna")
    XCTAssertEqual(TaskParentTag(of: attached)?.color, .palette(.blue))
    XCTAssertNil(TaskParentTag(of: loose), "l'Inbox nue ne se dit toujours pas")
  }

  func testTheProjectPageShowsOnlyItsAttachedTasks() {
    let attached = task("Devis", in: inbox)
    attached.file(to: .project(project), in: context)
    _ = task("Plan", in: list)
    _ = task("Idée", in: inbox)

    XCTAssertEqual(AllTasksPage.attached(to: project).map(\.title), ["Devis"])
  }

  func testACopyInTheInboxKeepsItsProject() {
    let attached = task("Devis", in: inbox)
    attached.file(to: .project(project), in: context)

    XCTAssertTrue(attached.copy(into: inbox).inboxProject === project)
    XCTAssertNil(attached.copy(into: list).inboxProject)
  }

  /// Le cas même qui sort une tâche utile de sa liste : sa liste est la SEULE du projet, et le
  /// projet doit rester proposé (« Sans liste »).
  func testAProjectWhoseOnlyListIsTheTasksOwnStaysATarget() {
    let targets = MoveTargetIndex([inbox, list]).excluding(list.persistentModelID)
    let group = targets.byProject.first { $0.project == "Zen Sauna" }

    XCTAssertNotNil(group)
    XCTAssertTrue(group?.model === project)
    XCTAssertEqual(group?.lists.count, 0)
  }

  /// La barre du projet et sa carte dans « Projets » comptent les tâches rattachées — sinon la page
  /// affichait « Aucune tâche » au-dessus de la section qui en montrait deux.
  func testTheProjectTotalsCountAttachedTasks() {
    let attached = task("Devis", in: inbox)
    attached.file(to: .project(project), in: context)
    let done = task("Plan", in: list)
    done.isCompleted = true
    done.completedAt = Date()

    let board = ProjectBoard.build(from: project, previewLimit: 6).total
    let overview = ProjectsOverview.total(of: project)

    XCTAssertEqual(board.countable, 2)
    XCTAssertEqual(board.done, 1)
    XCTAssertEqual(overview.countable, board.countable)
    XCTAssertEqual(overview.done, board.done)
  }
}
