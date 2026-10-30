import XCTest

@testable import Today

/// La règle de fermeture de la capsule : seul Échap recule d'un cran, tout le reste ferme et garde.
final class QuickEntryCloseTests: XCTestCase {
  func testEscapeCollapsesOpenBlockFirst() {
    XCTAssertEqual(
      QuickEntryClose.outcome(discardDraft: true, blockOpen: true, onSecondStep: true),
      .collapseBlock)
  }

  func testEscapeStepsBackBeforeClosing() {
    XCTAssertEqual(
      QuickEntryClose.outcome(discardDraft: true, blockOpen: false, onSecondStep: true),
      .stepBack)
  }

  func testEscapeOnSearchClosesAndDiscards() {
    XCTAssertEqual(
      QuickEntryClose.outcome(discardDraft: true, blockOpen: false, onSecondStep: false),
      .closeDiscardingDraft)
  }

  /// Le bug : cliquer à côté pendant une saisie laissait un panneau fantôme (bloc ouvert) ou vidait
  /// le brouillon (seconde étape). Aucune combinaison d'état ne doit plus y mener.
  func testAccidentalCloseAlwaysClosesAndKeepsDraft() {
    for blockOpen in [false, true] {
      for onSecondStep in [false, true] {
        XCTAssertEqual(
          QuickEntryClose.outcome(
            discardDraft: false, blockOpen: blockOpen, onSecondStep: onSecondStep),
          .closeKeepingDraft)
      }
    }
  }
}
