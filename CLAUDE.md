# Today

Clone natif macOS de Things (Cultured Code). Scope, décisions et découpage : `ROADMAP.md`.
SwiftPM (pas de `.xcodeproj`), SwiftUI + SwiftData, ~12 400 lignes dans `Sources/Today/`
(+ ~2 670 de tests). Le produit s'appelle **Today** ; « ThingsClone » ne survit que dans le nom
de `ThingsCloneApp.swift`.

## Lancer

```bash
./run.sh          # build → bundle .app → open. Le seul moyen correct de lancer l'app.
swift build       # compilation seule (~0,2 s incrémental)
swift test        # 189 tests, en mémoire ou sur un store temporaire — jamais la vraie base
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
| `Models/SortedByKey.swift` | trier des `@Model` en ne lisant les clés qu'UNE fois par élément | des comparateurs qui relisaient leurs clés à CHAQUE comparaison — ×7 à ×10 sur tous les tris de l'app |
| `Models/Reorder.swift` | l'arithmétique du glissement : repli, écartement, trou, ordre obtenu | la page de liste et la sidebar recalculaient la même chose chacune de son côté, sans le savoir |
| `Models/TaskFocus.swift` | quelle ligne est sélectionnée, laquelle est en édition | trois pages pilotaient deux `@State` nus avec les mêmes cinq transitions recopiées |
| `Models/TaskPageRows.swift` (`TaskPageBlock`) | ce qu'une page affiche : des pans de lignes, visibles ou repliés | chaque page REDÉCRIVAIT l'ordre de ses lignes dans une closure, que rien ne reliait à son `body` — une page l'a écrit faux, et le symptôme était « la touche ne marche pas » |
| `Models/TaskPageReorder.swift` | l'état d'un glissement : cadres, séquence figée, décalages, ordre obtenu | rien — seule la page d'une liste savait glisser, avec son moteur à elle |
| `Models/TodayPage.swift`, `AllTasksPage`, `UpcomingPage`, `ArchivePage` | ce que chaque page intelligente présente, à partir des tâches qu'on lui donne | des propriétés calculées DANS la vue : recalculées à chaque lecture (donc plusieurs fois par image) et invérifiables autrement qu'en cliquant |
| `Views/TaskList/TaskPageChrome.swift` (`TaskPageBase`) | le socle de TOUTE page de tâches : ⌫, ↑/↓, clic dans le vide, cadres des lignes | chaque page recevait ses gestes au coup par coup — la même touche donnait un résultat différent d'un onglet à l'autre |
| `Models/TodaySchema.swift` (`CurrentSchema` + `SchemaV1`) + `Tests/TodayTests/DeployedSchemaSnapshot.swift` | la forme des données, écrite deux fois et confrontée à chaque `swift test` | rien — un `@Model` cassé vidait sa colonne en silence (cf. Pièges) |
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
3. `.taskPageBase(focus:blocks:delete:reorder:newTask:)`, en déclarant ses pans dans l'ordre du
   rendu. `reorder` ET `newTask` sont sans valeur par défaut : la page se prononce, `nil` compris ;
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
- **TOUT changement de forme d'un `@Model` demande une montée de version ET une étape.** Y compris
  un ajout. `CurrentSchema` pointe les classes VIVANTES et son numéro de version ne bouge pas tout
  seul — SwiftData compare les NUMÉROS, jamais les formes. Deux issues, toutes deux muettes à la
  compilation :
  - **numéro inchangé** → il conclut « rien à faire », ne joue aucune étape, et **l'ouverture
    échoue** : la vraie base part en quarantaine et l'app démarre VIDE. Mesuré le 3 août 2026 en
    ajoutant `Project.colorRaw`, un simple `String?` — « un ajout est absorbé tout seul » était
    faux, ça a coûté une restauration.
  - **numéro monté mais étape manquante sur un renommage / une suppression / un changement de
    type** → `swift build` passe, le store s'ouvre SANS erreur, et **la donnée part**.

  Marche à suivre : les cinq points en tête de `TodaySchema.swift`. **Rouge ⇒ ne pas lancer
  l'app.** Deux cliquets le disent, et ils ont été vérifiés en REJOUANT la faute :

  1. `SchemaFingerprintTests` — l'empreinte SHA de la forme (`StoreBackup.fingerprint`, qui la
     calculait déjà pour décider d'une sauvegarde) confrontée à une constante versionnée. Modifier
     un `@Model` la fait bouger, point. Ne JAMAIS recopier l'empreinte pour faire taire le test :
     c'est l'oubli qu'il attrape.
  2. `StoreFixtureTests` — une VRAIE base par version livrée (`Tests/TodayTests/Fixtures/`),
     rouverte par `TodayApp.openStore`. À chaque montée de version, y déposer la base de la version
     sortante et l'ajouter à `shipped` ; les fichiers déjà là ne se retouchent jamais.

  Pourquoi ces deux-là et pas `SchemaCompatibilityTests` seul : ce dernier fabrique ses bases à
  partir d'une DESCRIPTION en code (`DeployedSchemaSnapshot`), éditable — et éditée le 3 août dans
  le même commit que les modèles, ce qui l'a laissé vert pendant que la vraie base partait en
  quarantaine. Mesuré en rejouant ce commit : les 4 `SchemaCompatibilityTests` verts, les 2 cliquets
  rouges. Un binaire versionné ne dérive pas. `DeployedSchemaSnapshot` se retouche EN DERNIER.

  Troisième filet, à l'exécution : `StoreBackup` copie la vraie base AVANT de l'ouvrir dès que la
  forme a bougé, dans `~/Library/Application Support/Today-Backups/` (3 copies gardées, journal
  SQLite compris). Restaurer = recopier les trois fichiers par-dessus `default.store`, app fermée.

  **Une migration se répète à blanc sur une COPIE de la vraie base avant de lancer l'app.** Les
  tests portent sur des fixtures ; la vraie base peut contenir ce qu'aucune fixture ne décrit.
  Copier `default.store` + ses deux journaux ailleurs, l'ouvrir par `TodayApp.openStore`, compter.
- **Une valeur par défaut est évaluée UNE fois, pas une fois par ligne.** Conséquence non évidente
  et mesurée le 3 août 2026 : ajouter `var uuid: UUID = UUID()` en migration `.lightweight` remplit
  TOUTES les lignes existantes avec le MÊME identifiant (`Schema.Attribute.defaultValue` contient un
  UUID concret, pas un générateur). Un identifiant d'identité partagé par tout le monde ne distingue
  rien — c'est le doublon en masse dès le premier jour de synchro. D'où l'étape `.custom` 3→4 et son
  `didMigrate`, gardée par `SchemaMigrationV4Tests`. La règle générale : dès qu'un champ ajouté doit
  valoir quelque chose de DIFFÉRENT par ligne, `.lightweight` ne peut pas convenir.
- **Le modèle est prêt pour CloudKit, et un test le tient.** `CloudKitReadinessTests` vérifie sur le
  `Schema` lui-même les quatre contraintes qu'iCloud impose : toute propriété optionnelle ou pourvue
  d'une valeur par défaut, aucune `@Attribute(.unique)`, toute relation « à un » optionnelle et
  pourvue d'un inverse, une identité stable (`uuid`) sur chaque entité. Elles ne coûtent rien tant
  que la synchro n'est pas branchée — c'est justement pourquoi elles se cassent sans qu'on le voie.
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
- **Une section VIDE ne se lit pas par sa voisine.** Sur « Tâches », le dépôt déduit la section
  d'accueil de la ligne VOISINE — la seule lecture qui marche pour les quatre sortes de sections
  d'un coup. Une section vide n'en a aucune : une tâche lâchée sur un « Aujourd'hui » vide partait
  dans « Non classé » et perdait sa date, EN SILENCE (mesuré, pas supposé). D'où `SectionBandKey` +
  `AllTasksPage.emptySection(at:bands:)`, qui désignent la section par sa GÉOMÉTRIE — et seulement
  quand elle est vide, la voisine restant plus précise ailleurs (dans un projet à plusieurs listes,
  elle dit laquelle). Ce n'est PAS un second stockage de cadres : il ne nourrit aucun décalage, il
  ne sert qu'au relâchement.
- **Lire une propriété d'un `@Model` n'est PAS un accès mémoire.** Ça traverse la machinerie
  SwiftData (`_$backingData`). Conséquence non évidente : un comparateur ordinaire relit ses clés à
  chaque comparaison, soit n·log n fois — ~4 400 accès pour trier 86 tâches sur cinq clés, et le tri
  coûtait dix fois le filtrage alors qu'il fait moins de travail. D'où `sortedByKey`, qui décore
  avant de trier. **Tout nouveau tri sur un `@Model` passe par lui**, jamais par `.sorted { }`
  directement. Corollaire à ne pas sur-appliquer : sur des types de valeur (dates, chaînes,
  `EKEvent`), la décoration est une allocation pour rien.
- **`cp -r` DÉTRUIT un framework versionné.** Sparkle n'est qu'une arborescence de liens
  symboliques (`Sparkle` → `Versions/Current/Sparkle`) ; `cp -r` les SUIT et copie les cibles —
  mesuré : 3,0 Mo deviennent 8,9 Mo, chaque binaire en double, et le bundle n'a plus la forme d'un
  framework. Conséquence : `codesign --verify --deep --strict` sort en erreur (« bundle format is
  ambiguous »), or c'est ce sceau que Sparkle compare entre l'app installée et celle qu'il télécharge
  avant d'installer une mise à jour. `ditto` partout où l'on copie un bundle (cf. `make-app.sh`).
- **Un store laissé sale par un plantage se répare tout seul — à la DEUXIÈME tentative.** Le 4 août
  2026, l'app a été tuée en plein travail (cf. le plantage ci-dessous) et a laissé un journal WAL de
  2,4 Mo non rejoué. L'ouverture suivante a ÉCHOUÉ, la base est partie en quarantaine, l'app est
  repartie vide — mais cette tentative ratée avait rejoué le journal au passage, et les MÊMES octets
  se rouvrent depuis sans une erreur (21 tâches, 5 listes, vérifié par `TodayApp.openStore` sur une
  copie). La quarantaine avait donc coûté une app vide pour une panne qui n'existait déjà plus. D'où
  la seconde tentative dans `TodayApp.container`, avant toute mise à l'écart.
- **Ne JAMAIS poster la notification d'ouverture de la capsule à une instance dont on refait le
  bundle.** C'est ce qui a tué l'app ce jour-là, et la pile le dit mot pour mot :
  `QuickEntryWindow.show` → `makeKeyAndOrderFront` → `NSRemoteView` → `_CFBundleGetValueForInfoKey`
  → exception → « Abort trap: 6 ». Ordonner une fenêtre à l'écran fait lire l'`Info.plist` du bundle
  par une vue hors-process ; si `make-app.sh` est en train de le réécrire, il n'y a rien à lire.
  C'est le plantage fantôme déjà décrit en tête de ce fichier, atteint par une autre porte —
  `run.sh` tue bien l'instance AVANT de reconstruire, mais un script qui parle à l'app par
  `DistributedNotificationCenter` court-circuite cette garantie.
- **La quarantaine se DIT à l'utilisateur.** `StoreQuarantine` écarte la base illisible et l'app
  repart vide ; « ça se remarque » ne suffisait pas — rien ne disait que le travail était encore là,
  à côté, sous un autre nom, et le vrai risque était de tout retaper par-dessus. Le rapport passe par
  les défauts (`StoreQuarantine.reportKey`) parce que la quarantaine a lieu pendant la construction
  du container, avant qu'aucune fenêtre n'existe ; `ContentView` le consomme et l'affiche une fois.
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
  l'omission est un CHOIX raisonnable ; pas quand elle produit une page à moitié branchée. Le
  même défaut s'est reproduit avec ⌘N : posé sur la page d'une liste et sur elle seule, il laissait
  les quatre autres retomber sur le *Nouvelle fenêtre* d'office de `WindowGroup` — la touche
  ouvrait un ONGLET sur « Tâches », « Aujourd'hui » et un projet. Deux corrections, à deux niveaux :
  `CommandGroup(replacing: .newItem) {}` retire la commande système une fois pour toutes, et
  `TaskPageBase.newTask` porte la création, sans défaut lui non plus.
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
  Un build à 0,2 s n'a rien vérifié du reste du module. Mesuré : **0 avertissement** quand il n'y a
  rien à refaire, **40** après un `touch` de tout. Avant de dire qu'une modification est propre :
  `find Sources Tests -name '*.swift' -exec touch {} +` puis `swift build && swift test` — et
  `-c release`, qui compile en module entier et sort des diagnostics que le debug tait.

  `make-app.sh` applique désormais ce constat plutôt que de le laisser à la mémoire de chacun : il
  résume les avertissements connus en UNE ligne, **s'arrête net** sur tout ce qui n'est pas un
  chemin de clé (échappatoire `ALLOW_NEW_WARNINGS=1`), et **refuse de conclure** quand rien n'a été
  recompilé — un ✓ dans ce cas-là serait exactement le mensonge que le contrôle doit empêcher.
  `release.sh` pose `FULL_WARNING_CHECK=1` : ce qu'on publie se compile entièrement.
- Formatage : `xcrun swift-format -i -r Sources Tests` (pas de config, valeurs par défaut).
- Publier : `./Scripts/quick.sh "message"` (bump + DMG signé + release + appcast + push).

## État réel

Ce qui marche : listes, tâches, en-têtes de section, réordonnancement (tâches ET blocs d'en-tête),
renommage, complétion, projets, sous-tâches, notes en texte riche, saisie rapide (`@demain`,
`#liste`), raccourcis texte et combinaisons globales, archivage, pomodoro, rappels et calendrier
Apple (lecture + report de complétion), recherche (`QuickFindPanel`), capsule de saisie rapide hors
app, et les quatre pages intelligentes — **Tâches**, **Aujourd'hui**, **À venir**, **Archives** —
toutes réelles.

