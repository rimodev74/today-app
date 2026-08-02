# Today

Clone natif macOS de Things (Cultured Code). Scope, décisions et découpage : `ROADMAP.md`.
SwiftPM (pas de `.xcodeproj`), SwiftUI + SwiftData, ~12 200 lignes dans `Sources/Today/`
(+ ~2 270 de tests). Le produit s'appelle **Today** ; « ThingsClone » ne survit que dans le nom
de `ThingsCloneApp.swift`.

## Lancer

```bash
./run.sh          # build → bundle .app → open. Le seul moyen correct de lancer l'app.
swift build       # compilation seule (~0,2 s incrémental)
swift test        # 159 tests, en mémoire ou sur un store temporaire — jamais la vraie base
```

**Jamais `swift run`.** L'exécutable nu n'est pas un bundle : macOS ne lui applique pas la
chrome de fenêtre native (coins arrondis, barre de titre) et l'app ne ressemble à rien.
`Scripts/make-app.sh` fabrique le bundle + Info.plist + signature, et REFUSE de tourner si une
instance de Today est en cours : reconstruire sous ses pieds lui retire son Info.plist, la première
lecture CFBundle lève une exception, et l'app meurt en « Abort trap: 6 » sans aucun rapport avec le
code qu'on vient d'écrire. C'était LE plantage fantôme de la phase de dev.

## Architecture — ce qui porte le reste

Ces pièces tiennent des invariants que rien d'autre ne garantit. Les modifier demande de lire
leur en-tête AVANT d'écrire.

| Pièce | Rôle | Ce qu'elle a remplacé |
|---|---|---|
| `Models/Reorder.swift` | l'arithmétique du glissement : repli, écartement, trou, ordre obtenu | la page de liste et la sidebar recalculaient la même chose chacune de son côté, sans le savoir |
| `Models/TaskFocus.swift` | quelle ligne est sélectionnée, laquelle est en édition | trois pages pilotaient deux `@State` nus avec les mêmes cinq transitions recopiées |
| `Models/TaskPageRows.swift` (`TaskPageBlock`) | ce qu'une page affiche : des pans de lignes, visibles ou repliés | chaque page REDÉCRIVAIT l'ordre de ses lignes dans une closure, que rien ne reliait à son `body` — une page l'a écrit faux, et le symptôme était « la touche ne marche pas » |
| `Models/TaskPageReorder.swift` | l'état d'un glissement : cadres, séquence figée, décalages, ordre obtenu | rien — seule la page d'une liste savait glisser, avec son moteur à elle |
| `Models/TodayPage.swift`, `Models/AllTasksPage.swift` | ce que ces deux pages présentent, à partir des tâches qu'on leur donne | des propriétés calculées DANS la vue : recalculées à chaque lecture (donc plusieurs fois par image) et invérifiables autrement qu'en cliquant |
| `Views/TaskList/TaskPageChrome.swift` (`TaskPageBase`) | le socle de TOUTE page de tâches : ⌫, ↑/↓, clic dans le vide, cadres des lignes | chaque page recevait ses gestes au coup par coup — la même touche donnait un résultat différent d'un onglet à l'autre |
| `Models/TodaySchema.swift` + `Tests/TodayTests/SchemaV1Snapshot.swift` | la forme des données, écrite deux fois et confrontée à chaque `swift test` | rien — un `@Model` cassé vidait sa colonne en silence (cf. Pièges) |
| `Services/StoreBackup.swift` | copie la base AVANT de l'ouvrir, quand la forme des modèles a changé | rien ne protégeait la vraie base à l'exécution |
| `TodayApp.openStore` | l'unique façon d'ouvrir un store | deux chemins d'ouverture, dont un que les tests ne couvraient pas |

### Comment une page de tâches se construit

Les CINQ pages (`ListPageView`, `TodayPageView`, `AllTasksPageView`, `UpcomingPageView`,
`ArchivePageView`) passent par le même socle. Une sixième se branche dessus sans une ligne de plus :

