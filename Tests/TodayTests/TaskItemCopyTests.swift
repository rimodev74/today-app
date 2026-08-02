import SwiftData
import XCTest

@testable import Today

/// Le garde-fou de `TaskItem.copy(into:)`. Trois champs ont déjà été oubliés par les chemins de
/// duplication au fil des ajouts au modèle (couleur d'en-tête, sous-tâches, durée estimée) : ce
/// test échoue au prochain oubli au lieu de le laisser passer en silence.
final class TaskItemCopyTests: XCTestCase {
  private func makeContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  /// Une tâche avec TOUS ses champs renseignés — c'est ce remplissage exhaustif qui donne sa
  /// valeur au test : un champ ajouté au modèle et pas ici passerait encore inaperçu.
  private func makeFullTask(in context: ModelContext) -> TaskItem {
    let task = TaskItem(
      title: "Appeler le client",
      notes: NotesCodec.encode(NSAttributedString(string: "avant 17 h")),
      when: Date(timeIntervalSince1970: 1_000_000),
      isHeader: true
    )
    task.deadline = Date(timeIntervalSince1970: 2_000_000)
    task.estimateMinutes = 30
    task.sortIndex = 7
    task.priority = .high
    task.headerColor = .purple
    context.insert(task)
    let sub = task.addSubtask()
    sub.title = "Préparer les chiffres"
    sub.isDone = true
    return task
  }

  func testCopy_carriesEveryField() throws {
    let context = try makeContext()
    let source = makeFullTask(in: context)
    let destination = TodoList(title: "Cible")
    context.insert(destination)

    let clone = source.copy(into: destination)
    context.insert(clone)

    XCTAssertEqual(clone.title, source.title)
    XCTAssertEqual(clone.notes, source.notes)
    XCTAssertEqual(clone.when, source.when)
    XCTAssertEqual(clone.deadline, source.deadline)
    XCTAssertEqual(clone.estimateMinutes, source.estimateMinutes)
    XCTAssertEqual(clone.sortIndex, source.sortIndex)
    XCTAssertEqual(clone.isHeader, source.isHeader)
    XCTAssertEqual(clone.priority, source.priority)
    XCTAssertEqual(clone.headerColor, source.headerColor)
    XCTAssertEqual(clone.list?.persistentModelID, destination.persistentModelID)
  }

  func testCopy_duplicatesSubtasksWithoutSharingThem() throws {
    let context = try makeContext()
    let source = makeFullTask(in: context)

    let clone = source.copy(into: nil)
    context.insert(clone)

    XCTAssertEqual(clone.orderedSubtasks.map(\.title), ["Préparer les chiffres"])
    XCTAssertEqual(clone.orderedSubtasks.map(\.isDone), [true])
    // De vraies copies : cocher côté clone ne doit rien changer à l'originale.
    clone.orderedSubtasks[0].isDone = false
    XCTAssertTrue(source.orderedSubtasks[0].isDone)
  }

  /// Une copie est une tâche À FAIRE, et un rappel Apple n'appartient qu'à une seule tâche —
  /// partager l'identifiant ferait que cocher la copie cocherait aussi l'originale.
  func testCopy_resetsCompletionAndReminderLink() throws {
    let context = try makeContext()
    let source = makeFullTask(in: context)
    source.toggleCompletion()
    source.reminderIdentifier = "REMINDER-123"

    let clone = source.copy(into: nil)
    context.insert(clone)

    XCTAssertFalse(clone.isCompleted)
    XCTAssertNil(clone.completedAt)
    XCTAssertNil(clone.reminderIdentifier)
  }
}
