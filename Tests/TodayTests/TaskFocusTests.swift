import SwiftData
import XCTest

@testable import Today

/// Les transitions de sélection/édition d'une page de tâches.
///
/// Elles étaient recopiées dans trois pages, donc invérifiables autrement qu'en cliquant. Ici elles
/// sont écrites une fois, et chaque règle a son cas — y compris les deux `false` de garde, qui ne se
/// voient pas à l'écran mais dont dépend le fait qu'un bouton réponde au premier clic.
final class TaskFocusTests: XCTestCase {
  /// Des tâches détachées de tout store : `TaskFocus` ne manipule que des identités, il n'a jamais
  /// besoin d'un contexte.
  private let a = TaskItem(title: "A")
  private let b = TaskItem(title: "B")

  func testStartsIdle() {
    let focus = TaskFocus()
    XCTAssertTrue(focus.isIdle)
    XCTAssertFalse(focus.isSelected(a))
    XCTAssertFalse(focus.isEditing(a))
  }

  func testSelectingClosesAnyOpenEditor() {
    var focus = TaskFocus()
    focus.edit(a)
    focus.select(b)

    XCTAssertTrue(focus.isSelected(b))
    XCTAssertFalse(focus.isEditing(a), "la carte de A devait se refermer")
    XCTAssertFalse(focus.isEditing(b), "sélectionner n'ouvre pas l'édition")
  }

  func testEditingImpliesSelection() {
    var focus = TaskFocus()
    focus.edit(a)
    XCTAssertTrue(focus.isEditing(a))
    XCTAssertTrue(focus.isSelected(a), "une ligne en édition est aussi la ligne sélectionnée")
  }

  /// Une seule ligne à la fois : ouvrir la carte de B referme celle de A.
  func testOnlyOneRowIsEverOpen() {
    var focus = TaskFocus()
    focus.edit(a)
    focus.edit(b)
    XCTAssertFalse(focus.isEditing(a))
    XCTAssertTrue(focus.isEditing(b))
  }

  func testEndEditingClearsEverything() {
    var focus = TaskFocus()
    focus.edit(a)
    focus.endEditing(a)
    XCTAssertTrue(focus.isIdle)
  }

  /// Une ligne ne referme jamais la carte d'une autre.
  func testEndEditingIgnoresAnotherRow() {
    var focus = TaskFocus()
    focus.edit(a)
    focus.endEditing(b)
    XCTAssertTrue(focus.isEditing(a), "A reste ouverte")
  }

  func testDismissClearsEverything() {
    var focus = TaskFocus()
    focus.edit(a)
    focus.dismiss()
    XCTAssertTrue(focus.isIdle)
  }

  /// `dismiss` est idempotent, et `isIdle` est le prédicat par lequel les pages décident de NE PAS
  /// ouvrir de transaction animée (cf. l'en-tête de `TaskFocus.dismiss` : une résignation de focus
  /// à chaque clic de la fenêtre faisait perdre aux boutons le suivi de leur propre appui). Ce
  /// prédicat se teste ici ; la garde qui s'en sert vit dans chaque page, hors de portée d'un test
  /// unitaire.
  func testDismissIsIdempotentAndIdleIsThePredicateToGuardOn() {
    var focus = TaskFocus()
    XCTAssertTrue(focus.isIdle, "rien d'ouvert : les pages s'abstiennent d'animer")
    focus.dismiss()
    XCTAssertTrue(focus.isIdle)
  }

  func testForgettingTheDesignatedRowClearsIt() {
    var focus = TaskFocus()
    focus.edit(a)
    focus.forget(a)
    XCTAssertTrue(focus.isIdle)
  }

  /// Supprimer une AUTRE ligne ne doit pas défaire la sélection en cours.
  func testForgettingAnotherRowLeavesTheFocusAlone() {
    var focus = TaskFocus()
    focus.select(a)
    focus.forget(b)
    XCTAssertTrue(focus.isSelected(a))
  }

  /// Sélection sur A, édition sur A : `forget` doit nettoyer les DEUX, pas seulement la sélection.
  func testForgettingClearsBothRoles() {
    var focus = TaskFocus()
    focus.edit(a)
    focus.forget(a)
    XCTAssertNil(focus.selected)
    XCTAssertNil(focus.editing)
  }
}
