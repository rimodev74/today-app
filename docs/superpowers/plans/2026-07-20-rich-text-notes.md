# Notes riches (liens, gras/italique, couleur d'en-tête) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notes de tâche/liste/projet en texte riche (liens auto-détectés + Cmd+K natif, gras/italique via Cmd+B/Cmd+I) et en-têtes de section avec couleur au choix parmi une palette fermée.

**Architecture:** `notes` passe de `String` à `Data` (RTF) sur les 3 modèles concernés. Un nouveau `RichTextEditor` (NSViewRepresentable, `isRichText = true`) remplace `AutoGrowingTextEditor` sur les 3 sites d'édition. `NotesCodec` isole la conversion Data↔NSAttributedString (seul point pur/testable de la feature). `HeaderColor` est un enum fermé (7 teintes système) mappé sur un nouveau champ `TaskItem.headerColorRaw: String?`, même pattern que `Priority`/`priorityRaw` déjà dans le modèle.

**Tech Stack:** SwiftUI + AppKit (NSTextView), SwiftData, XCTest.

## Global Constraints

- Spec source : `docs/superpowers/specs/2026-07-20-rich-text-notes-design.md`.
- Cible `.macOS(.v14)` (`Package.swift`) — `swift build` compile pour l'hôte (macOS 26+), donc une API trop récente compilerait sans erreur et casserait sur une vraie machine macOS 14. Toutes les API utilisées dans ce plan ont été vérifiées disponibles depuis macOS 11 au plus tard (`isRichText`, `isAutomaticLinkDetectionEnabled`, `orderFrontLinkPanel(_:)` : AppKit historique ; `TextFormattingCommands`, `CommandGroup` : SwiftUI Commands, macOS 11+) — aucun `#available` requis.
- **Pas de tests UI automatisés dans ce projet** (cf. `CLAUDE.md` : « swift build qui passe ne veut pas dire que ça marche »). Les tâches qui touchent uniquement des vues SwiftUI/NSViewRepresentable se vérifient via `swift build` (compile) + `./run.sh` (vérification manuelle décrite dans chaque tâche), PAS via XCTest. Seule la logique pure (`NotesCodec`, `HeaderColor`) reçoit de vrais tests XCTest, dans `Tests/ThingsCloneTests/`, même style que `PomodoroTimerTests.swift` (`XCTestCase`, `@testable import ThingsClone`, messages d'assertion en français).
- Changer le type d'un champ `@Model` efface la base SwiftData locale au prochain lancement (déjà documenté dans `CLAUDE.md`, confirmé acceptable avec l'utilisateur pour ce changement).
- Aucun trailer `Co-Authored-By` ni mention « Generated with Claude Code » dans les messages de commit (préférence globale de l'utilisateur).
- Formatage avant chaque commit : `xcrun swift-format -i -r Sources`.

---

### Task 1: `HeaderColor` — palette fermée de couleurs d'en-tête

**Files:**
- Create: `Sources/ThingsClone/Models/HeaderColor.swift`
- Test: `Tests/ThingsCloneTests/HeaderColorTests.swift`

**Interfaces:**
- Produces: `enum HeaderColor: String, CaseIterable, Identifiable` avec `case red, orange, yellow, green, blue, purple, pink`, `var id: String`, `var label: String`, `var color: Color`. Utilisé par Task 6 (menu ••• de `HeaderRow`) et par `TaskItem.headerColor` (Task 4).

- [ ] **Step 1: Écrire le test qui échoue**

```swift
// Tests/ThingsCloneTests/HeaderColorTests.swift
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
```

- [ ] **Step 2: Vérifier que ça échoue**

Run: `swift test --filter HeaderColorTests`
Expected: FAIL (`cannot find type 'HeaderColor' in scope`)

- [ ] **Step 3: Implémentation minimale**

```swift
// Sources/ThingsClone/Models/HeaderColor.swift
import SwiftUI

/// Palette fermée pour la couleur d'un en-tête de section (pas de `ColorPicker` libre) — mêmes
/// teintes que les tags Finder, pour rester dans un vocabulaire de couleur déjà familier sur macOS.
/// Stockée sur `TaskItem.headerColorRaw` (même pattern que `Priority`/`priorityRaw`).
enum HeaderColor: String, CaseIterable, Identifiable {
  case red, orange, yellow, green, blue, purple, pink

  var id: String { rawValue }

  var label: String {
    switch self {
    case .red: return "Rouge"
    case .orange: return "Orange"
    case .yellow: return "Jaune"
    case .green: return "Vert"
    case .blue: return "Bleu"
    case .purple: return "Violet"
    case .pink: return "Rose"
    }
  }

  /// Couleur système dynamique (s'adapte au mode sombre et à l'accessibilité) plutôt qu'un hex
  /// figé : rung le plus natif possible pour un pastille de menu.
  var color: Color {
    switch self {
    case .red: return Color(nsColor: .systemRed)
    case .orange: return Color(nsColor: .systemOrange)
    case .yellow: return Color(nsColor: .systemYellow)
    case .green: return Color(nsColor: .systemGreen)
    case .blue: return Color(nsColor: .systemBlue)
    case .purple: return Color(nsColor: .systemPurple)
    case .pink: return Color(nsColor: .systemPink)
    }
  }
}
```

- [ ] **Step 4: Vérifier que ça passe**

Run: `swift test --filter HeaderColorTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
xcrun swift-format -i -r Sources
git add Sources/ThingsClone/Models/HeaderColor.swift Tests/ThingsCloneTests/HeaderColorTests.swift
git commit -m "Ajoute la palette HeaderColor pour les en-têtes"
```

---

### Task 2: `NotesCodec` — conversion Data (RTF) ↔ NSAttributedString

**Files:**
- Create: `Sources/ThingsClone/Views/TaskList/NotesCodec.swift`
- Test: `Tests/ThingsCloneTests/NotesCodecTests.swift`

**Interfaces:**
- Produces: `enum NotesCodec` avec `static func decode(_ data: Data) -> NSAttributedString`, `static func encode(_ attributedString: NSAttributedString) -> Data`, `static func plainText(_ data: Data) -> String`. Utilisé par `RichTextEditor` (Task 3) et par l'aperçu tronqué + placeholder « Notes » des 3 sites d'édition (Task 4).
- Garantie posée par ce module (dont dépend le reste de la feature) : une note vide encode TOUJOURS en `Data()` exactement — jamais un en-tête RTF non vide pour une chaîne vide. Les vérifications `.isEmpty` sur les champs `notes: Data` des modèles s'appuient sur cette garantie sans repasser par `NotesCodec`.

- [ ] **Step 1: Écrire le test qui échoue**

```swift
// Tests/ThingsCloneTests/NotesCodecTests.swift
import XCTest
@testable import ThingsClone

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
    XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false, "le gras doit survivre à l'aller-retour RTF")
  }

  func testPlainText_matchesDecodedString() {
    let data = NotesCodec.encode(NSAttributedString(string: "abc"))
    XCTAssertEqual(NotesCodec.plainText(data), "abc")
  }

  func testPlainText_ofEmptyData_isEmpty() {
    XCTAssertEqual(NotesCodec.plainText(Data()), "")
  }
}
```

- [ ] **Step 2: Vérifier que ça échoue**

Run: `swift test --filter NotesCodecTests`
Expected: FAIL (`cannot find 'NotesCodec' in scope`)

- [ ] **Step 3: Implémentation minimale**

```swift
// Sources/ThingsClone/Views/TaskList/NotesCodec.swift
import AppKit

/// Sérialise les notes riches (gras, italique, liens) en RTF pour le stockage `Data` des modèles
/// (`TaskItem.notes`, `TodoList.notes`, `Project.notes`). Seul point de conversion : les modèles
/// eux-mêmes restent ignorants du RTF, ils stockent du `Data` opaque.
enum NotesCodec {
  static func decode(_ data: Data) -> NSAttributedString {
    guard !data.isEmpty,
      let attributed = NSAttributedString(rtf: data, documentAttributes: nil)
    else { return NSAttributedString() }
    return attributed
  }

  /// Une note vide encode TOUJOURS en `Data()` exactement (jamais un en-tête RTF vide) : les
  /// `.isEmpty` sur `notes: Data` dans les vues restent fiables sans repasser par ce module.
  static func encode(_ attributedString: NSAttributedString) -> Data {
    guard !attributedString.string.isEmpty else { return Data() }
    let range = NSRange(location: 0, length: attributedString.length)
    return attributedString.rtf(from: range, documentAttributes: [:]) ?? Data()
  }

  /// Texte brut, pour l'aperçu tronqué (une ligne, sans mise en forme) sous une tâche au repos.
  static func plainText(_ data: Data) -> String {
    decode(data).string
  }
}
```

- [ ] **Step 4: Vérifier que ça passe**

Run: `swift test --filter NotesCodecTests`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
xcrun swift-format -i -r Sources
git add Sources/ThingsClone/Views/TaskList/NotesCodec.swift Tests/ThingsCloneTests/NotesCodecTests.swift
git commit -m "Ajoute NotesCodec pour la conversion RTF des notes"
```

---

### Task 3: `RichTextEditor` — remplace `AutoGrowingTextEditor`

**Files:**
- Create: `Sources/ThingsClone/Views/TaskList/RichTextEditor.swift`

**Interfaces:**
- Consumes: `NotesCodec.decode(_:) -> NSAttributedString`, `NotesCodec.encode(_:) -> Data` (Task 2).
- Produces: `struct RichTextEditor: NSViewRepresentable` avec `@Binding var data: Data`, `var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)`, `var textColor: NSColor = .labelColor`, `var handleReturn: ((_ shiftHeld: Bool) -> Bool)? = nil`. Câblé sur les 3 sites d'édition en Task 4 (ne compile/ne s'exécute pas encore à cette étape — `AutoGrowingTextEditor` reste en place et utilisé jusqu'à Task 4, ce fichier est ajouté sans rien casser).

Pas de test XCTest ici : `NSViewRepresentable` n'est pas testable hors d'une fenêtre réelle (cf. Global Constraints). Vérifié par `swift build` puis, une fois câblé en Task 4, par la checklist manuelle de cette tâche-là.

- [ ] **Step 1: Créer le fichier**

```swift
// Sources/ThingsClone/Views/TaskList/RichTextEditor.swift
import AppKit
import SwiftUI