`HUDWindow` est la pastille d'accusé de réception, en bas de l'ÉCRAN : elle ne parle QUE des gestes
dont le résultat n'est pas à l'écran — une tâche déposée par la capsule depuis une autre app, un
Pomodoro piloté au clavier (cf. les commandes `!pomodoro…` d'`AppCommand`, à qui elle sert de seul
retour, puisqu'elles n'activent délibérément pas la fenêtre). Là où la rangée apparaît sous les yeux,
elle n'a rien à dire, et l'y ajouter la transformerait en bruit.

Les cinq pages se comportent pareil, et ça a été vérifié à la main, dans les deux thèmes :
sélection au clic, ⌫, ↑/↓, clic dans le vide qui relâche, ⌘Z après une suppression. Le glisser
existe sur une liste, un projet, « Aujourd'hui » et « Tâches » ; « À venir » et « Archives » n'en
ont pas, et c'est un choix — elles sont ordonnées par une date, il n'y a pas d'ordre manuel à y
mettre.

**Plus rien n'est du décor.** Les trois derniers faux-semblants ont été retirés le 2 août 2026, et
le principe qui les a fait partir vaut pour la suite : *une fonctionnalité est branchée ou elle
n'existe pas.* Du code en pause ment sur ce que l'app sait faire, et se paie deux fois — une fois
en le maintenant, une fois en le débranchant.