1. un `@State TaskFocus` pour la sélection, et `.rowPressGesture` sur chaque ligne — un geste
   UNIQUE qui sélectionne, renomme et glisse (`ListPageView` a le sien, plus riche : il emmène
   aussi les blocs d'en-tête). Surtout pas deux gestes séparés : dès qu'une vue porte un tap
   double, AppKit retient le tap simple le temps de la fenêtre de double-clic ;
2. `.measureTaskRow(task)` sur chaque ligne — sans ça la page reste aveugle : le clic dans le vide
   ne peut pas savoir qu'il est dans le vide, et rien ne peut se glisser ;
3. `.taskPageBase(focus:blocks:delete:reorder:)`, en déclarant ses pans dans l'ordre du rendu ;
4. pour glisser, en plus : un `@State TaskPageReorder`, `.taskRowDragLayer` sur les lignes,
   `.taskReorderPlaceholder` sur la page, `reorder.track(…)` à l'empoignade et `dropTaskDrag(…)`
   au relâchement.

Ce qui reste à la page, et à elle seule, c'est ce qu'elle ÉCRIT au relâchement — un rang sur
« Aujourd'hui », un rang plus un rattachement sur « Tâches » (`AllTasksPage.applyDrop`). C'est la
frontière posée en tête de `Reorder.swift` : l'arithmétique est commune, la règle métier ne l'est
pas.

**Deux axes d'ordre, et ils ne se mélangent pas.** `TaskItem.sortIndex` est attribué PAR LISTE :
sur une vue qui mélange les provenances, deux tâches peuvent porter le même rang, elles ne sont pas
comparables. D'où `TaskItem.smartOrder`, l'ordre manuel des vues intelligentes — **0 = jamais posée
à la main**, ce qui laisse `SmartList.sort` PLACER ce qui arrive et garantit qu'une base d'avant
garde exactement l'ordre qu'elle avait.

Elles partagent aussi `TaskRow`, les courbes `taskFlow`/`taskSelectFade`/`taskInsert`/`taskDrop` et
les métriques `gutter`/`rowInset`. Une page se construit AVEC ces briques, jamais à côté d'elles.

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
  Deux protections, à deux moments différents : `SchemaCompatibilityTests` attrape le changement AU
  MOMENT OÙ ON L'ÉCRIT (**rouge ⇒ ne pas lancer l'app**, suivre les cinq points en tête de
  `TodaySchema.swift`) ; `StoreBackup` copie la vraie base AVANT de l'ouvrir dès que la forme a
  bougé, dans `~/Library/Application Support/Today-Backups/` (3 copies gardées, journal SQLite
  compris). Restaurer = recopier les trois fichiers par-dessus `default.store`, app fermée.
- **EventKit rend des optionnels implicites.** `EKEvent.startDate`, `EKCalendarItem.calendar`,
  `EKCalendar.cgColor`, `.title` sont `null_unspecified` : les lire sans garde plante sur un
  calendrier d'abonnement mal formé. Filtrer À L'ENTRÉE, dans `RemindersService`, jamais chez chaque
  appelant.
- **`swift build` qui passe ne veut pas dire que ça marche.** L'essentiel des bugs ici sont des
  bugs de layout et d'interaction, invisibles au compilateur. Un changement d'UI se vérifie en
  lançant `./run.sh` et en regardant — **dans les deux thèmes** : les régressions de mode sombre
  sont la rechute la plus fréquente du projet (couleurs figées en dur, cf. Conventions).
- **Un glisser qui saccade n'est presque jamais le calcul.** `Reorder.swift` est partagé et couvert
  par 21 tests ; quand un glissement tremble, chercher plutôt dans cette liste — chaque ligne a
  coûté un aller-retour de vérification manuelle :
  1. **la translation se lit dans un repère FIXE** (`.named(taskPageSpace)`), jamais le repère
     local, qui est celui de la rangée — c'est-à-dire celui que le geste déplace. Mesurer un
     déplacement dans un repère que ce déplacement bouge fait trembler la ligne ;
  2. **les cadres sont gelés à l'empoignade**, et il ne suffit pas d'ignorer la nouvelle mesure : il
     ne faut pas l'ÉCRIRE. `frame(in:)` inclut le décalage des lignes tirées, et un `@State`
     réécrit à l'identique invalide quand même la vue — c'est l'invalidation qui boucle ;
  3. **un seul stockage de cadres par page.** Deux ont coexisté, un seul gelait : la boucle est
     revenue par la porte de derrière ;
  4. **l'ordre écrit et le retour des décalages à zéro tiennent dans UNE transaction** (cf.
     `dropTaskDrag`). Séparés, la rangée saute à sa nouvelle place pendant que son décalage s'anime
     depuis l'ancienne : elle part à l'opposé avant de revenir ;
  5. **la page réaffiche sa séquence VIVANTE**, jamais la copie figée. Rendre l'une puis rebasculer
     sur l'autre au relâchement produit le même symptôme que le point 4, pour une autre raison : le
     `ForEach` réordonne ses identités au moment où les décalages retombent. Rien n'écrit pendant un
     geste, la séquence vivante ne bouge donc pas d'elle-même. Le CALCUL, lui, garde bien sa copie.
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
  `CompletedTaskRetention`, `TaskPageBlock`, `TaskPageReorder`, `TodayPage`, `AllTasksPage`.
  **Une vue orchestre et anime ; elle ne calcule pas.** Corollaire mesuré : une propriété calculée
  d'une `View` repart de zéro à CHAQUE lecture et à chaque rendu — filtrer, trier et regrouper toute
  la base plusieurs fois par image se paie cash dès qu'un geste continu s'y ajoute. Construire une
  fois en tête de `body`, puis distribuer.
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
- **Un réglage qui peut s'oublier en silence est un bug en attente.** `TaskPageBase.reorder` n'a
  PAS de valeur par défaut : les cinq pages se prononcent, `nil` compris. Quand il en avait une,
  l'oubli compilait sans un mot et le glissement ne recevait aucun cadre — exactement le même
  défaut que la closure `rows` qu'il a remplacée. Une valeur par défaut se justifie quand
  l'omission est un CHOIX raisonnable ; pas quand elle produit une page à moitié branchée.