/// `NSTextView` en mode texte riche pour les notes de tâche/liste/projet : gras/italique via
/// `Cmd+B`/`Cmd+I` (menu Format natif, cf. `ThingsCloneApp`), liens détectés automatiquement à la
/// frappe et ajoutés/retirés via `Cmd+K` (panneau natif AppKit) ou clic droit → Supprimer le lien.
/// Remplace `AutoGrowingTextEditor` (texte brut) — même stratégie de taille intrinsèque
/// (`sizeThatFits` piloté par le layoutManager) ; le contenu est sérialisé en RTF (`NotesCodec`)
/// au lieu d'un `String` brut.
struct RichTextEditor: NSViewRepresentable {
  @Binding var data: Data
  var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
  var textColor: NSColor = .labelColor
  /// Appelé sur Entrée ; `true` = géré (le retour à la ligne par défaut est supprimé),
  /// `false`/`nil` = comportement natif (insère un retour à la ligne).
  var handleReturn: ((_ shiftHeld: Bool) -> Bool)?

  func makeNSView(context: Context) -> NSTextView {
    let textView = NSTextView()
    textView.delegate = context.coordinator
    textView.isRichText = true
    textView.isAutomaticLinkDetectionEnabled = true
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.font = font
    textView.textColor = textColor
    textView.typingAttributes = [.font: font, .foregroundColor: textColor]
    textView.textStorage?.setAttributedString(NotesCodec.decode(data))
    context.coordinator.lastPushed = data
    return textView
  }

