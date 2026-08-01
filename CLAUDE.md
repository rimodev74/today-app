# Today

Clone natif macOS de Things (Cultured Code). Scope, décisions et découpage : `ROADMAP.md`.
SwiftPM (pas de `.xcodeproj`), SwiftUI + SwiftData, ~11 200 lignes dans `Sources/Today/`
(+ ~1 460 de tests). Le produit s'appelle **Today** ; « ThingsClone » ne survit que dans le nom
de `ThingsCloneApp.swift`.

## Lancer

```bash
./run.sh          # build → bundle .app → open. Le seul moyen correct de lancer l'app.
swift build       # compilation seule (~0,2 s incrémental)
swift test        # 110 tests, en mémoire ou sur un store temporaire — jamais la vraie base
```

**Jamais `swift run`.** L'exécutable nu n'est pas un bundle : macOS ne lui applique pas la
chrome de fenêtre native (coins arrondis, barre de titre) et l'app ne ressemble à rien.
`Scripts/make-app.sh` fabrique le bundle + Info.plist + signature, et REFUSE de tourner si une
instance de Today est en cours : reconstruire sous ses pieds lui retire son Info.plist, la première
lecture CFBundle lève une exception, et l'app meurt en « Abort trap: 6 » sans aucun rapport avec le
code qu'on vient d'écrire. C'était LE plantage fantôme de la phase de dev.

## Architecture — ce qui porte le reste

Quatre pièces tiennent des invariants que rien d'autre ne garantit. Les modifier demande de lire
leur en-tête AVANT d'écrire.

| Pièce | Rôle | Ce qu'elle a remplacé |
|---|---|---|
| `Models/Reorder.swift` | l'arithmétique du glissement : repli, écartement, trou, ordre obtenu | la page de liste et la sidebar recalculaient la même chose chacune de son côté, sans le savoir |
| `Models/TaskFocus.swift` | quelle ligne est sélectionnée, laquelle est en édition | trois pages pilotaient deux `@State` nus avec les mêmes cinq transitions recopiées |
| `Models/TodaySchema.swift` + `Tests/TodayTests/SchemaV1Snapshot.swift` | la forme des données, écrite deux fois et confrontée à chaque `swift test` | rien — un `@Model` cassé vidait sa colonne en silence (cf. Pièges) |
| `TodayApp.openStore` | l'unique façon d'ouvrir un store | deux chemins d'ouverture, dont un que les tests ne couvraient pas |

Les pages de tâches (`ListPageView`, `TodayPageView`, `AllTasksPageView`) partagent en plus
`TaskRow`, `RowPressGesture`, les courbes `taskFlow`/`taskSelectFade`/`taskInsert` et les métriques
`gutter`/`rowInset`. Une quatrième page se construit AVEC ces briques, jamais à côté d'elles.

## Pièges de ce projet

- **Le minimum macOS n'est pas vérifié par le build.** `Package.swift` déclare `.macOS(.v14)`
  mais `swift build` compile pour l'hôte. Une API `@available(macOS 15+)` compile sans broncher et
  casserait sur une vraie cible 14. À vérifier à l'œil.
- **Le store contient de la VRAIE donnée**, pas des jeux d'essai — et il vit à la racine de
  `~/Library/Application Support/` (`default.store`), sans sous-dossier au nom du bundle id.
  Le compter avant d'y toucher : `sqlite3 default.store "select count(*) from ZTASKITEM;"`.
- **Un `@Model` modifié peut vider une colonne sans un mot.** `CurrentSchema` pointe les classes
  VIVANTES et son numéro de version ne bouge pas tout seul. Un ajout est absorbé sans rien faire ;
  un renommage, une suppression ou un changement de type laisse `swift build` passer, laisse le
  store s'ouvrir SANS erreur, et perd la donnée — mesuré, pas supposé. Ni quarantaine ni alerte.
  Le seul garde-fou est `SchemaCompatibilityTests` : **rouge ⇒ ne pas lancer l'app**, et suivre les
  cinq points en tête de `TodaySchema.swift`.
- **EventKit rend des optionnels implicites.** `EKEvent.startDate`, `EKCalendarItem.calendar`,
  `EKCalendar.cgColor`, `.title` sont `null_unspecified` : les lire sans garde plante sur un
  calendrier d'abonnement mal formé. Filtrer À L'ENTRÉE, dans `RemindersService`, jamais chez chaque
  appelant.
- **`swift build` qui passe ne veut pas dire que ça marche.** L'essentiel des bugs ici sont des
  bugs de layout et d'interaction, invisibles au compilateur. Un changement d'UI se vérifie en
  lançant `./run.sh` et en regardant — **dans les deux thèmes** : les régressions de mode sombre
  sont la rechute la plus fréquente du projet (couleurs figées en dur, cf. Conventions).
- **Un plantage sans message se lit dans le journal.** `CrashLog` installe un gestionnaire
  d'exceptions non rattrapées, parce que le rapport système garde la pile mais PAS la raison :
  `log show --last 1h --predicate 'process == "Today"' | grep PLANTAGE`.

## Conventions

- **Natif d'abord, toujours.** Les régressions de ce projet viennent toutes de réimplémentations
  de ce que macOS fait déjà. Si l'API native ne convient pas, dire pourquoi en commentaire avant
  d'écrire du custom (cf. `TaskCheckbox` dans `TaskListView.swift`, ou le choix assumé de
  `ScrollView` + `LazyVStack` contre `List` dans `ListPageView`).