- l'**icône tag**, décorative faute de modèle qui porte des tags → retirée ;
- **`TaskItem.hasTime`**, jamais mis à vrai par aucun chemin (l'app ne pose que des JOURS), ce qui
  rendait l'affichage d'heure d'« À venir » inatteignable → retiré du schéma (cf. `SchemaV1`) ;
- la **barre de capacité** d'« Aujourd'hui », écrite, testée et masquée — avec son réglage
  « Fin de journée » resté VISIBLE dans les Réglages, où il ne pilotait donc plus rien → supprimée,
  avec `DayCapacity`. `Estimate` (la durée d'une tâche) reste : elle sert ailleurs.

Dette connue, par ordre de coût :

1. **Le champ « Nouvelle tâche » et ⌘N ne créent pas la même chose**, et c'est voulu : le champ note
   vite (on tape un titre, on valide), ⌘N crée une tâche VIDE ouverte en édition (notes,
   sous-tâches, date, priorité). Une tâche restée entièrement vide est supprimée à la fermeture de
   son édition (cf. `TaskItem.isBlank`) — sans ça, ⌘N puis Échap laissait un « Sans titre » en base.
2. **Toutes les `@Query` lisent la table entière** puis filtrent et trient en mémoire. Mesuré à 87
   tâches : sans objet (le rendu d'« Aujourd'hui » coûte 0,46 ms de filtre + tri, 11,7 ms à 2 000
   tâches). C'est le plafond à connaître, pas à corriger — passer en `#Predicate` le jour où la
   base se comptera en milliers.
3. Le mode langage reste Swift 5. La concurrence stricte est en revanche VÉRIFIÉE (réglage dans
   `Package.swift`) et tous les diagnostics restants sont le même : `SortDescriptor(\Model.x)` veut
   un chemin de clé `Sendable`, qu'un `@Model` SwiftData ne peut pas être. Trou d'Apple, pas dette
   du projet. **Ce cliquet porte sur leur NATURE, pas sur leur nombre** — celui-ci dépend du mode de
   compilation (~40 en release, qui compile en module entier, nettement plus en debug, qui répète la
   même expansion de macro fichier par fichier). Tout diagnostic qui n'est PAS un chemin de clé est
   une régression d'isolation à corriger sur-le-champ.