  func updateNSView(_ nsView: NSTextView, context: Context) {
    context.coordinator.parent = self
    // N'écrase le contenu que si `data` a changé depuis l'EXTÉRIEUR (chargement initial, autre
    // vue) — pas en écho de notre propre `textDidChange`, sinon le curseur saute à chaque frappe.
    guard data != context.coordinator.lastPushed else { return }
    nsView.textStorage?.setAttributedString(NotesCodec.decode(data))
    context.coordinator.lastPushed = data
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0,
      let textContainer = nsView.textContainer, let layoutManager = nsView.layoutManager
    else { return nil }
    textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: textContainer)
    let contentHeight = layoutManager.usedRect(for: textContainer).height
    let lineHeight = layoutManager.defaultLineHeight(for: nsView.font ?? font)
    return CGSize(width: width, height: ceil(max(contentHeight, lineHeight)))
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: RichTextEditor
    /// Dernière valeur poussée dans `parent.data`, par nous-même ou vue de l'extérieur — distingue
    /// un écho de notre propre frappe (à ignorer dans `updateNSView`) d'un changement externe réel.
    var lastPushed = Data()

    init(_ parent: RichTextEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let encoded = NotesCodec.encode(textView.attributedString())
      lastPushed = encoded
      parent.data = encoded
    }

