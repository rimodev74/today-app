import XCTest

@testable import Today

/// Le codage du repli des sous-tâches. La lecture par tâche (`isExpanded`) passe par
/// `UserDefaults` et le fil principal ; ce qui se vérifie sans écran, c'est l'aller-retour et la
/// règle qui porte tout : **absent = ouvert**.
final class SubtaskExpansionTests: XCTestCase {
  func testDecodeOfEmptyDataIsEmptySet() {
    // Le cas du premier lancement : rien d'enregistré, donc rien de replié — tout est ouvert.
    XCTAssertTrue(SubtaskExpansion.decode(Data()).isEmpty)
  }

  func testDecodeOfGarbageIsEmptySetRatherThanCrash() {
    XCTAssertTrue(SubtaskExpansion.decode(Data("pas du JSON".utf8)).isEmpty)
  }

  func testRoundTripKeepsExactlyTheCollapsedIdentifiers() {
    let collapsed: Set<UUID> = [UUID(), UUID(), UUID()]
    XCTAssertEqual(SubtaskExpansion.decode(SubtaskExpansion.encode(collapsed)), collapsed)
  }

  /// La règle du défaut, écrite noir sur blanc : on n'enregistre QUE les repliées, donc un
  /// identifiant absent de l'ensemble est ouvert. C'est ce qui fait qu'une tâche neuve arrive
  /// dépliée sans qu'on ait eu à l'inscrire.
  func testAnIdentifierAbsentFromTheSetIsExpanded() {
    let collapsed = SubtaskExpansion.decode(SubtaskExpansion.encode([UUID()]))
    XCTAssertFalse(collapsed.contains(UUID()))
  }
}
