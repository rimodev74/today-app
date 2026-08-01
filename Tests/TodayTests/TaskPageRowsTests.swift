import XCTest

@testable import Today

/// L'ordre affiché d'une page, déduit de ses pans.
///
/// C'est la règle que chaque page réécrivait à la main à côté de son `body`, et qu'une page avait
/// fini par écrire faux (cf. `TaskPageBlock`). Écrite une fois, elle se vérifie une fois.
final class TaskPageRowsTests: XCTestCase {
  /// Détachées de tout store : l'aplatissement ne regarde que l'ordre, jamais la donnée.
  private let a = TaskItem(title: "A")
  private let b = TaskItem(title: "B")
  private let c = TaskItem(title: "C")

  func testKeepsDeclarationOrderAcrossBlocks() {
    let blocks: [TaskPageBlock] = [.visible([a]), .visible([b, c])]
    XCTAssertEqual(blocks.displayedRows.map(\.title), ["A", "B", "C"])
  }

  /// Le cas qui compte : une section repliée n'offre aucune ligne au clavier — ↑/↓ ne peuvent pas
  /// emmener la sélection sur une ligne que l'œil ne voit pas.
  func testCollapsedBlockContributesNothing() {
    let blocks = [
      TaskPageBlock.visible([a]),
      TaskPageBlock(tasks: [b], isExpanded: false),
      TaskPageBlock.visible([c]),
    ]
    XCTAssertEqual(blocks.displayedRows.map(\.title), ["A", "C"])
  }

  func testNoBlocksMeansNoRows() {
    XCTAssertTrue([TaskPageBlock]().displayedRows.isEmpty)
    XCTAssertTrue([TaskPageBlock.visible([])].displayedRows.isEmpty)
  }
}