    // Intercepte Entrée avant l'insertion native : `handleReturn` décide si elle doit être
    // avalée (retour `true`) ou laissée insérer un retour à la ligne comme d'habitude.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard selector == #selector(NSResponder.insertNewline(_:)), let handleReturn = parent.handleReturn
      else { return false }
      let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
      return handleReturn(shiftHeld)
    }
  }
}
```

- [ ] **Step 2: Vérifier que le build passe**

Run: `swift build`
Expected: succès (le fichier est ajouté mais n'est encore référencé nulle part — `AutoGrowingTextEditor` reste utilisé jusqu'à Task 4).

- [ ] **Step 3: Commit**

```bash
xcrun swift-format -i -r Sources
git add Sources/ThingsClone/Views/TaskList/RichTextEditor.swift
git commit -m "Ajoute RichTextEditor (NSTextView riche) en remplacement d'AutoGrowingTextEditor"
```

---

### Task 4: Notes en `Data` sur les 3 modèles + câblage de `RichTextEditor`

Tâche unique et non scindable : changer le type de `notes` casse la compilation de tout site qui le
lit encore comme `String` — le changement de modèle et le câblage des 3 éditeurs doivent atterrir
dans le même commit pour que le projet compile à chaque étape.

**Files:**
- Modify: `Sources/ThingsClone/Models/TaskItem.swift`
- Modify: `Sources/ThingsClone/Models/TodoList.swift`
- Modify: `Sources/ThingsClone/Models/Project.swift`
- Modify: `Sources/ThingsClone/Views/TaskList/TaskListView.swift` (notes de liste, de tâche, de projet, aperçu tronqué)
- Delete: `Sources/ThingsClone/Views/TaskList/AutoGrowingTextEditor.swift` (remplacé par `RichTextEditor`, Task 3 ; plus aucun appelant après cette tâche)

**Interfaces:**
- Consumes: `RichTextEditor` (Task 3), `NotesCodec.plainText(_:)` (Task 2), `HeaderColor` (Task 1, pour la propriété calculée `TaskItem.headerColor` — pas encore affichée, câblée en Task 6).
- Produces: `TaskItem.notes: Data`, `TodoList.notes: Data`, `Project.notes: Data`, `TaskItem.headerColorRaw: String?` + `TaskItem.headerColor: HeaderColor?` (get/set).

- [ ] **Step 1: `TaskItem.swift` — notes en `Data` + champ couleur d'en-tête**

Remplacer :

```swift
  var title: String
  var notes: String
  var isCompleted: Bool
```

par :

```swift
  var title: String
  var notes: Data
  var isCompleted: Bool
