# Sous-tâches (checklist) — design

## Objectif

Ajouter des **sous-tâches** cochables à une `TaskItem`, en **cohabitation** avec les notes :
- Notes = contexte libre / référence (avec la liste à tirets déjà en place).
- Sous-tâches = entité à part, des **étapes qu'on coche**.

Cas d'usage : une tâche multi-étapes (« Dérushage des caméras Sony ») dont les étapes
(« Créer les dossiers », « Ranger les rushes ») deviennent des sous-tâches cochables plutôt
qu'un simple texte de note non actionnable.

## Décisions (verrouillées au brainstorm)

1. **Couplage : aucun.** Cocher une sous-tâche ne modifie jamais `task.isCompleted`, et cocher la
   tâche ne touche pas les sous-tâches. La checklist informe, l'utilisateur décide (comme Things).
2. **Affichage au repos : checklist dépliée et cochable.** Les sous-tâches s'affichent sous la
   tâche même fermée, et se cochent directement sans ouvrir la tâche.
3. **Ajout / édition : flux clavier façon Things.** L'icône `list.bullet` (aujourd'hui décorative)
   ajoute une première sous-tâche vide avec le focus ; Entrée enchaîne ; Retour arrière sur vide
   supprime.
4. **Réordonnancement : reporté** (itération 2). `sortIndex` stocké dès maintenant pour l'ajouter
   proprement plus tard, sans drag imbriqué pour le MVP.
5. **Renommer : uniquement en mode édition** de la tâche. Au repos, le titre est en lecture seule
   (seule la case fonctionne).

## Modèle de données

Nouveau `@Model` dédié (mirroir exact du pattern `TodoList` ↔ `TaskItem`) :

```swift
@Model final class Subtask {
  var title: String
  var isDone: Bool = false
  var sortIndex: Int = 0
  var createdAt: Date = Date()
  var task: TaskItem?

  init(title: String = "", task: TaskItem? = nil) { … }
}
```

Sur `TaskItem` :

```swift
@Relationship(deleteRule: .cascade, inverse: \Subtask.task) var subtasks: [Subtask] = []

/// Ordre manuel ; `createdAt` départage les ex æquo (même pattern que `TodoList.orderedTasks`).
var orderedSubtasks: [Subtask] {
  subtasks.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
}

/// Crée une sous-tâche vide en fin de liste et la renvoie (pour poser le focus dessus).
@discardableResult func addSubtask() -> Subtask { … }
```

**Alternatives rejetées :**
- *`TaskItem` avec `parent: TaskItem?`* — `TaskItem` est trop lourd (en-têtes, dates, priorité,
  rappels, `list`) et chaque requête `list.tasks` devrait exclure les sous-tâches : fuite garantie.
- *Blob `Codable` sur `TaskItem`* — reste un changement de schéma (donc même effacement de base),
  perd la requête SwiftData, et cocher une case ré-encoderait tout le tableau.

**Effacement de la base — nuancé :** `ThingsCloneApp.container` ne supprime le store *que si* son
ouverture avec le nouveau schéma **échoue** (fallback `try? ... else removeItem`). Or nos
changements sont **purement additifs** (nouvelle entité `Subtask` + relation optionnelle `subtasks`
défaut `[]`) — le type de changement que SwiftData sait faire en **migration légère automatique**,
même sans plan de migration. Donc l'ouverture devrait réussir et **les données être préservées**.
Non garanti à 100 % (le fallback efface si l'ouverture échoue). **Filet de sécurité :** le store a
été sauvegardé avant implémentation dans
`~/Library/Application Support/thingsclone-db-backup-2026-07-22/` (les 3 fichiers `.store`, `-shm`,
`-wal`) ; restauration par `cp` inverse si besoin.

## UI & interactions

### Case ronde

Généraliser `TaskCheckbox` (aujourd'hui `RoundedRectangle` cornerRadius 4.5) pour accepter la
**forme** (rectangle arrondi *ou* cercle), en réutilisant tout l'existant : tracé du check animé
(`.trim`), bounce au press, curseur main via cursor rects AppKit. Rond = sous-tâche, carré = tâche.
Pas de case dupliquée.

### `SubtaskRowView`

Une sous-tâche : case ronde + titre, aligné sous le titre de la tâche (retrait x = 26, comme
`notePreview`).
- **Au repos** : titre en `Text` lecture seule ; la case coche/décoche `isDone`. Coché → texte
  barré + couleur secondaire.
- **En édition** (la tâche parente est `isEditing`) : le titre devient un champ éditable (renommer).

### Placement dans `TaskRow`

Dans la partie **toujours montée** du `VStack` à arbre unique (PAS dans le `editorBody` révélé —
pour ne pas perturber l'animation pilule → carte) :

```
[ case | dateTag | titre | … | trailing ]     ← ligne titre (existant)
  – aperçu de note (référence)                 ← notePreview, si note (existant)
  ○ sous-tâche 1                               ← subtasks, si présentes (NOUVEAU)
  ○ sous-tâche 2
  [ editorBody révélé si édition ]             ← notesField + rangée d'icônes (existant)
```

Ordre : note d'abord (référence), sous-tâches ensuite (actionnable).

### Flux clavier (en édition)

- Icône **`list.bullet`** → `addSubtask()` + focus sur la nouvelle ligne vide.
- **Entrée** sur une sous-tâche non vide → en crée une nouvelle en dessous + focus.
- **Entrée** sur une ligne vide → la retire + termine le flux d'ajout.
- **Retour arrière** sur un champ vide → supprime la sous-tâche + focus sur la précédente.
- Focus géré par un `@FocusState` clé = identifiant persistant de la sous-tâche.

### Nettoyage

Les sous-tâches au titre vide sont purgées à la sortie d'édition (`onEndEditing`), comme les
brouillons de nouvelle tâche : on ne persiste jamais une ligne vide.

## Hors périmètre (assumé)

- Pas de drag-to-reorder (ordre = ordre d'ajout ; `sortIndex` prêt pour l'itération 2).
- Pas de sous-tâches imbriquées.
- Pas de date / priorité / rappel sur une sous-tâche.
- Pas de badge de progression compact au repos (on affiche la liste dépliée, pas un « 1/3 »).

## Tests

- `Subtask` / `TaskItem` : `orderedSubtasks` trie par `sortIndex` puis `createdAt` ;
  `addSubtask()` ajoute en fin et renvoie l'objet ; suppression en cascade (`deleteRule: .cascade`)
  vérifiée à la suppression d'une `TaskItem`.
- Purge des sous-tâches vides à la sortie d'édition.
- (Interactions clavier / focus : vérifiées à l'œil via `./run.sh`, comme le reste de l'UI.)