- **En français.** Identifiants en anglais, commentaires et documentation en français.
- `// ponytail:` marque une simplification délibérée et son plafond.
- Pas de trailer `Co-Authored-By` ni de mention d'outil dans les commits.

## Déjà essayé et REJETÉ — ne pas refaire

Chacune de ces approches a été écrite, essayée, et retirée. Deux l'ont été DEUX fois, par oubli.

- **Un fond transparent (`.background { Color.clear … onTapGesture }`) pour attraper le clic dans le
  vide.** Un `ScrollView` capte les clics de toute sa surface, et un fond de contenu ne couvre de
  toute façon ni les marges (`gutter`) ni le vide sous la dernière ligne. La seule réponse qui
  marche est celle du socle : moniteur `NSEvent` + cadres des lignes.
- **Faire publier aux lignes leur identité par `PreferenceKey` pour en dériver l'ordre du clavier.**
  Faux sur `ListPageView`, qui est en `LazyVStack` : les rangées hors écran ne sont pas construites
  et ne publient rien, donc l'ordre s'arrête au viewport. Une préférence mesure ce qui est RENDU ;
  l'ordre du clavier est ce qui est AFFICHÉ — d'où `TaskPageBlock`, qui est une valeur, pas une
  mesure. Les cadres, eux, restent bien du ressort d'une préférence : ils ne concernent que le
  visible, c'est leur définition.
- **`LazyVStack` sur « Aujourd'hui »** pour ne construire que les lignes visibles. Mesuré : le
  glisser en devient PIRE, pas meilleur (les rangées se créent et se détruisent au passage des
  décalages). Cette page reste en `VStack`.
- **Faire taire les diagnostics de chemins de clé** en marquant les `@Model` `@unchecked Sendable`.
  Ce serait un mensonge (ce sont des classes mutables) et le rafistolage que le projet refuse. Trou
  entre SwiftData et Swift 6, à laisser tel quel.
- **Le curseur « main » sur toute la ligne.** Sur macOS, la main signale un bouton ou un lien, jamais
  une ligne sélectionnable (Finder, Mail, Rappels gardent la flèche). Le comportement actuel — main
  sur la case à cocher seulement — est correct. Si un repère de survol manque, la bonne réponse est
  un fond de survol, pas un changement de curseur.

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

Les cinq pages se comportent pareil, et ça a été vérifié à la main, dans les deux thèmes :
sélection au clic, ⌫, ↑/↓, clic dans le vide qui relâche, ⌘Z après une suppression. Le glisser
existe sur une liste, un projet, « Aujourd'hui » et « Tâches » ; « À venir » et « Archives » n'en
ont pas, et c'est un choix — elles sont ordonnées par une date, il n'y a pas d'ordre manuel à y
mettre.

Encore du décor — le vérifier avant de le présenter comme fini :

- l'icône **tag** de la carte d'édition ne fait rien (le modèle ne porte pas de tags) ; les trois
  autres (date, checklist, priorité) sont branchées ;
- `TaskItem.hasTime` est bien LU (par `UpcomingPageView`, pour l'heure affichée) mais rien ne le met
  jamais à `true` : ni la saisie rapide ni les sélecteurs ne posent d'heure, seulement des jours ;
- la barre de capacité d'« Aujourd'hui » est écrite mais masquée (`ponytail:` dans `TodayPageView`).

Dette connue, par ordre de coût :

1. **`UpcomingPageView` et `ArchivePageView` calculent encore leur contenu dans leur `body`**
   (`agenda`, `archiveMonths`). C'est le dernier endroit qui s'écarte de la règle, et le même
   travail que `TodayPage`/`AllTasksPage` : sortir le calcul, ses tests viennent avec.
2. `TaskListView.swift` fait encore ~2 770 lignes. Ce n'est pas sa taille le problème, mais ce
   qu'elle mélange : `TaskRow`, `HeaderRow`, la barre d'outils et les `NSViewRepresentable` en
   sortiraient sans rien casser. Attention : `Checkmark` et `NotesBox` devront passer de `private`
   à interne.
3. **On ne peut pas déposer une tâche dans un dépliant VIDE de « Tâches ».** La section d'accueil se
   lit sur la ligne voisine (seule lecture qui marche pour les quatre sortes de sections) ; sans
   voisine, rien à lire. Le jour où ça manque : donner un cadre au bandeau lui-même et viser dessus.
4. Le mode langage reste Swift 5. La concurrence stricte est en revanche VÉRIFIÉE (réglage dans
   `Package.swift`) et tous les diagnostics restants sont le même : `SortDescriptor(\Model.x)` veut
   un chemin de clé `Sendable`, qu'un `@Model` SwiftData ne peut pas être. Trou d'Apple, pas dette
   du projet. **Ce cliquet porte sur leur NATURE, pas sur leur nombre** — celui-ci dépend du mode de
   compilation (~40 en release, qui compile en module entier, nettement plus en debug, qui répète la
   même expansion de macro fichier par fichier). Tout diagnostic qui n'est PAS un chemin de clé est
   une régression d'isolation à corriger sur-le-champ.
