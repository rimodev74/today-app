# Sous-tâches (checklist) — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter des sous-tâches cochables à une `TaskItem`, affichées dépliées sous la tâche, en cohabitation avec les notes.

**Architecture:** Nouveau `@Model Subtask` relié à `TaskItem` par `@Relationship(deleteRule: .cascade)` (miroir du pattern `TodoList` ↔ `TaskItem`). Rendu par une `SubtaskRowView` (case ronde réutilisant `TaskCheckbox` généralisée), insérée dans l'arbre de vue *toujours monté* de `TaskRow`. Ajout/édition au clavier via l'icône `list.bullet` aujourd'hui décorative. Couplage nul avec l'état de la tâche.

**Tech Stack:** Swift, SwiftUI, SwiftData, AppKit. SwiftPM (pas de `.xcodeproj`). Tests : XCTest.

## Global Constraints

- **Cible macOS 14** (`Package.swift` : `.macOS(.v14)`). Le build compile pour l'hôte (macOS 26) sans vérifier ce plancher — vérifier à l'œil qu'aucune API `@available(macOS 15+)` n'est utilisée. `AnyShape` et `.onKeyPress` sont macOS 13/14+ : OK.
- **Natif d'abord.** Réutiliser `TaskCheckbox` plutôt qu'une nouvelle case ; `List`/SwiftUI natif.
- **Commentaires = pourquoi, pas quoi.** En français.
- **`// ponytail:`** marque une simplification délibérée et son plafond.
- **Lancer l'app :** `./run.sh` uniquement (jamais `swift run`). `swift build` pour compiler seul.
- **UI vérifiée à l'œil :** `swift build` qui passe ≠ ça marche. Chaque tâche UI se vérifie via `./run.sh`.
- **Pas de trailer `Co-Authored-By: Claude` ni mention « Generated with Claude »** dans les commits.
- **Base de données :** le store a été sauvegardé dans `~/Library/Application Support/thingsclone-db-backup-2026-07-22/`. La migration attendue est additive (préserve les données) ; restaurer par `cp` inverse si un lancement efface le store.

---

### Task 1 : Modèle `Subtask` + relation sur `TaskItem` + schéma

**Files:**
- Create: `Sources/ThingsClone/Models/Subtask.swift`
- Modify: `Sources/ThingsClone/Models/TaskItem.swift` (ajout relation + helpers)
- Modify: `Sources/ThingsClone/ThingsCloneApp.swift:57` (ajout `Subtask.self` au `Schema`)
- Test: `Tests/ThingsCloneTests/SubtaskTests.swift`

