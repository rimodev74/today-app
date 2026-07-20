# Toolbar de liste, en-têtes inline, recherche globale, anneau de progression

Date : 2026-07-11

## Contexte

`TaskListView` affiche les tâches d'une smart list, d'un projet ou d'une zone,
avec un champ d'ajout de tâche inline en bas de la liste. On ajoute :

1. Une toolbar flottante en bas du body pour ajouter une tâche, ajouter une
   en-tête, et rechercher.
2. Un type d'en-tête inline dans les listes (séparateur visuel, comme les
   headings de Things).
3. Une recherche globale en modal qui navigue vers le résultat choisi.
4. Un anneau de progression dans le header de la vue projet.

## 1. Modèle — `TaskItem.isHeader`

Pas de nouveau modèle. Ajout d'un champ sur `TaskItem` :

```swift
var isHeader: Bool = false
```

Une en-tête est un `TaskItem` normal (mêmes `when` / `project` / `area`,
même tri par `createdAt`) avec `isHeader = true`. Elle s'intercale
naturellement dans les listes triées existantes — aucune logique de fusion
de deux sources de données.

Conséquences sur le code existant :
- `TaskRowView` : rendu différent si `isHeader` (voir §3).
- Comptage de progression (`Project`, §4) : exclut les `TaskItem` où
  `isHeader == true`.
- Une en-tête n'est jamais "complétée" (pas de checkbox, `isCompleted`
  reste `false` en permanence, jamais togglée).

## 2. Toolbar flottante

Nouvelle vue `ListToolbar`, insérée dans `TaskListView` via
`.safeAreaInset(edge: .bottom)` (même pattern que `SidebarView.bottomBar`).

Apparence : capsule (`Capsule`) avec fond `.regularMaterial`, **largeur au
contenu** (pas `maxWidth: .infinity`), centrée horizontalement en bas du
body, 3 boutons icône espacés à l'intérieur (`plus.circle` / en-tête / loupe).
Visible sur toutes les vues (smart lists, projets, zones).

Comportement des boutons :
- **Tâche** : donne le focus au champ "Nouvelle tâche..." déjà existant en
  bas de la liste (`TaskListView`), en mode tâche normale.
- **En-tête** : donne le focus au **même** champ, mais bascule un état
  `newItemIsHeader: Bool` à `true` pour ce prochain ajout. Le placeholder du
  champ change ("Nouvelle en-tête...") tant que ce mode est actif. À la
  soumission (`Enter`), crée un `TaskItem(isHeader: true)` au lieu d'une
  tâche normale, puis réinitialise `newItemIsHeader` à `false`.
- **Recherche** : ouvre la modal de recherche globale (`.sheet`).

Pas de nouveau champ de saisie dédié aux en-têtes : réutilisation du champ
existant pour éviter la duplication d'UI.

## 3. Rendu d'une en-tête (`TaskRowView`)

Quand `task.isHeader == true` :
- Pas de checkbox / cercle.
- `TextField` (borderless, comme le titre de projet) lié à `task.title`,
  police en gras, taille légèrement supérieure au texte de tâche normal —
  éditable directement, pas de mode édition séparé.
- `Divider()` gris en dessous de l'en-tête (séparateur visuel demandé).
- Pas de sous-titre "nom du projet" (n'a pas de sens pour une en-tête).

## 4. Recherche globale

Nouvelle vue `SearchModalView`, présentée en `.sheet` depuis `TaskListView`.

- `@Query` sur tous les `TaskItem` où `isHeader == false`, filtré côté vue
  par un `TextField` de recherche sur `title` (insensible à la casse).
- Liste de résultats cliquables. Cliquer un résultat :
  - ferme la modal,
  - navigue vers `.project(task.project)` si la tâche a un projet, sinon
    `.area(task.area)` si elle a une zone, sinon `.smartList(.inbox)` (les
    tâches sans conteneur vivent dans l'Inbox).
- Pour permettre cette navigation, `TaskListView.selection` passe de
  `let selection: SidebarSelection` à `@Binding var selection:
  SidebarSelection?`, et `ContentView` lui passe `$selection` au lieu de
  `selection`.

## 5. Anneau de progression (vue projet)

Dans `TaskListView.header`, cas `.project(let project)` : un cercle à
gauche du titre éditable.

- Calcul : `project.tasks.filter { !$0.isHeader }` → total ; sous-ensemble
  `isCompleted == true` → complété.
- Rendu : deux `Circle().trim(...)` superposés — anneau gris de fond
  (trait complet) + anneau coloré (`trim(to: completed/total)`), pas de
  texte au centre.
- Si `total == 0` : anneau vide (0%), toujours visible (pas de condition
  de masquage).
- Se met à jour automatiquement (SwiftData `@Bindable`/`@Query` déjà
  réactifs sur `isCompleted`).

## Hors périmètre

- Pas de headings dans les smart lists agrégées différemment des projets/
  zones — elles suivent le même mécanisme générique (`when`/`project`/
  `area`), aucun traitement spécial requis.
- Pas de réordonnancement drag & drop des en-têtes/tâches (hors sujet ici).
- Pas d'anneau de progression pour les zones (seulement demandé pour les
  projets).