```

Remplacer :

```swift
  var reminderIdentifier: String?
  var list: TodoList?

  init(
    title: String,
    notes: String = "",
    when: Date? = nil,
    isHeader: Bool = false,
    list: TodoList? = nil
  ) {
```

par :

```swift
  var reminderIdentifier: String?
  var list: TodoList?
  /// Couleur de l'en-tête (uniquement significatif si `isHeader`). `nil` = style par défaut.
  /// Stocke `HeaderColor.rawValue` — voir `headerColor` ci-dessous, même pattern que `priority`.
  var headerColorRaw: String?

  init(
    title: String,
    notes: Data = Data(),
    when: Date? = nil,
    isHeader: Bool = false,
    list: TodoList? = nil
  ) {
```

Ajouter, après la propriété calculée `priority` existante :

```swift
  /// Stocké en String (rawValue) : SwiftData persiste les propriétés stockées, pas les calculées.
  var headerColor: HeaderColor? {
    get { headerColorRaw.flatMap(HeaderColor.init(rawValue:)) }
    set { headerColorRaw = newValue?.rawValue }
  }
```

- [ ] **Step 2: `TodoList.swift` — notes en `Data`**

Remplacer :

```swift
  var title: String
  var notes: String
  var sortIndex: Int = 0
```

par :

```swift
  var title: String
  var notes: Data
  var sortIndex: Int = 0
```

Remplacer :

```swift
  init(title: String, notes: String = "", project: Project? = nil) {
```

par :

```swift
  init(title: String, notes: Data = Data(), project: Project? = nil) {
```

- [ ] **Step 3: `Project.swift` — notes en `Data`**

Remplacer :

```swift
  var title: String
  var notes: String
  var sortIndex: Int = 0
```

par :

```swift
  var title: String
  var notes: Data
  var sortIndex: Int = 0
```

Remplacer :

```swift
  init(title: String, notes: String = "") {
```

par :

```swift
  init(title: String, notes: Data = Data()) {
```

- [ ] **Step 4: Vérifier que le build échoue aux bons endroits**

Run: `swift build`
Expected: FAIL — erreurs de type sur les 3 appels à `AutoGrowingTextEditor(text: $...notes, ...)` (attend `Binding<String>`, reçoit `Binding<Data>`) et sur `Text(task.notes)`. C'est le signal qu'on modifie exactement les bons sites ensuite.

- [ ] **Step 5: Notes de liste — `notesBox` (TaskListView.swift)**

Remplacer :

```swift
      AutoGrowingTextEditor(
        text: $list.notes,
        font: .systemFont(ofSize: NSFont.systemFontSize),
        textColor: .labelColor,
```

par :

```swift
      RichTextEditor(
        data: $list.notes,
        font: .systemFont(ofSize: NSFont.systemFontSize),
        textColor: .labelColor,
```

(le reste du bloc `notesBox` — `handleReturn:`, `.fixedSize`, `.focused` — ne change pas ; `list.notes.isEmpty` juste au-dessus reste tel quel, `Data.isEmpty` fonctionne identiquement.)

- [ ] **Step 6: Notes de tâche — `notesField` (TaskListView.swift)**

Remplacer :

```swift
      AutoGrowingTextEditor(
        text: $task.notes,
        font: .systemFont(ofSize: NSFont.systemFontSize),
        textColor: .secondaryLabelColor
      )
```

par :

```swift
      RichTextEditor(
        data: $task.notes,
        font: .systemFont(ofSize: NSFont.systemFontSize),
        textColor: .secondaryLabelColor
      )
```

(`task.notes.isEmpty` juste au-dessus reste tel quel.)

- [ ] **Step 7: Aperçu tronqué d'une tâche au repos (TaskListView.swift, struct `TaskRow`)**

Remplacer :

```swift
      } else if !task.notes.isEmpty {
        // Au repos : aperçu de la note sous le titre (1 ligne tronquée, façon Things). Aligné
        // sous le titre (case 16 + espace 10), pas sous la case.
        Text(task.notes)
          .font(.callout)
```

par :

```swift
      } else if !task.notes.isEmpty {
        // Au repos : aperçu de la note sous le titre (1 ligne tronquée, façon Things). Aligné
        // sous le titre (case 16 + espace 10), pas sous la case. Texte brut seulement — la mise
        // en forme (gras/italique/liens) ne sert qu'en édition.
        Text(NotesCodec.plainText(task.notes))
          .font(.callout)
```

- [ ] **Step 8: Notes de projet — `ProjectPageView` (TaskListView.swift)**

Remplacer :

```swift
        TextField("Notes", text: $project.notes, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
```

par :

```swift
        ZStack(alignment: .topLeading) {
          if project.notes.isEmpty {
            Text("Notes")
              .font(.subheadline)
              .foregroundStyle(.tertiary)
              .padding(.leading, 5)
              .allowsHitTesting(false)
          }
          RichTextEditor(
            data: $project.notes,
            font: .systemFont(ofSize: NSFont.systemFontSize - 1),
            textColor: .secondaryLabelColor
          )
          .fixedSize(horizontal: false, vertical: true)
        }
      }
```

- [ ] **Step 9: Supprimer `AutoGrowingTextEditor.swift`**

Run: `rm "Sources/ThingsClone/Views/TaskList/AutoGrowingTextEditor.swift"`

- [ ] **Step 10: Vérifier que le build passe**

Run: `swift build`
Expected: succès, zéro erreur.

- [ ] **Step 11: Vérification manuelle**

Run: `./run.sh`

- Ouvrir une liste, taper dans ses notes → le texte apparaît normalement, le placeholder « Notes » disparaît/réapparaît correctement.
- Taper une URL (ex. `https://apple.com`) dans les notes d'une tâche → elle devient bleue/soulignée automatiquement en quittant le mot.
- Ouvrir un projet, taper dans ses notes → même comportement que liste/tâche (avant : simple `TextField`, donc vérifier surtout que le retrait/placeholder est cohérent avec le reste de la page).
- Fermer l'app et la rouvrir (`./run.sh` à nouveau) → la base a été effacée une seule fois au premier lancement post-changement (attendu), les notes tapées APRÈS ce lancement persistent bien au relancement suivant.

- [ ] **Step 12: Commit**

```bash
xcrun swift-format -i -r Sources
git add Sources/ThingsClone/Models/TaskItem.swift Sources/ThingsClone/Models/TodoList.swift \
  Sources/ThingsClone/Models/Project.swift Sources/ThingsClone/Views/TaskList/TaskListView.swift
git rm Sources/ThingsClone/Views/TaskList/AutoGrowingTextEditor.swift
git commit -m "Notes en RTF (Data) sur tâche/liste/projet, câblées sur RichTextEditor"
```

---

### Task 5: Gras/italique et liens — commandes natives de l'app

**Files:**
- Modify: `Sources/ThingsClone/ThingsCloneApp.swift`

**Interfaces:**
- Consumes: `RichTextEditor` (Task 3/4, déjà câblé et en mode `isRichText = true` — cette tâche n'ajoute que le câblage des commandes clavier/menu, aucune modification du composant lui-même).

- [ ] **Step 1: Ajouter le menu Format (gras/italique) et le raccourci lien**

Remplacer :

```swift
    .modelContainer(Self.container)
    .defaultSize(width: 1400, height: 900)

    Settings {
```

par :

```swift
    .modelContainer(Self.container)
    .defaultSize(width: 1400, height: 900)
    // Menu Format natif (gras Cmd+B, italique Cmd+I, etc.) câblé sur le premier répondeur —
    // `RichTextEditor` (isRichText) gère déjà ces actions nativement, aucune logique à écrire.
    // Le second groupe ajoute Cmd+K : panneau natif AppKit pour ajouter/modifier/retirer un lien
    // sur la sélection courante (même mécanisme que Mail/Notes/TextEdit).
    .commands {
      TextFormattingCommands()
      CommandGroup(after: .textEditing) {
        Button("Ajouter un lien…") {
          NSApp.sendAction(#selector(NSTextView.orderFrontLinkPanel(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("k", modifiers: .command)
      }
    }

    Settings {
```

- [ ] **Step 2: Vérifier que le build passe**

Run: `swift build`
Expected: succès.

- [ ] **Step 3: Vérification manuelle**

Run: `./run.sh`

- Ouvrir les notes d'une tâche, taper du texte, sélectionner un mot, `Cmd+B` → le mot passe en gras. `Cmd+I` sur un autre mot → italique. Un menu « Format » apparaît dans la barre de menu avec ces mêmes options.
- Sélectionner du texte, `Cmd+K` → un petit panneau natif s'ouvre pour saisir une URL ; valider → le texte sélectionné devient un lien cliquable (Cmd+clic l'ouvre dans le navigateur).
- Clic droit sur ce lien → « Supprimer le lien » est présent et fonctionne.

- [ ] **Step 4: Commit**

```bash
xcrun swift-format -i -r Sources
git add Sources/ThingsClone/ThingsCloneApp.swift
git commit -m "Ajoute le menu Format natif et Cmd+K pour les liens"
```

---

### Task 6: Couleur d'en-tête — palette dans le menu ••• de `HeaderRow`

**Files:**
- Modify: `Sources/ThingsClone/Views/TaskList/TaskListView.swift` (struct `HeaderRow`, et `taskRow(_:)` pour la vue en lecture seule du projet)

**Interfaces:**
- Consumes: `HeaderColor` (Task 1), `TaskItem.headerColor` (Task 4).

- [ ] **Step 1: Ajouter la palette au menu ••• de l'en-tête**

Remplacer :

```swift
      Menu {
        Button("Supprimer", role: .destructive, action: onDelete)
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.accentColor.opacity(0.85))
      }
```

par :

```swift
      Menu {
        Menu("Couleur") {
          Button("Par défaut") { task.headerColor = nil }
          ForEach(HeaderColor.allCases) { option in
            Button {
              task.headerColor = option
            } label: {
              Label(option.label, systemImage: "circle.fill")
                .foregroundStyle(option.color)
            }
          }
        }
        Divider()
        Button("Supprimer", role: .destructive, action: onDelete)
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.accentColor.opacity(0.85))
      }
```

- [ ] **Step 2: Teinter le titre et le fond de la pilule**

Remplacer (dans `pill(active:)`) :

```swift
      TextField("Nouvel en-tête", text: $task.title)
        .textFieldStyle(.plain)
        .font(.headline)
        .foregroundStyle(Color.accentColor.opacity(0.85))
```

par :

```swift
      TextField("Nouvel en-tête", text: $task.title)
        .textFieldStyle(.plain)
        .font(.headline)
        .foregroundStyle((task.headerColor?.color ?? Color.accentColor).opacity(0.85))
```

Remplacer :

```swift
    .background {
      if active {
        // Pendant le drag, l'en-tête est le calque du DESSUS de la cascade : couleur OPAQUE dédiée
        // (#CAE1FF), sinon les calques derrière transparaissent à travers. Hors drag, le lavande
        // translucide (comme une tâche sélectionnée) suffit. Ombre de soulevé seulement au drag.
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isDragging ? AnyShapeStyle(Self.dragTop) : AnyShapeStyle(thingsSelectionFill))
          .shadow(color: .black.opacity(isDragging ? 0.14 : 0), radius: 6, y: 3)
      }
    }
```

par :

```swift
    .background {
      if active {
        // Pendant le drag, l'en-tête est le calque du DESSUS de la cascade : couleur OPAQUE dédiée
        // (#CAE1FF), sinon les calques derrière transparaissent à travers. Hors drag, le lavande
        // translucide (comme une tâche sélectionnée) suffit, ou la teinte choisie si définie.
        // Ombre de soulevé seulement au drag.
        // ponytail: opacité fixe (0.22) plutôt que le double palier clair/sombre de
        // `thingsSelectionFill` — à aligner si l'écart se voit trop en mode sombre.
        let tinted = task.headerColor.map { AnyShapeStyle($0.color.opacity(0.22)) }
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isDragging ? AnyShapeStyle(Self.dragTop) : (tinted ?? AnyShapeStyle(thingsSelectionFill)))
          .shadow(color: .black.opacity(isDragging ? 0.14 : 0), radius: 6, y: 3)
      }
    }
```

- [ ] **Step 3: Refléter la couleur dans la vue en lecture seule du projet (`taskRow(_:)`)**

Remplacer :

```swift
    if task.isHeader {
      Text(task.title.isEmpty ? "En-tête" : task.title)
        .font(.subheadline.bold())
        .foregroundStyle(.secondary)
        .padding(.leading, 20)
        .padding(.top, 6)
```

par :

```swift
    if task.isHeader {
      Text(task.title.isEmpty ? "En-tête" : task.title)
        .font(.subheadline.bold())
        .foregroundStyle(task.headerColor.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
        .padding(.leading, 20)
        .padding(.top, 6)
```

- [ ] **Step 4: Vérifier que le build passe**

Run: `swift build`
Expected: succès.

- [ ] **Step 5: Vérification manuelle**

Run: `./run.sh`

- Créer un en-tête, survoler → le ••• apparaît, l'ouvrir → sous-menu « Couleur » avec 7 options + « Par défaut ».
- Choisir « Rouge » → le titre de l'en-tête devient rouge immédiatement ; sélectionner l'en-tête → la pilule prend un fond rouge translucide.
- Choisir « Par défaut » → retour au lavande/accent d'origine.
- Ouvrir la page du projet contenant cette liste → l'en-tête coloré apparaît aussi en rouge dans la vue en lecture seule.

- [ ] **Step 6: Commit**

```bash
xcrun swift-format -i -r Sources
git add Sources/ThingsClone/Views/TaskList/TaskListView.swift
git commit -m "Couleur d'en-tête : palette dans le menu de HeaderRow"
```
