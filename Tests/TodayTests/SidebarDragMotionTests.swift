import Observation
import XCTest
import os

@testable import Today

/// Le résultat d'une image de glissement dans la sidebar, tel que les modificateurs le lisent.
@MainActor
final class SidebarDragMotionTests: XCTestCase {
  func testLiftedRowFollowsTheCursorOthersOnlyMoveVertically() {
    let motion = SidebarDragMotion<String>()
    motion.update(
      translation: CGSize(width: 4, height: 30), offsets: ["b": -24], placeholder: nil)

    XCTAssertEqual(motion.offset(of: "a", lifted: true), CGSize(width: 4, height: 30))
    XCTAssertEqual(motion.offset(of: "b", lifted: false), CGSize(width: 0, height: -24))
    XCTAssertEqual(
      motion.offset(of: "c", lifted: false), .zero, "une ligne non écartée reste en place")
  }

  func testClearBringsEverythingBackToRest() {
    let motion = SidebarDragMotion<String>()
    motion.update(
      translation: CGSize(width: 1, height: 9), offsets: ["b": 24],
      placeholder: CGRect(x: 0, y: 10, width: 100, height: 24))
    motion.clear()

    XCTAssertEqual(motion.translation, .zero)
    XCTAssertTrue(motion.offsets.isEmpty)
    XCTAssertNil(motion.placeholder)
  }

  /// Le point de tout le type : réécrire une valeur identique n'invalide personne. Sans cette
  /// garde, les lignes qui n'ont pas bougé (et le trou) se rejoueraient à chaque image.
  func testIdenticalUpdateDoesNotNotifyObservers() {
    let motion = SidebarDragMotion<String>()
    let frame = (
      CGSize(width: 0, height: 12), ["b": CGFloat(-24)], CGRect(x: 0, y: 0, width: 9, height: 9)
    )
    motion.update(translation: frame.0, offsets: frame.1, placeholder: frame.2)

    // Un verrou et pas un `var` : `onChange` est `@Sendable`, muter une variable capturée y est
    // un diagnostic de concurrence.
    let fired = OSAllocatedUnfairLock(initialState: 0)
    withObservationTracking {
      _ = motion.translation
      _ = motion.offsets
      _ = motion.placeholder
    } onChange: {
      fired.withLock { $0 += 1 }
    }
    motion.update(translation: frame.0, offsets: frame.1, placeholder: frame.2)
    XCTAssertEqual(fired.withLock { $0 }, 0)

    motion.update(translation: CGSize(width: 0, height: 13), offsets: frame.1, placeholder: frame.2)
    XCTAssertEqual(fired.withLock { $0 }, 1, "une translation qui change doit, elle, être vue")
  }
}
