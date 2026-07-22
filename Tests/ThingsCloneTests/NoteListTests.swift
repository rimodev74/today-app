import AppKit
import XCTest

@testable import ThingsClone

final class NoteListTests: XCTestCase {
  func testShouldConvert_onlyBareDashAtLineStart() {
    XCTAssertTrue(NoteList.shouldConvert(typedLineStart: "-"))
    XCTAssertFalse(NoteList.shouldConvert(typedLineStart: "*"))  // la puce a été retirée
    XCTAssertFalse(NoteList.shouldConvert(typedLineStart: "a"))
    XCTAssertFalse(NoteList.shouldConvert(typedLineStart: ""))
    // Ne convertit qu'en tout début de ligne : « x- » n'est pas un marqueur.
    XCTAssertFalse(NoteList.shouldConvert(typedLineStart: "x-"))
  }

  func testIsListItem() {
    XCTAssertTrue(NoteList.isListItem("–\tliste"))
    XCTAssertFalse(NoteList.isListItem("• puce"))  // plus de puces
    XCTAssertFalse(NoteList.isListItem("texte normal"))
    // Un tiret sans tabulation n'est pas un item (c'est du texte qui commence par « - »).
    XCTAssertFalse(NoteList.isListItem("- pas une liste"))
  }

  func testIsEmptyItem() {
    XCTAssertTrue(NoteList.isEmptyItem("–\t"))
    XCTAssertTrue(NoteList.isEmptyItem("–\t\n"))  // item vide au milieu (avec \n de fin)
    XCTAssertFalse(NoteList.isEmptyItem("–\tcontenu"))
    XCTAssertFalse(NoteList.isEmptyItem("texte normal"))
  }

  /// Le cœur du choix « fausse liste » : le marqueur + le retrait suspendu doivent traverser le
  /// stockage RTF des notes intacts, sinon la liste casse au rechargement.
  func testListSurvivesNotesCodecRoundTrip() {
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13),
      .paragraphStyle: NoteList.paragraphStyle(),
    ]
    let original = NSAttributedString(string: "–\tliste\n–\tde", attributes: attrs)

    let decoded = NotesCodec.decode(NotesCodec.encode(original))
    XCTAssertEqual(decoded.string, "–\tliste\n–\tde")
    XCTAssertTrue(NoteList.isListItem(decoded.string))
    let style = decoded.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(style?.headIndent, NoteList.indent, "le retrait suspendu doit survivre au RTF")
  }
}
