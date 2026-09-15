import XCTest

@testable import Today

/// L'accueil ne doit JAMAIS s'afficher devant une base qui contient déjà du travail : c'est ce qui
/// sépare une installation d'une mise à jour, et la seule règle de l'accueil qui puisse gêner.
final class OnboardingTests: XCTestCase {
  func testUneBaseViergeSansDrapeauVoitLAccueil() {
    XCTAssertEqual(Onboarding.decide(completed: false, hasExistingData: false), .present)
  }

  func testUneBaseExistanteSansDrapeauEstMarqueeEnSilence() {
    XCTAssertEqual(Onboarding.decide(completed: false, hasExistingData: true), .markCompleted)
  }

  func testLeDrapeauEcritNeMontrePlusRien() {
    XCTAssertEqual(Onboarding.decide(completed: true, hasExistingData: false), .none)
    XCTAssertEqual(Onboarding.decide(completed: true, hasExistingData: true), .none)
  }

  func testLesEtapesSEnchainentEtSArretentAuxBords() {
    XCTAssertNil(OnboardingStep.welcome.previous)
    XCTAssertEqual(OnboardingStep.welcome.next, .profile)
    XCTAssertEqual(OnboardingStep.profile.next, .appearance)
    XCTAssertEqual(OnboardingStep.reminders.next, .ready)
    XCTAssertNil(OnboardingStep.ready.next)
  }

  func testLesTouchesSeLisentDansLeLibelle() {
    XCTAssertEqual(Onboarding.keycaps(for: "⌃⌥Espace"), ["⌃", "⌥", "Espace"])
    XCTAssertEqual(Onboarding.keycaps(for: "⌘⇧A"), ["⌘", "⇧", "A"])
    XCTAssertEqual(Onboarding.keycaps(for: "F5"), ["F5"])
    XCTAssertEqual(Onboarding.keycaps(for: ""), [])
  }
}
