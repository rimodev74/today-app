# Notes riches : liens, gras/italique, couleur d'en-tête

Date : 2026-07-20

## Contexte

Les notes de tâche, de liste et de projet sont aujourd'hui du texte brut
(`notes: String` sur `TaskItem`, `TodoList`, `Project`), édité via
`AutoGrowingTextEditor` (tâche/liste) ou une simple `TextField` (projet).
Objectif : liens cliquables avec annulation/rétablissement, mise en forme
gras/italique sur sélection, et couleur personnalisable par en-tête de
section dans la liste de tâches.

## A. Stockage — `notes: String` → `notes: Data` (RTF)

`TaskItem.notes`, `TodoList.notes`, `Project.notes` passent de `String` à
`Data`, encodée/décodée en RTF via `NSAttributedString`. Un changement de
type de champ `@Model` efface la base locale au prochain lancement (pitfall
déjà documenté dans `CLAUDE.md`) — accepté, données de dev jetables.

Une note vide est stockée comme `Data()` exactement (pas un RTF d'une chaîne
vide) : les tests `.isEmpty` existants sur `notes` (placeholder, aperçu
tronqué, etc.) continuent de fonctionner sans changement de forme.

## B. `RichTextEditor` — remplace `AutoGrowingTextEditor`

Même wrapper `NSViewRepresentable`, binding `@Binding var data: Data` (pas de
binding `NSAttributedString` exposé à l'appelant — la conversion RTF↔attribué
reste interne au composant, donc les 3 sites d'appel gardent une forme
d'usage quasi identique à aujourd'hui). Réglages supplémentaires vs.
l'éditeur actuel : `isRichText = true`, `isAutomaticLinkDetectionEnabled =
true`.

Remplace :
- `AutoGrowingTextEditor` pour les notes de tâche (TaskListView.swift:1289)
- `AutoGrowingTextEditor` pour les notes de liste (TaskListView.swift:865)
- la `TextField("Notes", text: $project.notes, axis: .vertical)` des notes de
  projet (TaskListView.swift:1042), qui n'était pas encore un éditeur riche

L'aperçu tronqué d'une ligne sous une tâche au repos (TaskListView.swift:1182,
`Text(task.notes)`) passe par le texte brut décodé (`.string` de
l'`NSAttributedString`) — pas de mise en forme dans l'aperçu, seulement dans
l'édition.

## C. Liens

- Détection automatique au fil de la frappe (`isAutomaticLinkDetectionEnabled`) :
  une URL tapée devient cliquable sans action de l'utilisateur.
- `Cmd+K` sur une sélection ouvre le panneau natif AppKit
  (`NSTextView.orderFrontLinkPanel(_:)`) : ajouter, modifier ou **retirer**
  un lien, avec champ URL — même mécanisme que Mail/Notes/TextEdit.
- Clic droit sur un lien existant : « Supprimer le lien » (menu contextuel
  natif de NSTextView en mode rich text).
- Ouverture d'un lien : Cmd+clic (comportement standard AppKit en mode
  éditable — un clic simple placerait le curseur).

Aucun état de survol personnalisé, aucun hit-testing manuel : tout vient de
la configuration native de `NSTextView`.

## D. Gras / italique

Ajout de `.commands { TextFormattingCommands() }` sur la `Scene` de
`ThingsCloneApp.swift`. Ce groupe de commandes SwiftUI natif ajoute le menu
Format et câble `Cmd+B` / `Cmd+I` vers le premier répondeur — que
`RichTextEditor` (rich text) gère déjà nativement. Aucune logique de
formatage écrite à la main.

## E. Couleur d'en-tête

Nouveau champ `TaskItem.headerColorHex: String?` (`nil` = style actuel,
lavande/accent). Le menu ••• existant de `HeaderRow` (TaskListView.swift,
struct `HeaderRow`, actuellement juste « Supprimer ») gagne une entrée
« Couleur » → sous-menu d'environ 7 pastilles prédéfinies + « Par défaut »
(remet `nil`). La pilule (fond) et le titre de l'en-tête (`TextField`)
utilisent cette teinte quand elle est définie ; sinon comportement actuel
inchangé.

## Hors scope

- Pas de migration des données existantes (base locale effacée, accepté).
- Pas de barre d'outils de mise en forme flottante : uniquement `Cmd+B`/`Cmd+I`
  et le menu Format natif.
- Pas de couleur personnalisée libre pour l'en-tête (palette fermée, pas de
  `ColorPicker`).
