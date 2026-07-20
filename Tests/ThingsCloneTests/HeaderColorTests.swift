import XCTest
@testable import ThingsClone

final class HeaderColorTests: XCTestCase {
  func testAllCases_haveDistinctRawValues() {
    let rawValues = HeaderColor.allCases.map(\.rawValue)
    XCTAssertEqual(rawValues.count, Set(rawValues).count, "chaque teinte doit avoir une rawValue unique")
  }

  func testInit_fromRawValue_roundTrips() {
    for option in HeaderColor.allCases {
      XCTAssertEqual(HeaderColor(rawValue: option.rawValue), option)
    }
  }

  func testInit_fromUnknownRawValue_returnsNil() {
    XCTAssertNil(HeaderColor(rawValue: "turquoise-fluo"), "une valeur stockée inconnue (ancienne teinte retirée) ne doit pas planter, juste retomber sur nil")
  }
}
