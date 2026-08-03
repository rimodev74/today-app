import XCTest

@testable import Today

final class TextShortcutTests: XCTestCase {
  private let shortcuts: [TextShortcut] = [
    .init(trigger: "ajd", expansion: "@today"),
    .init(trigger: "crs", expansion: "#Courses"),
  ]

  private func expand(_ text: String) -> String? {
    QuickEntry.expanding(text, shortcuts: shortcuts).map(QuickEntry.applying)
  }

  /// L'espace final n'est pas cosmétique : c'est lui qui fait passer le jeton par `consuming`.
  func testTriggerAloneBecomesTokenFollowedBySpace() {
    XCTAssertEqual(expand("ajd"), "@today ")
    XCTAssertEqual(expand("crs"), "#Courses ")
  }

  func testOnlyTheLastWordIsReplaced() {
    XCTAssertEqual(expand("Acheter du pain ajd"), "Acheter du pain @today ")
  }

  func testCaseAndAccentInsensitive() {
    XCTAssertEqual(expand("AJD"), "@today ")
    XCTAssertEqual(
      QuickEntry.expanding("ÉTÉ", shortcuts: [.init(trigger: "ete", expansion: "@demain")])
        .map(QuickEntry.applying),
      "@demain ")
  }

  /// Une commande d'app ne se recolle PAS au texte : `before` est ce qui reste de la tâche en
  /// cours, et c'est le sigil `!` qui la distingue d'un jeton de saisie rapide.
  func testAppCommandIsRecognisedAndLeavesTheTextBehindIt() {
    let commands: [TextShortcut] = [.init(trigger: "ajd", expansion: AppCommand.today.token)]
    let match = QuickEntry.expanding("Acheter du pain ajd", shortcuts: commands)
    XCTAssertEqual(match?.before, "Acheter du pain ")
    XCTAssertEqual(AppCommand(token: match?.shortcut.expansion ?? ""), .today)
    XCTAssertEqual(AppCommand.today.smartList, .today)
    XCTAssertNil(AppCommand.show.smartList)
  }

  /// Le chemin qu'empruntent Entrée, ⌘↩ et ⇥. Un déclencheur de commande seul ne doit RIEN laisser
  /// comme titre, sinon il part en tâche nommée « op » — le bug remonté.
  func testResolvingSeparatesWrittenTokensFromCommands() {
    let all: [TextShortcut] = [
      .init(trigger: "ajd", expansion: "@today"),
      .init(trigger: "op", expansion: AppCommand.show.token),
    ]
    let token = QuickEntry.resolving("ajd", shortcuts: all)
    XCTAssertEqual(token?.text, "@today ")
    XCTAssertNil(token?.command)

    let command = QuickEntry.resolving("op", shortcuts: all)
    XCTAssertEqual(command?.text, "")
    XCTAssertEqual(command?.command, .show)

    // Ce qui précède le déclencheur reste une tâche à enregistrer.
    XCTAssertEqual(
      QuickEntry.resolving("Relire le devis op", shortcuts: all)?.text, "Relire le devis ")
    XCTAssertNil(QuickEntry.resolving("Relire le devis", shortcuts: all))
  }

  /// Les commandes du minuteur sont des commandes d'app comme les autres (même sigil, même menu de
  /// réglages), mais elles ne NAVIGUENT pas : `smartList` nul et `isPomodoro` vrai, c'est ce couple
  /// qui les empêche de ramener la fenêtre au premier plan quand on les frappe depuis une autre app.
  func testPomodoroCommandsNavigateNowhere() {
    XCTAssertEqual(AppCommand.pomodoroCommands.count, 5)
    for command in AppCommand.pomodoroCommands {
      XCTAssertNil(command.smartList, command.rawValue)
      XCTAssertTrue(command.isPomodoro, command.rawValue)
      XCTAssertEqual(AppCommand(token: command.token), command)
    }
    XCTAssertFalse(AppCommand.today.isPomodoro)
  }

