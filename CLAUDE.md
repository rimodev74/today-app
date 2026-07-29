# Today

Clone natif macOS de Things (Cultured Code). Scope, décisions et découpage : `ROADMAP.md`.
SwiftPM (pas de `.xcodeproj`), SwiftUI + SwiftData, ~7 400 lignes dans `Sources/Today/`
(+ ~570 de tests). Le produit s'appelle **Today** ; « ThingsClone » ne survit que dans le nom
de `ThingsCloneApp.swift`.

## Lancer

```bash
./run.sh          # build → bundle .app → open. Le seul moyen correct de lancer l'app.
swift build       # compilation seule (~0,2 s incrémental)
swift test        # 49 tests, tous en mémoire — aucun ne touche le store sur disque
```

**Jamais `swift run`.** L'exécutable nu n'est pas un bundle : macOS ne lui applique pas la
chrome de fenêtre native (coins arrondis, barre de titre) et l'app ne ressemble à rien.
`Scripts/make-app.sh` fabrique le bundle + Info.plist + signature ad-hoc.

## Pièges de ce projet

- **Le minimum macOS n'est pas vérifié par le build.** `Package.swift` déclare `.macOS(.v14)`
  mais `swift build` compile pour l'hôte (macOS 26). Une API `@available(macOS 15+)` compile
  sans broncher et casserait sur une vraie cible 14. À vérifier à l'œil.
- **Le store contient de la VRAIE donnée**, pas des jeux d'essai — et il vit à la racine de
  `~/Library/Application Support/` (`default.store`), sans sous-dossier au nom du bundle id.
  Le compter avant d'y toucher : `sqlite3 default.store "select count(*) from ZTASKITEM;"`.
- **Changer un `@Model` ne détruit plus la base.** Le store passe par `TodayMigrationPlan`
  (cf. `Models/TodaySchema.swift`) : additif → SwiftData migre seul ; cassant (renommer,
  supprimer, changer un type) → il FAUT une `SchemaV2` et une étape, la marche à suivre est
  écrite dans le fichier. En dernier recours le store est mis de côté sous un nom horodaté
  (`StoreQuarantine`), jamais supprimé.
- **`swift build` qui passe ne veut pas dire que ça marche.** L'essentiel des bugs ici sont des
  bugs de layout et d'interaction, invisibles au compilateur. Un changement d'UI se vérifie en
  lançant `./run.sh` et en regardant — **dans les deux thèmes** : les régressions de mode sombre
  sont la rechute la plus fréquente du projet (couleurs figées en dur, cf. ci-dessous).

## Conventions

- **Natif d'abord, toujours.** Les régressions de ce projet viennent toutes de réimplémentations
  de ce que macOS fait déjà. Si l'API native ne convient pas, dire pourquoi en commentaire avant
  d'écrire du custom (cf. `TaskCheckbox` dans `TaskListView.swift`, ou le choix assumé de
  `ScrollView` + `LazyVStack` contre `List` dans `ListPageView`).
- **Une couleur figée se double.** Quand une valeur de maquette s'impose (fond opaque, calque de
  drag), passer par `NSColor(name:) { appearance in … }` avec sa version sombre — le motif est
  déjà là dans `SidebarView.rowFill`, `thingsSelectionFill` et `HeaderRow.dragLayer`. Une
  `Color(red:…)` nue est un bug de mode sombre en attente.
- **Les commentaires disent *pourquoi*, jamais *quoi*.** Ce code documente des pièges macOS non
  évidents (le préchauffage du field editor au lancement, le gel des `rowFrames` pendant un drag,
  l'image tabulaire du `MenuBarExtra`). C'est le standard : le tenir.
- **En français**, comme le reste du code.
- `// ponytail:` marque une simplification délibérée et son plafond.
- Pas de trailer `Co-Authored-By` ni de mention d'outil dans les commits.

## Outils

- **sourcekit-lsp est installé** et couvre les `.swift`. Utiliser les outils `lsp_*`
  (`lsp_diagnostics`, `lsp_goto_definition`, `lsp_find_references`, `lsp_hover`) plutôt que de
  deviner un type ou de grep des références à la main.
- Formatage : `xcrun swift-format -i -r Sources` (pas de config, valeurs par défaut).
- Publier : `./Scripts/quick.sh "message"` (bump + DMG signé + release + appcast + push).

## État réel

Ce qui marche : listes, tâches, en-têtes de section, réordonnancement (tâches ET blocs
d'en-tête), renommage, complétion, projets, sous-tâches, notes en texte riche, saisie rapide
(`@demain`, `#liste`), archivage, pomodoro, rappels Apple, recherche (`QuickFindPanel`), pages
**Aujourd'hui** et **Archives**.

Encore du décor — le vérifier avant de le présenter comme fini :

- vues intelligentes **Tâches** et **À venir** : stubs `comingSoon` ;
- l'icône **tag** de la carte d'édition ne fait rien (le modèle ne porte pas de tags) ; les trois
  autres (date, checklist, priorité) sont branchées ;
- `TaskItem.hasTime` est écrit mais jamais lu : la saisie rapide et les sélecteurs ne posent que
  des jours, pas des heures.
