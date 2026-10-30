import SwiftData
import XCTest

@testable import Today

/// Supprimer un projet ou une liste, c'est la cascade la plus profonde de l'app : projet → listes →
/// tâches → sous-tâches. Avec un `UndoManager` branché sur le contexte — ce que fait `ContentView`
/// pour que ⌘Z atteigne la pile de la FENÊTRE — SwiftData tombait pendant l'enregistrement :
///
///     SwiftData/DataUtilities.swift:541: Fatal error:
///     A snapshot should exist before creating a new snapshot for undo
///
/// Deux conditions, et il faut les DEUX : un manager branché, et des objets relus DU DISQUE (donc
/// sans instantané en mémoire). D'où le `save` + réouverture au milieu de chaque test — construire
/// et supprimer dans la même session ne reproduit rien.
final class CascadeDeleteTests: XCTestCase {
  private var storeURL: URL!

  override func setUpWithError() throws {
    storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("cascade-\(UUID().uuidString).store")
  }

  override func tearDownWithError() throws {
    for suffix in ["", "-shm", "-wal"] {
      try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
    }
  }

  private func openContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    return ModelContext(
      try ModelContainer(
        for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL)))
  }

  /// Sème, enregistre, puis REND UN CONTEXTE NEUF sur les mêmes octets : c'est la relecture depuis
  /// le disque qui met SwiftData dans l'état où l'annulation le faisait tomber.
  private func seedThenReopen() throws -> ModelContext {
    let seeding = try openContext()
    let project = Project(title: "P")
    seeding.insert(project)
    for l in 0..<3 {
      let list = project.appendList(titled: "L\(l)", in: seeding)
      for t in 0..<4 {
        let task = TaskItem(title: "T\(l)-\(t)")
        task.list = list
        seeding.insert(task)
        for _ in 0..<3 { _ = task.addSubtask() }
      }
    }
    try seeding.save()

    let reopened = try openContext()
    reopened.undoManager = UndoManager()
    return reopened
  }

  func testDeleteProject_withUndoManager_cascadesWithoutCrashing() throws {
    let ctx = try seedThenReopen()
    let project = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Project>()).first)

    ctx.deleteCascadeAndSave(project)

    XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Project>()), 0)
    XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TodoList>()), 0)
    XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TaskItem>()), 0)
    XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Subtask>()), 0)
  }

  func testDeleteList_withUndoManager_cascadesWithoutCrashing() throws {
    let ctx = try seedThenReopen()
    let list = try XCTUnwrap(try ctx.fetch(FetchDescriptor<TodoList>()).first)

    ctx.deleteCascadeAndSave(list)

    XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TodoList>()), 2)
    XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TaskItem>()), 8)
    XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Subtask>()), 24)
  }

  /// Le manager doit être RENDU au contexte : le débranchement ne vaut que pour la cascade, sinon
  /// ⌘Z ne marcherait plus nulle part après la première suppression de projet.
  func testUndoManagerIsRestored_andItsStackIsCleared() throws {
    let ctx = try seedThenReopen()
    let manager = try XCTUnwrap(ctx.undoManager)
    let task = try XCTUnwrap(try ctx.fetch(FetchDescriptor<TaskItem>()).first)
    task.title = "modifiée"
    try ctx.save()
    XCTAssertTrue(manager.canUndo, "SwiftData enregistre bien dans la pile de la fenêtre")

    let project = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Project>()).first)
    ctx.deleteCascadeAndSave(project)

    XCTAssertIdentical(ctx.undoManager, manager)
    XCTAssertFalse(manager.canUndo, "la pile parlait d'objets que la cascade vient d'effacer")
  }

  /// Le chemin de la synchro Rappels, reproduit à l'identique : une tâche sortie d'un FETCH, dont
  /// on lit les propriétés que `RemindersSync.shouldDelete` consulte — et RIEN d'autre. Ses
  /// sous-tâches ne sont jamais lues, personne n'a rendu sa ligne.
  ///
  /// C'est le cas qui manquait à ce fichier le 6 août 2026, et il tombait : lire la tâche ne suffit
  /// pas, ce sont les instantanés des SOUS-TÂCHES qui manquent à l'annulation. Une tâche à
  /// sous-tâches dont le rappel disparaissait faisait tomber le processus.
  ///
  /// D'où `deleteCascadeAndSave` dans `ContentView.deleteTasksWhoseReminderIsGone`, alors qu'il ne
  /// s'agit que d'une tâche. Ce test échoue si quelqu'un le ramène à `delete` + `save` en se fiant
  /// à « une tâche, ça ne cascade pas assez pour casser ».
  func testSuppressionHorsAffichage_passeParLaCascade() throws {
    let ctx = try seedThenReopen()
    let fetched = try ctx.fetch(FetchDescriptor<TaskItem>())
    for task in fetched {
      _ = task.title
      _ = task.isCompleted
      _ = task.when
      _ = task.reminderIdentifier
      _ = task.isHeader
    }

    let doomed = try XCTUnwrap(fetched.first)
    ctx.deleteCascadeAndSave(doomed)

    XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TaskItem>()), 11)
    XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Subtask>()), 33)
  }

  /// L'ORDRE de `deleteTasksAndSave` : les identifiants sont lus avant la suppression, et les
  /// rappels effacés APRÈS l'enregistrement. Inversé, c'est la bombe des cinq pages — EventKit qui
  /// écrit au milieu d'une mutation SwiftData (cf. l'en-tête du helper).
  ///
  /// La boucle de lecture n'est PAS décorative. Mesuré le 6 août 2026 en écrivant ce test :
  /// supprimer, manager branché, une tâche qu'on vient de relire du disque **sans jamais lire une
  /// seule de ses propriétés** fait tomber la même assertion que la cascade d'un projet. Lire ses
  /// propriétés d'abord suffit à l'éviter — c'est l'instantané qui manquait. Dans l'app, toute ligne
  /// supprimable a d'abord été RENDUE, donc lue ; c'est ce qui met ⌫ hors de portée du défaut, et
  /// non la taille de la cascade.
  func testDeleteTasksAndSave_forgetsRemindersAfterTheStoreIsWritten() throws {
    let ctx = try seedThenReopen()
    let all = try ctx.fetch(FetchDescriptor<TaskItem>())
    for task in all {
      _ = task.title
      for subtask in task.subtasks { _ = subtask.title }
    }
    let tasks = Array(all.prefix(2))
    for (i, task) in tasks.enumerated() { task.reminderIdentifier = "R\(i)" }
    try ctx.save()

    var forgotten: [String] = []
    var remainingWhenForgetting = -1
    ctx.deleteTasksAndSave(tasks) { ids in
      forgotten = ids
      remainingWhenForgetting = (try? ctx.fetchCount(FetchDescriptor<TaskItem>())) ?? -1
    }

    XCTAssertEqual(forgotten.sorted(), ["R0", "R1"], "identifiants lus avant la suppression")
    XCTAssertEqual(remainingWhenForgetting, 10, "SwiftData a fini quand EventKit commence")
  }

  // MARK: Un enregistrement raté n'efface RIEN côté Apple

  /// Un contexte sur la même base, mais qui REFUSE d'enregistrer : la façon la plus sûre de faire
  /// échouer `save()` sans abîmer le disque.
  private func readOnlyContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    return ModelContext(
      try ModelContainer(
        for: schema,
        configurations: ModelConfiguration(schema: schema, url: storeURL, allowsSave: false)))
  }

  /// `try? save()` puis `forget` quand même : la tâche restait sur le disque, son rappel partait.
  /// Raté, l'enregistrement ne fait RIEN effacer côté Apple tout de suite — seulement au prochain
  /// enregistrement réussi, et pour les tâches encore supprimées à ce moment-là.
  ///
  /// Pas de `rollback()` attendu : il fait tomber SwiftData ou laisse un état incohérent (mesuré,
  /// cf. `ModelContext.saveReportingSuccess`). La suppression reste en attente.
  func testDeleteTasksAndSave_failedSave_forgetsOnlyAfterTheNextSuccessfulSave() throws {
    _ = try seedThenReopen()
    let ctx = try readOnlyContext()
    let tasks = Array(try ctx.fetch(FetchDescriptor<TaskItem>()).prefix(2))
    for (i, task) in tasks.enumerated() { task.reminderIdentifier = "R\(i)" }

    var forgotten: [String]?
    let saved = ctx.deleteTasksAndSave(tasks) { forgotten = $0 }

    XCTAssertFalse(saved)
    XCTAssertNil(forgotten, "rien effacé côté Apple tant que le disque relie la tâche au rappel")
    XCTAssertTrue(ctx.hasChanges, "la suppression attend le prochain enregistrement")

    // Le prochain enregistrement réussi (ici simulé : ce contexte refuse d'enregistrer).
    NotificationCenter.default.post(name: ModelContext.didSave, object: ctx)
    XCTAssertEqual(forgotten?.sorted(), ["R0", "R1"])

    forgotten = nil
    NotificationCenter.default.post(name: ModelContext.didSave, object: ctx)
    XCTAssertNil(forgotten, "une fois, puis l'observateur s'en va")
  }

  /// La cascade en attente sera écrite par l'autosave : le manager ne revient qu'APRÈS, sans quoi
  /// cet enregistrement-là serait le plantage que le helper évite.
  func testDeleteCascadeAndSave_failedSave_keepsUndoDetachedUntilTheNextSave() throws {
    _ = try seedThenReopen()
    let ctx = try readOnlyContext()
    let manager = UndoManager()
    ctx.undoManager = manager
    let project = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Project>()).first)

    XCTAssertFalse(ctx.deleteCascadeAndSave(project))
    XCTAssertNil(ctx.undoManager)

    NotificationCenter.default.post(name: ModelContext.didSave, object: ctx)
    XCTAssertTrue(ctx.undoManager === manager)
  }

  func testDeleteTasksAndSave_success_reportsTrue() throws {
    let ctx = try seedThenReopen()
    let task = try XCTUnwrap(try ctx.fetch(FetchDescriptor<TaskItem>()).first)
    _ = task.title
    for subtask in task.subtasks { _ = subtask.title }
    XCTAssertTrue(ctx.deleteTasksAndSave([task]) { _ in })
  }

  /// Ce que `RemindersSyncPass.isGone` lit après chaque `await` : une tâche supprimée — avant comme
  /// après l'enregistrement — doit se reconnaître, sans quoi la passe écrirait l'identifiant d'un
  /// rappel neuf sur un objet effacé.
  func testADeletedTaskIsRecognisable_beforeAndAfterSave() throws {
    let ctx = try openContext()
    let task = TaskItem(title: "T")
    ctx.insert(task)
    try ctx.save()

    ctx.delete(task)
    XCTAssertTrue(task.isDeleted || task.modelContext == nil, "avant l'enregistrement")
    try ctx.save()
    XCTAssertTrue(task.isDeleted || task.modelContext == nil, "après l'enregistrement")
  }
}
