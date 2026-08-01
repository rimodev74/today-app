import XCTest

@testable import Today

final class NotesCodecTests: XCTestCase {
  func testEncode_emptyAttributedString_producesEmptyData() {
    XCTAssertEqual(NotesCodec.encode(NSAttributedString(string: "")), Data())
  }

  func testDecode_emptyData_producesEmptyAttributedString() {
    XCTAssertEqual(NotesCodec.decode(Data()).string, "")
  }

  func testEncodeDecode_roundTripsPlainText() {
    let original = NSAttributedString(string: "Rendez-vous à 10h")
    let data = NotesCodec.encode(original)
    XCTAssertFalse(data.isEmpty)
    XCTAssertEqual(NotesCodec.decode(data).string, "Rendez-vous à 10h")
  }

  func testEncodeDecode_preservesBold() {
    let bold = NSAttributedString(
      string: "important",
      attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
    )
    let data = NotesCodec.encode(bold)
    let decoded = NotesCodec.decode(data)
    let font = decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    XCTAssertTrue(
      font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
      "le gras doit survivre à l'aller-retour RTF")
  }

  func testPlainText_matchesDecodedString() {
    let data = NotesCodec.encode(NSAttributedString(string: "abc"))
    XCTAssertEqual(NotesCodec.plainText(data), "abc")
  }

  func testPlainText_ofEmptyData_isEmpty() {
    XCTAssertEqual(NotesCodec.plainText(Data()), "")
  }

  func testPlainText_collapsesNewlinesToSingleLine() {
    let data = NotesCodec.encode(
      NSAttributedString(string: "Créer les dossiers\net ranger les rushes"))
    XCTAssertEqual(NotesCodec.plainText(data), "Créer les dossiers et ranger les rushes")
  }
}