  /// Les réglages du Pomodoro et l'onglet Raccourcis écrivent dans la MÊME liste : régler la
  /// combinaison d'une action met à jour sa ligne, ne la duplique pas, et la retirer efface la
  /// ligne au lieu de laisser une entrée sans déclencheur.
  func testCombosAreKeyedByTokenInASingleList() {
    let combo = KeyCombo(keyCode: 35, modifiers: 0, label: "⌃P")
    var keys: [KeyShortcut] = [.init(expansion: "@today", key: combo)]

    keys.setCombo(combo, for: AppCommand.pomodoroStart.token)
    XCTAssertEqual(keys.count, 2)
    XCTAssertEqual(keys.combo(for: AppCommand.pomodoroStart.token), combo)

    let autre = KeyCombo(keyCode: 36, modifiers: 0, label: "⌃L")
    keys.setCombo(autre, for: AppCommand.pomodoroStart.token)
    XCTAssertEqual(keys.count, 2, "une action ne doit jamais avoir deux lignes")
    XCTAssertEqual(keys.combo(for: AppCommand.pomodoroStart.token), autre)

    keys.setCombo(nil, for: AppCommand.pomodoroStart.token)
    XCTAssertEqual(keys.count, 1)
    XCTAssertNil(keys.combo(for: AppCommand.pomodoroStart.token))
  }

  /// Même règle pour l'abréviation, plus une : les espaces autour sont retirés, et une abréviation
  /// vidée efface la ligne — sinon « » resterait un déclencheur, que TOUT texte satisferait.
  func testTriggersAreTrimmedAndClearable() {
    var texts: [TextShortcut] = []
    texts.setTrigger("  pom ", for: AppCommand.pomodoroStart.token)
    XCTAssertEqual(texts.trigger(for: AppCommand.pomodoroStart.token), "pom")

    texts.setTrigger("   ", for: AppCommand.pomodoroStart.token)
    XCTAssertTrue(texts.isEmpty)
    XCTAssertEqual(texts.trigger(for: AppCommand.pomodoroStart.token), "")
  }

  /// Les deux familles ne doivent pas se confondre : un jeton de date n'est pas une commande.
  func testDateTokenIsNotAnAppCommand() {
    XCTAssertNil(AppCommand(token: "@today"))
    XCTAssertNil(AppCommand(token: "#Courses"))
    XCTAssertNil(AppCommand(token: "!inconnu"))
  }

  /// Sans correspondance, Tab doit rester Tab : `nil` est le signal que l'appelant relaie la touche.
  func testNoMatchReturnsNil() {
    XCTAssertNil(expand("ajouter"))
    XCTAssertNil(expand("ajd du pain"))
    XCTAssertNil(expand(""))
    XCTAssertNil(expand("ajd "))
  }

  /// Un store vierge sert les défauts ; une liste vidée à la main reste vide.
  func testDecodeDistinguishesEmptyStoreFromEmptyList() {
    XCTAssertEqual(TextShortcut.decode(Data()), TextShortcut.defaults)
    XCTAssertEqual(TextShortcut.decode(TextShortcut.encode([])), [])
    XCTAssertEqual(TextShortcut.decode(TextShortcut.encode(shortcuts)), shortcuts)
  }

  /// Les combinaisons ont leur propre liste, et surtout AUCUN défaut : en poser d'office risquerait
  /// de marcher sur le raccourci global d'une autre app sans que personne ne l'ait demandé.
  func testKeyShortcutsStartEmptyAndSurviveEncoding() {
    XCTAssertEqual(KeyShortcut.decode(Data()), [])
    let stored = [
      KeyShortcut(
        expansion: "@today", key: KeyCombo(keyCode: 17, modifiers: 1_048_576, label: "⌘T")),
      KeyShortcut(expansion: "!today"),
    ]
    XCTAssertEqual(KeyShortcut.decode(KeyShortcut.encode(stored)), stored)
  }

  /// Les défauts livrés doivent exister dans le menu des réglages, sinon le `Picker` s'affiche vide.
  func testDefaultExpansionsAreOfferedInSettings() {
    let tokens = Set(TextShortcut.dateOptions.map(\.token))
    for shortcut in TextShortcut.defaults {
      XCTAssertTrue(tokens.contains(shortcut.expansion), shortcut.expansion)
    }
  }
}
