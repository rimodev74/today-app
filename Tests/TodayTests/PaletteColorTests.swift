import XCTest

@testable import Today

final class PaletteColorTests: XCTestCase {
  func testAllCases_haveDistinctRawValues() {
    let rawValues = PaletteColor.allCases.map(\.rawValue)
    XCTAssertEqual(
      rawValues.count, Set(rawValues).count, "chaque teinte doit avoir une rawValue unique")
  }

  func testInit_fromRawValue_roundTrips() {
    for option in PaletteColor.allCases {
      XCTAssertEqual(PaletteColor(rawValue: option.rawValue), option)
    }
  }

  func testInit_fromUnknownRawValue_returnsNil() {
    XCTAssertNil(
      PaletteColor(rawValue: "turquoise-fluo"),
      "une valeur stockée inconnue (ancienne teinte retirée) ne doit pas planter, juste retomber sur nil"
    )
  }
}
