import XCTest

@testable import Today

/// Ce qui fait qu'une tâche « ne porte rien », donc qu'elle s'en va quand on referme son édition.
///
/// La règle vaut sur les trois pages qui savent créer, et elle décide d'une SUPPRESSION : chaque
/// champ qui doit la retenir a son test. En oublier un, c'est perdre le travail de quelqu'un.
final class TaskItemBlankTests: XCTestCase {
  private func fresh() -> TaskItem { TaskItem(title: "") }

  func testUneTacheNeuveSansRienEstVide() {
    XCTAssertTrue(fresh().isBlank)
  }

  func testUnTitreLaRetient() {
    XCTAssertFalse(TaskItem(title: "acheter du pain").isBlank)
  }

  /// Des espaces ne sont pas un titre : « ⌘N, espace, Échap » doit partir comme « ⌘N, Échap ».
  func testUnTitreDEspacesNeLaRetientPas() {
    XCTAssertTrue(TaskItem(title: "   \n  ").isBlank)
  }

  // MARK: Tout ce qui doit la retenir

  func testDesNotesLaRetiennent() {
    let task = fresh()
    task.notes = NotesCodec.encode(NSAttributedString(string: "une pensée"))
    XCTAssertFalse(task.isBlank)
  }

  func testUneSousTacheLaRetient() {
    let task = fresh()
    task.addSubtask()
    XCTAssertFalse(task.isBlank)
  }

  func testUneEcheanceLaRetient() {
    let task = fresh()
    task.deadline = Date()
    XCTAssertFalse(task.isBlank)
  }

  func testUnePrioriteLaRetient() {
    let task = fresh()
    task.priority = .high
    XCTAssertFalse(task.isBlank)
  }

  func testUneDureeEstimeeLaRetient() {
    let task = fresh()
    task.estimateMinutes = 30
    XCTAssertFalse(task.isBlank)
  }

  /// Invisible sur la ligne au repos, et pourtant : un rappel Apple a été créé pour de vrai, il ne
  /// faut pas laisser une tâche orpheline pointer dessus.
  func testUnRappelAppleLaRetient() {
    let task = fresh()
    task.reminderIdentifier = "ABC-123"
    XCTAssertFalse(task.isBlank)
  }

  func testUneTacheCocheeLaRetient() {
    let task = fresh()
    task.toggleCompletion()
    XCTAssertFalse(task.isBlank)
  }

  /// Une en-tête de section vide se renomme, elle ne se supprime pas toute seule — ce n'est pas une
  /// tâche, et elle structure la liste même sans titre.
  func testUneEnTeteNestJamaisVide() {
    XCTAssertFalse(TaskItem(title: "", isHeader: true).isBlank)
  }

  // MARK: Le cas qui a demandé une décision

  /// `when` ne compte PAS : « Aujourd'hui » date ses tâches d'office à la création, sinon la tâche
  /// neuve ne s'afficherait pas sur la page qui vient de la créer. Une date seule ne prouve donc
  /// rien sur ce qu'on a saisi.
  func testUneDateSeuleNeLaRetientPas() {
    let task = fresh()
    task.when = Date()
    XCTAssertTrue(task.isBlank)
  }

  /// Mais dès qu'il y a un titre, la date ne change évidemment rien.
  func testUneTacheDateeAvecUnTitreReste() {
    XCTAssertFalse(TaskItem(title: "réunion", when: Date()).isBlank)
  }
}