**Interfaces:**
- Produces:
  - `final class Subtask` : `title: String`, `isDone: Bool`, `sortIndex: Int`, `createdAt: Date`, `task: TaskItem?`. `init(title: String = "")`.
  - `TaskItem.subtasks: [Subtask]`
  - `TaskItem.orderedSubtasks: [Subtask]` (tri `sortIndex` puis `createdAt`)
  - `TaskItem.addSubtask() -> Subtask` (`@discardableResult` ; ajoute en fin, renvoie l'objet)

- [ ] **Step 1 : Écrire les tests qui échouent**

Create `Tests/ThingsCloneTests/SubtaskTests.swift` :

```swift
import SwiftData
import XCTest

@testable import ThingsClone

final class SubtaskTests: XCTestCase {
  /// Conteneur en mémoire : les tests de modèle ne touchent jamais le vrai store sur disque.
  private func makeContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  func testAddSubtask_appendsInOrderAndReturnsObject() throws {
    let ctx = try makeContext()
    let task = TaskItem(title: "T")
    ctx.insert(task)

    let a = task.addSubtask(); a.title = "a"
    let b = task.addSubtask(); b.title = "b"

    XCTAssertEqual(task.orderedSubtasks.map(\.title), ["a", "b"])
    XCTAssertEqual(b.sortIndex, a.sortIndex + 1)
  }

  func testOrderedSubtasks_sortsBySortIndex() throws {
    let ctx = try makeContext()
    let task = TaskItem(title: "T")
    ctx.insert(task)

    let a = task.addSubtask(); a.title = "a"
    let b = task.addSubtask(); b.title = "b"
    b.sortIndex = -5  // b passe devant

    XCTAssertEqual(task.orderedSubtasks.map(\.title), ["b", "a"])
  }

  func testDeletingTask_cascadesToSubtasks() throws {
    let ctx = try makeContext()
    let task = TaskItem(title: "T")
    ctx.insert(task)
    _ = task.addSubtask()
    try ctx.save()

    ctx.delete(task)
    try ctx.save()

    let remaining = try ctx.fetch(FetchDescriptor<Subtask>())
    XCTAssertTrue(remaining.isEmpty, "la suppression en cascade doit retirer les sous-tâches")
  }
}
```

- [ ] **Step 2 : Lancer les tests, vérifier qu'ils échouent (compilation)**

Run: `swift test --filter SubtaskTests 2>&1 | tail -20`
Expected: ÉCHEC de compilation — `Subtask` et `TaskItem.addSubtask` n'existent pas encore.

- [ ] **Step 3 : Créer le modèle `Subtask`**

Create `Sources/ThingsClone/Models/Subtask.swift` :

```swift
import Foundation
import SwiftData

/// Une étape cochable rattachée à une `TaskItem`. Entité distincte des notes (texte libre) : une
/// sous-tâche porte un état fait / pas fait et un ordre, rien d'autre. Miroir volontaire du pattern
/// `TodoList` ↔ `TaskItem` (relation + `sortIndex`).
@Model
final class Subtask {
  var title: String
  var isDone: Bool = false
  var sortIndex: Int = 0
  var createdAt: Date = Date()
  var task: TaskItem?

  init(title: String = "") {
    self.title = title
    self.createdAt = Date()
  }
}
```

- [ ] **Step 4 : Ajouter la relation et les helpers sur `TaskItem`**

Modify `Sources/ThingsClone/Models/TaskItem.swift`. Ajouter la propriété de relation juste après `var headerColorRaw: String?` (ligne 28) :

```swift
  @Relationship(deleteRule: .cascade, inverse: \Subtask.task) var subtasks: [Subtask] = []
```

Puis ajouter, avant la fermeture de la classe (après `func toggleCompletion()`) :

```swift
  /// Ordre manuel des sous-tâches ; `createdAt` départage les ex æquo (même pattern que
  /// `TodoList.orderedTasks`).
  var orderedSubtasks: [Subtask] {
    subtasks.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
  }

  /// Crée une sous-tâche vide en fin de liste et la renvoie (pour poser le focus dessus).
  @discardableResult
  func addSubtask() -> Subtask {
    let subtask = Subtask()
    subtask.sortIndex = (orderedSubtasks.last?.sortIndex ?? -1) + 1
    subtasks.append(subtask)
    return subtask
  }
```

- [ ] **Step 5 : Enregistrer `Subtask` dans le schéma**

Modify `Sources/ThingsClone/ThingsCloneApp.swift:57`. Remplacer :

```swift
    let schema = Schema([Project.self, TodoList.self, TaskItem.self])
```

par :

```swift
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
```

- [ ] **Step 6 : Lancer les tests, vérifier qu'ils passent**

Run: `swift test --filter SubtaskTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 7 : Commit**

```bash
git add Sources/ThingsClone/Models/Subtask.swift Sources/ThingsClone/Models/TaskItem.swift Sources/ThingsClone/ThingsCloneApp.swift Tests/ThingsCloneTests/SubtaskTests.swift
git commit -m "Modèle Subtask + relation cascade sur TaskItem"
```

---

### Task 2 : Généraliser `TaskCheckbox` (variante ronde)

**Files:**
- Modify: `Sources/ThingsClone/Views/TaskList/TaskListView.swift:2291` (struct `TaskCheckbox`)

**Interfaces:**
- Consumes: rien de nouveau.
- Produces: `TaskCheckbox` devient **internal** (plus `private`) avec un paramètre `circular: Bool = false`. Signature : `TaskCheckbox(isCompleted: Bool, circular: Bool = false, onToggle: () -> Void)`.

- [ ] **Step 1 : Remplacer la struct `TaskCheckbox`**

Modify `Sources/ThingsClone/Views/TaskList/TaskListView.swift`. Remplacer toute la struct `private struct TaskCheckbox: View { … }` (à partir de la ligne 2291) par :

```swift
struct TaskCheckbox: View {
  let isCompleted: Bool
  /// Sous-tâche = cercle ; tâche = rectangle arrondi (défaut). Même case, seule la forme change :
  /// on ne duplique pas le tracé du check animé, le bounce ni le curseur main.
  var circular: Bool = false
  var onToggle: () -> Void

  private static let size: CGFloat = 16
  private var shape: AnyShape {
    circular
      ? AnyShape(Circle())
      : AnyShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
  }

  var body: some View {
    Button(action: onToggle) {
      shape
        .fill(isCompleted ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
        // Bordure et check coexistent en permanence (opacité / trim pilotés par isCompleted) :
        // pas de `if` qui insère/retire une vue, sinon le trim n'aurait rien à animer.
        .overlay {
          shape
            .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
            .opacity(isCompleted ? 0 : 1)
        }
        .overlay {
          // `.trim` = strokeEnd de Core Animation exposé en SwiftUI : le trait se *trace*
          // (0→1) au lieu d'apparaître. lineCap/Join .round pour la même douceur que Things.
          Checkmark()
            .trim(from: 0, to: isCompleted ? 1 : 0)
            .stroke(
              .white,
              style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            )
            .frame(width: Self.size * 0.55, height: Self.size * 0.55)
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
    }
    // Bounce au press/release (l'état pressé du bouton, pas la pression trackpad) via un
    // ButtonStyle dédié ; le tracé + le fond restent animés par le withAnimation de la page.
    .buttonStyle(PressBounceButtonStyle())
    .animation(.bouncy(duration: 0.3, extraBounce: 0.15), value: isCompleted)
    // PAS `.onHover` + `NSCursor.set()` : cette case vit DANS une ligne qui a déjà son propre
    // `.onHover` ; deux zones de survol SwiftUI imbriquées se disputent les événements. Les cursor
    // rects AppKit sont résolus par la fenêtre à partir de la géométrie : aucun conflit.
    .overlay { PointingHandCursorArea().allowsHitTesting(false) }
  }
}
```

- [ ] **Step 2 : Compiler**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` — le paramètre `circular` a une valeur par défaut, les appels existants (`TaskCheckbox(isCompleted:onToggle:)`) restent valides.

- [ ] **Step 3 : Vérifier visuellement (non-régression)**

Run: `./run.sh && open ThingsClone.app`
Vérifier : les cases des tâches sont **inchangées** (rectangle arrondi), la coche s'anime et bounce comme avant.

- [ ] **Step 4 : Commit**

```bash
git add Sources/ThingsClone/Views/TaskList/TaskListView.swift
git commit -m "TaskCheckbox : variante ronde réutilisable (paramètre circular)"
```

---

### Task 3 : `SubtaskRowView`

**Files:**
- Create: `Sources/ThingsClone/Views/TaskList/SubtaskRowView.swift`

**Interfaces:**
- Consumes: `Subtask` (Task 1), `TaskCheckbox(isCompleted:circular:onToggle:)` (Task 2).
- Produces: `SubtaskRowView(subtask: Subtask, isEditing: Bool, focus: FocusState<PersistentIdentifier?>.Binding, onEnter: () -> Void, onDeleteEmpty: () -> Void)`.

- [ ] **Step 1 : Créer la vue**

Create `Sources/ThingsClone/Views/TaskList/SubtaskRowView.swift` :

```swift
import SwiftData
import SwiftUI

/// Une sous-tâche dans la carte d'une `TaskItem` : case RONDE + titre. La case fonctionne au repos
/// comme en édition ; le titre n'est éditable qu'en édition (au repos il est en lecture seule, seule
/// la coche agit). Aligné sous le titre de la tâche par le retrait porté côté `TaskRow`.
struct SubtaskRowView: View {
  @Bindable var subtask: Subtask
  let isEditing: Bool
  /// Focus partagé avec `TaskRow`, clé = identifiant persistant de la sous-tâche (pour poser le
  /// focus sur celle qu'on vient de créer).
  @FocusState.Binding var focus: PersistentIdentifier?
  /// Entrée dans le champ (ajouter la suivante / terminer — logique côté `TaskRow`).
  var onEnter: () -> Void
  /// Retour arrière sur un champ vide (supprimer — logique côté `TaskRow`).
  var onDeleteEmpty: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      TaskCheckbox(isCompleted: subtask.isDone, circular: true) {
        subtask.isDone.toggle()
      }

      if isEditing {
        TextField("Sous-tâche", text: $subtask.title)
          .textFieldStyle(.plain)
          .focused($focus, equals: subtask.persistentModelID)
          .onSubmit(onEnter)
          // Retour arrière sur un champ vide → supprimer (sinon laisser le champ effacer un
          // caractère). `.delete` = la touche Retour arrière (0x7F), pas la suppression avant.
          .onKeyPress(.delete) {
            guard subtask.title.isEmpty else { return .ignored }
            onDeleteEmpty()
            return .handled
          }
      } else {
        Text(subtask.title)
          .strikethrough(subtask.isDone)
          .foregroundStyle(subtask.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      }
    }
    .font(.body)
  }
}
```

- [ ] **Step 2 : Compiler**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` (la vue compile ; elle n'est pas encore utilisée — avertissement éventuel toléré).

- [ ] **Step 3 : Commit**

```bash
git add Sources/ThingsClone/Views/TaskList/SubtaskRowView.swift
git commit -m "SubtaskRowView : case ronde + titre (lecture seule au repos, éditable en édition)"
```

---

### Task 4 : Afficher les sous-tâches + ajout via l'icône + enchaînement Entrée

**Files:**
- Modify: `Sources/ThingsClone/Views/TaskList/TaskListView.swift` (struct `TaskRow` : env, état focus, section de rendu, helpers d'ajout, icône `list.bullet`)

**Interfaces:**
- Consumes: `SubtaskRowView` (Task 3), `TaskItem.addSubtask()` / `orderedSubtasks` (Task 1).
- Produces: sous-tâches affichées et cochables au repos ; l'icône `list.bullet` en édition ajoute une sous-tâche et pose le focus ; Entrée enchaîne / termine.

- [ ] **Step 1 : Ajouter `modelContext` et l'état de focus à `TaskRow`**

Modify `Sources/ThingsClone/Views/TaskList/TaskListView.swift`. Juste après `@Environment(RemindersService.self) private var remindersService` de `TaskRow` (ligne 1594) :

```swift
  @Environment(\.modelContext) private var modelContext
  /// Focus de la sous-tâche en cours d'édition (clé = identifiant persistant), pour poser le focus
  /// sur celle qu'on vient de créer.
  @FocusState private var focusedSubtask: PersistentIdentifier?
```

- [ ] **Step 2 : Insérer la section des sous-tâches dans l'arbre de vue**

Dans le `body` de `TaskRow`, repérer la ligne (aperçu de note) :

```swift
      if !isEditing && !task.notes.isEmpty { notePreview }
```

Insérer JUSTE APRÈS (donc hors du bloc `if showEditor`, pour un affichage au repos) :

```swift
      // Sous-tâches : affichées dépliées sous la tâche, au repos comme en édition (PAS dans le
      // corps révélé `editorBody`, pour ne pas perturber l'animation pilule → carte). Rien si aucune.
      if !task.orderedSubtasks.isEmpty { subtasksSection }
```

- [ ] **Step 3 : Ajouter la vue `subtasksSection` et les helpers d'ajout à `TaskRow`**

Ajouter dans `TaskRow` (par ex. juste avant `private var noteHint`) :

```swift
  private var subtasksSection: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(task.orderedSubtasks) { subtask in
        SubtaskRowView(
          subtask: subtask,
          isEditing: isEditing,
          focus: $focusedSubtask,
          onEnter: { enterOnSubtask(subtask) },
          onDeleteEmpty: {}  // branché en Task 5
        )
      }
    }
    // Aligné sous le titre (case 16 + espace 10 = 26), comme l'aperçu de note.
    .padding(.leading, 26)
    .padding(.top, 4)
  }

  /// Icône checklist : crée une sous-tâche vide et pose le focus dessus.
  private func addNewSubtask() {
    focusedSubtask = task.addSubtask().persistentModelID
  }

  /// Entrée sur une sous-tâche : vide → termine (défocalise) ; non vide → nouvelle sous-tâche + focus.
  /// ponytail: la nouvelle va toujours en FIN (pas d'insertion au milieu) — sans réordonnancement,
  /// le flux « taper, Entrée, taper » reste toujours sur la dernière, donc « en dessous » en pratique.
  private func enterOnSubtask(_ subtask: Subtask) {
    if subtask.title.trimmingCharacters(in: .whitespaces).isEmpty {
      focusedSubtask = nil
    } else {
      focusedSubtask = task.addSubtask().persistentModelID
    }
  }
```

- [ ] **Step 4 : Câbler l'icône `list.bullet`**

Repérer dans `editorBody` (ligne ~1808) :

```swift
        actionIcon("list.bullet")
```

Remplacer par :

```swift
        Button(action: addNewSubtask) {
          actionIcon("list.bullet", active: !task.subtasks.isEmpty)
        }
        .buttonStyle(.plain)
```

- [ ] **Step 5 : Compiler**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6 : Vérifier visuellement**

Run: `./run.sh && open ThingsClone.app`
Vérifier, sur une tâche ouverte en édition :
1. Cliquer l'icône checklist (`list.bullet`) → une sous-tâche vide à **case ronde** apparaît avec le focus.
2. Taper un titre, **Entrée** → une nouvelle sous-tâche vide apparaît, focus dessus.
3. **Entrée** sur une ligne vide → l'ajout se termine (le focus quitte).
4. Cocher une sous-tâche → coche animée (rond), le titre se barre.
5. Fermer la tâche (Entrée sur le titre / clic ailleurs), la rouvrir : les sous-tâches non vides **persistent** et restent cochables **au repos**.

- [ ] **Step 7 : Commit**

```bash
git add Sources/ThingsClone/Views/TaskList/TaskListView.swift
git commit -m "Affiche les sous-tâches sous la tâche + ajout clavier via l'icône checklist"
```

---

### Task 5 : Suppression (Retour arrière) + purge des vides à la fermeture

**Files:**
- Modify: `Sources/ThingsClone/Views/TaskList/TaskListView.swift` (struct `TaskRow` : callback `onDeleteEmpty`, helper `deleteSubtask`, purge dans `.onChange(of: isEditing)`)

**Interfaces:**
- Consumes: `focusedSubtask`, `modelContext`, `subtasksSection` (Task 4).
- Produces: Retour arrière sur une sous-tâche vide la supprime et refocalise la précédente ; les sous-tâches vides sont purgées à la sortie d'édition.

- [ ] **Step 1 : Brancher `onDeleteEmpty` sur un vrai helper**

Dans `subtasksSection` (Task 4), remplacer :

```swift
          onDeleteEmpty: {}  // branché en Task 5
```

par :

```swift
          onDeleteEmpty: { deleteSubtask(subtask) }
```

- [ ] **Step 2 : Ajouter le helper `deleteSubtask`**

Ajouter dans `TaskRow`, à côté de `enterOnSubtask` :

```swift
  /// Retour arrière sur une sous-tâche vide : la supprime et refocalise la précédente (ou rien).
  private func deleteSubtask(_ subtask: Subtask) {
    let ordered = task.orderedSubtasks
    let index = ordered.firstIndex { $0.persistentModelID == subtask.persistentModelID }
    modelContext.delete(subtask)
    if let index, index > 0 {
      focusedSubtask = ordered[index - 1].persistentModelID
    } else {
      focusedSubtask = nil
    }
  }
```

- [ ] **Step 3 : Purger les sous-tâches vides à la fermeture**

Repérer, dans `.onChange(of: isEditing)` de `TaskRow`, la branche `else` (ligne ~1742). Juste après `focusNotesOnAppear = false` (ligne 1744), ajouter :

```swift
        // Purge des sous-tâches au titre vide : on ne persiste jamais une ligne vide (comme les
        // brouillons de nouvelle tâche).
        for subtask in task.subtasks
        where subtask.title.trimmingCharacters(in: .whitespaces).isEmpty {
          modelContext.delete(subtask)
        }
```

- [ ] **Step 4 : Compiler**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5 : Vérifier visuellement**

Run: `./run.sh && open ThingsClone.app`
Vérifier, sur une tâche en édition avec plusieurs sous-tâches :
1. Placer le curseur dans une sous-tâche, tout effacer, **Retour arrière** sur le champ vide → la sous-tâche disparaît, le focus remonte sur la précédente.
2. Ajouter une sous-tâche vide (icône) puis fermer la tâche sans rien taper → à la réouverture, **aucune ligne vide** n'a été persistée.
3. Un titre non vide n'est jamais supprimé par le Retour arrière (il efface un caractère normalement).

- [ ] **Step 6 : Commit**

```bash
git add Sources/ThingsClone/Views/TaskList/TaskListView.swift
git commit -m "Sous-tâches : suppression au Retour arrière + purge des vides à la fermeture"
```

---

## Self-Review

**Couverture du spec :**
- Modèle `Subtask` dédié + relation cascade → Task 1. ✓
- Couplage nul (aucun lien isCompleted ↔ isDone) → aucun code de couplage écrit nulle part. ✓
- Checklist dépliée + cochable au repos → Task 4, Step 2 (rendu hors `if showEditor`) + `SubtaskRowView` (case active au repos). ✓
- Ajout clavier via `list.bullet` + Entrée enchaîne/termine → Task 4. ✓
- Renommer en édition seulement, lecture seule au repos → `SubtaskRowView` (`if isEditing` TextField / Text). ✓
- Suppression Retour arrière + purge des vides → Task 5. ✓
- Réordonnancement reporté, `sortIndex` prêt → Task 1 (`sortIndex` stocké, pas de drag). ✓
- Case ronde réutilisant `TaskCheckbox` → Task 2. ✓
- Placement note (référence) puis sous-tâches (actionnable) → Task 4 Step 2 (inséré après `notePreview`). ✓

**Placeholders :** le `onDeleteEmpty: {}` de Task 4 est un intermédiaire explicitement remplacé en Task 5 (Step 1), pas un TODO abandonné.

**Cohérence des types :** `addSubtask() -> Subtask`, `focusedSubtask: PersistentIdentifier?`, `persistentModelID` (fourni par SwiftData), `TaskCheckbox(isCompleted:circular:onToggle:)` — noms cohérents entre les tâches.