- **La logique non triviale sort de la vue, et elle est testée.** Un calcul d'indices, une machine à
  états, un parseur, une règle de tri n'ont rien à faire dans un `struct: View` : mêlés à `@State` et
  `@Query`, ils ne se vérifient qu'en cliquant, donc on ne les vérifie pas, donc on n'ose plus y
  toucher. Ils vont dans `Models/` — type de valeur, sans SwiftUI — avec leur fichier de tests. C'est
  le cas de `Reorder`, `TaskFocus`, `QuickEntry`, `DayCapacity`, `Dormancy`, `NoteList`,
  `CompletedTaskRetention`. **Une vue orchestre et anime ; elle ne calcule pas.**
- **Avant d'ajouter un `@State`, chercher le type qui porte déjà ce comportement.** Un second état
  pour une notion existante (sélection, édition, brouillon, glissement) est exactement la façon dont
  deux pages se mettent à diverger sans que personne ne le voie.
- **Une couleur figée se double.** Quand une valeur de maquette s'impose (fond opaque, calque de
  drag), passer par `NSColor(name:) { appearance in … }` avec sa version sombre — le motif est
  déjà là dans `SidebarView.rowFill`, `thingsSelectionFill` et `HeaderRow.dragLayer`. Une
  `Color(red:…)` nue est un bug de mode sombre en attente.
- **Ce qui s'installe se démonte.** Moniteur `NSEvent`, observateur `NotificationCenter`, `Timer` :
  chacun a son `removeMonitor` / `removeObserver` / `invalidate` sur le chemin de sortie
  (`dismantleNSView`, `onDisappear`). Le motif est appliqué partout dans le projet — le tenir.
- **Les commentaires disent *pourquoi*, jamais *quoi*.** Ce code documente des pièges macOS non
  évidents (le préchauffage du field editor au lancement, le gel des `rowFrames` pendant un drag,
  l'image tabulaire du `MenuBarExtra`). C'est le standard : le tenir.
- **Un nom qui ment coûte plus cher qu'un commentaire manquant.** Si la documentation d'un type
  existe pour démentir son propre nom, c'est le nom qu'il faut changer — cf. l'ancien `SchemaV1`,
  qui s'annonçait figé tout en pointant les modèles vivants, devenu `CurrentSchema`.
- **En français.** Identifiants en anglais, commentaires et documentation en français.
- `// ponytail:` marque une simplification délibérée et son plafond.
- Pas de trailer `Co-Authored-By` ni de mention d'outil dans les commits.

## Outils

- **sourcekit-lsp est installé** et couvre les `.swift`. Utiliser les outils `lsp_*`
  (`lsp_diagnostics`, `lsp_goto_definition`, `lsp_find_references`, `lsp_hover`) plutôt que de
  deviner un type ou de grep des références à la main. Attention : après création ou renommage d'un
  fichier, son index met un moment à se rafraîchir et remonte des erreurs fantômes —
  **`swift build` fait foi, pas les diagnostics**.
- **Un `swift build` incrémental ne montre pas les warnings des fichiers qu'il ne recompile pas.**
  Un build à 0,2 s n'a rien vérifié du reste du module. Avant de dire qu'une modification est
  propre : `find Sources Tests -name '*.swift' -exec touch {} +` puis `swift build && swift test`
  — et `-c release`, qui compile en module entier et sort des diagnostics que le debug tait.
- Formatage : `xcrun swift-format -i -r Sources Tests` (pas de config, valeurs par défaut).
- Publier : `./Scripts/quick.sh "message"` (bump + DMG signé + release + appcast + push).

## État réel

Ce qui marche : listes, tâches, en-têtes de section, réordonnancement (tâches ET blocs d'en-tête),
renommage, complétion, projets, sous-tâches, notes en texte riche, saisie rapide (`@demain`,
`#liste`), raccourcis texte et combinaisons globales, archivage, pomodoro, rappels et calendrier
Apple (lecture + report de complétion), recherche (`QuickFindPanel`), capsule de saisie rapide hors
app, et les quatre pages intelligentes — **Tâches**, **Aujourd'hui**, **À venir**, **Archives** —
toutes réelles.

Encore du décor — le vérifier avant de le présenter comme fini :

- l'icône **tag** de la carte d'édition ne fait rien (le modèle ne porte pas de tags) ; les trois
  autres (date, checklist, priorité) sont branchées ;
- `TaskItem.hasTime` est bien LU (par `UpcomingPageView`, pour l'heure affichée) mais rien ne le met
  jamais à `true` : ni la saisie rapide ni les sélecteurs ne posent d'heure, seulement des jours ;
- la barre de capacité d'« Aujourd'hui » est écrite mais masquée (`ponytail:` dans `TodayPageView`).

Dette connue, par ordre de coût :

1. `TaskListView.swift` fait encore ~3 400 lignes. Ce n'est pas sa taille le problème, mais ce
   qu'elle mélange : `TaskRow`, `HeaderRow`, la barre d'outils et les quatre `NSViewRepresentable`
   en sortiraient sans rien casser.
2. `Package.swift` est en `swift-tools-version: 5.10` — mode langage Swift 5, concurrence stricte
   NON vérifiée. Les `@MainActor` sont tenus à la main (cf. le rappel Carbon de `GlobalHotKey`, qui
   appelle du code isolé depuis une classe qui ne l'est pas). Ça marche ; rien ne le garantit.
3. `StoreQuarantine` est un filet de secours, pas une sauvegarde : rien ne copie la base avant une
   migration.
