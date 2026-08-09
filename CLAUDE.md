# Today

Clone natif macOS de Things (Cultured Code). Scope, décisions et découpage : `ROADMAP.md`.
SwiftPM (pas de `.xcodeproj`), SwiftUI + SwiftData, ~12 400 lignes dans `Sources/Today/`
(+ ~2 670 de tests). Le produit s'appelle **Today** ; « ThingsClone » ne survit que dans le nom
de `ThingsCloneApp.swift`.

## Lancer

```bash
./run.sh          # build RELEASE → bundle .app → open. Le seul moyen correct de lancer l'app.
                  # `./run.sh debug` pour le pas-à-pas. Il construisait en debug PAR DÉFAUT, ce qui
                  # faisait juger la fluidité sur un binaire non optimisé alors qu'on livre l'autre.
swift build       # compilation seule (~0,2 s incrémental)
swift test        # en mémoire ou sur un store temporaire — jamais la vraie base
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
| `Models/SidebarDrop.swift` | ranger une tâche en la lâchant sur la barre latérale : la règle du dépôt, `TaskItem.move(to:)`, et l'état d'un geste que trois vues SŒURS se partagent | le menu ▸ *Déplacer vers…* pour seul chemin — et son écriture recopiée dans trois pages, dont deux calculaient le nouveau rang à l'envers |
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

- **Un popover est une FENÊTRE, et SwiftUI ne la présente pas au clic — il la présente depuis le
  LAYOUT.** `PopoverBridge.preferencesDidChange` → `updatePresentations` →
  `NSPopover.showRelativeToRect:`, le tout sous `NSHostingView.layout()`. Or cette app fait circuler
  des préférences en continu (chaque ligne republie son cadre, `TaskRowFrameKey`, à chaque mise en
  page). Ordonner une fenêtre enfant en plein calcul de layout fait passer AppKit par
  `addChildWindow:` → `_rebuildOrderingGroup:`, qui réordonne les autres fenêtres du groupe ; l'une
  d'elles héberge une vue hors-process, `-[NSRemoteView containingWindowWillOrderOnScreen:]` lève
  une exception, et comme on est sous `_NSViewLayout` AppKit la convertit en
  `+[NSApplication _crashOnException:]` : **SIGTRAP, sans un mot**, et le gestionnaire de `CrashLog`
  ne la voit JAMAIS (AppKit passe devant). Pile complète : `Today-2026-08-06-164404.ips`, geste
  « ••• → Couleur… » sur une en-tête. Trois plantages de la même famille le 5 août.

  **Ce n'est pas le menu qui se ferme derrière.** Hypothèse plausible, et FAUSSE : mesurée avec un
  reproducteur AppKit nu, un `NSPopover` présenté dans le même tour de boucle qu'un `NSMenu` qui se
  ferme passe 12 fois sur 12. C'est la présentation depuis le layout qui casse.

  Conséquence : **une palette, un sélecteur, un panneau ne prennent pas de fenêtre** — ils se
  révèlent DANS la fenêtre (cf. `PalettePicker`, et `QuickFindPanel` avant lui). Les popovers qui
  restent (`WhenPicker`, `DeadlinePicker`, la date d'une liste) sont sous la même menace ; celui de
  `TaskRow` se referme avant d'écrire, ce qui traite le symptôme, pas la cause.
- **Un `@Query` se ré-invalide SANS qu'aucune écriture n'ait lieu.** Mesuré le 6 août 2026 avec
  `Self._printChanges()` : ouvrir la carte d'édition d'une tâche imprime, à chaque fois,
  `SidebarView: \_QueryController<TodoList, String>.<computed (Bool)> changed` — puis pareil à la
  fermeture. Or **rien n'est écrit** : vérifié en écoutant `ModelContext.didSave`,
  `ModelContext.willSave` et `NSManagedObjectContextObjectsDidChange`, aucune des trois ne sonne.
  C'est une sur-notification de SwiftData (l'accès à une relation suffit), et **on ne peut pas
  l'empêcher depuis ici**.

  Conséquence, et c'est elle qui compte : **le corps d'une vue qui porte un `@Query` se rejoue
  bien plus souvent qu'on ne le croit** — il faut donc qu'il soit BON MARCHÉ, pas qu'il soit rare.
  `SidebarView.body` coûtait ~13 ms, soit plus d'une image entière à 120 Hz, et il tombait pile au
  démarrage de l'animation d'ouverture d'une carte : le décrochage se voyait.

  La cause du prix : `listRow` lisait `list.progress` puis `list.remainingCount` DEUX fois, soit
  trois traversées de la relation `TodoList.tasks` PAR RANGÉE. D'où `Models/SidebarCounts.swift` —
  tous les compteurs en UNE passe, distribués aux rangées, exactement le motif de `TodayPage.build`
  et des décalages de `projectsGroup`. Mesuré au `sample` sur le geste rejoué en boucle : travail
  du fil principal par ouverture/fermeture **1264 → ~940 échantillons** (deux runs : 970 et 907,
  contre 1264 avant), soit ~6,6 ms → ~4,9 ms par image. Il y a de nouveau de la marge sous les
  8,3 ms d'une image à 120 Hz.

  Le corollaire général : **toute propriété calculée d'un `@Model` lue depuis une rangée est un
  piège** (`progress`, `remainingCount`, `orderedTasks`…). Elle se calcule une fois en tête du
  `body` qui rend la collection, jamais dans la rangée.

  Pour diagnostiquer un rendu de trop : `Self._printChanges()` dit QUELLE dépendance a bougé, ce
  qu'un `sample` ne dira jamais. Et pour déclencher un geste sans souris, un `.task` temporaire
  piloté par une variable d'environnement vaut mieux qu'un clic simulé (le journal système ne
  remonte rien de ce process, cf. plus bas — passer par `print` avec `setvbuf(stdout, nil, _IONBF, 0)`,
  sinon la sortie reste dans le tampon et on croit que rien ne s'exécute).
- **Lire un rappel par son identifiant est un XPC SYNCHRONE.**
  `EKEventStore.calendarItem(withIdentifier:)` fait un aller-retour bloquant vers le démon Rappels :
  sur le fil principal, il le GÈLE le temps de la réponse. Trois fonctions en posaient un PAR tâche
  liée (`completionStates`, `reminderDay`, `reminderVanished`). Mesuré au `sample`, app AU REPOS :
  **97 échantillons de fil principal arrêtés dans
  `__NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__` sur une fenêtre de 4 s** — la moitié de
  tout le travail non-oisif du fil qui dessine, pour une app à laquelle personne ne touchait. Et
  c'est linéaire en tâches liées, rejoué à chaque `.EKEventStoreChanged` **et** à chaque
  `ModelContext.didSave`, donc après chaque titre validé, chaque case cochée, chaque dépôt.

  Remplacé par UN instantané asynchrone par passe (`RemindersService.passSnapshot`, pris dans
  `withSyncLock`) : `fetchReminders` rend la main tout de suite et rappelle hors du fil principal.
  Re-mesuré : **97 → 0**. La règle générale : dans ce service, tout ce qui interroge EventKit par
  identifiant passe par l'instantané, jamais par `store` en direct.
- **Le minimum macOS n'est pas vérifié par le build.** `Package.swift` déclare `.macOS(.v14)`
  mais `swift build` compile pour l'hôte. Une API `@available(macOS 15+)` compile sans broncher et
  casserait sur une vraie cible 14. À vérifier à l'œil.
- **Le store contient de la VRAIE donnée**, pas des jeux d'essai — et il vit dans
  `~/Library/Application Support/Today/default.store` (cf. `Services/StoreLocation.swift`, qui
  déménage aussi l'ancienne base au premier lancement). Le compter avant d'y toucher :
  `sqlite3 default.store "select count(*) from ZTASKITEM;"`.

  **Il vivait à la RACINE de `~/Library/Application Support/`**, sans sous-dossier, parce que
  SwiftData nomme son fichier par défaut `default.store` et le pose là quand rien ne lui dit où
  aller. Le 5 août 2026, une autre app a écrit SON `default.store` par-dessus le nôtre : deux
  applications sans rapport se disputaient le même chemin, et la première à écrire gagnait. C'est
  pour ça que le dossier au nom de l'app n'est pas cosmétique.
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
- **Une mesure posée APRÈS un `.offset` ne bouge pas.** `.offset` est un effet de RENDU : il ne
  déplace pas la position de layout. Une `GeometryReader` posée après lui dans la chaîne devient
  donc la SŒUR de la vue décalée, reste calée sur la place de repos, et publie un cadre parfaitement
  immobile pendant tout le geste. Posée AVANT, elle est sous l'offset et le suit. C'est la même
  mécanique que le gel des cadres de `TaskPageReorder`, vue de l'autre côté : là c'est le piège qui
  fait boucler, ici c'est le mécanisme qui fait marcher `publishTaskDrag` — le calque du rangement
  vers la sidebar. Rien de tout ça ne se voit à la compilation : mesuré le 6 août 2026, le calque
  n'apparaissait jamais et aucune ligne de sidebar ne s'allumait, sans un mot nulle part.

  Corollaire de diagnostic : **le journal système ne remonte rien de ce process**
  (`log show --predicate 'process == "Today"'` rend 0 ligne, y compris pour un `NSLog` que le binaire
  exécute vraiment). Tracer un geste passe par un fichier plat — l'app n'a aucun entitlement de
  sandbox, `/tmp` lui est ouvert.
- **Sur « Tâches », chaque section est sa PROPRE zone de glissement**, et on n'y fait plus voyager
  une tâche d'une section à l'autre au doigt. La séquence donnée au moteur est `section.tasks`,
  jamais les lignes de la page (cf. `AllTasksPageView.rowsView`).

  Le glisser traversant a existé, avec toute une machinerie pour deviner la section d'accueil
  (`SectionBandKey`, `AllTasksPage.emptySection(at:bands:)`, `measureSectionBand` — **tous
  supprimés**, ne pas les chercher). Il a été retiré le 6 août 2026 pour deux défauts que cette
  machinerie ne pouvait pas corriger, parce qu'ils venaient d'ailleurs : le moteur raisonnait sur
  une liste PLATE, alors que les titres de section occupent de la hauteur à l'écran. Plus on
  traversait de titres, plus l'écart se creusait entre la ligne dessinée et le trou qui s'ouvre —
  le « flou » constaté à l'usage. Et un titre n'étant pas une ligne, lâcher dessus faisait lire la
  tâche du DESSUS : on atterrissait dans la section précédente.

  Bornée à sa section, la séquence est homogène et contiguë : plus de trou d'air, et les deux bouts
  du dépliant deviennent des butées naturelles.

  **Ne pas rétablir le glisser entre sections**, et surtout pas pour faire s'ouvrir une section
  repliée au survol (la demande est venue, elle a été écartée le 6 août — la SIDEBAR, elle, déplie
  bien au survol, et pourquoi ce n'est pas la même chose est en « Déjà essayé et REJETÉ »). Ce serait réinstaller les
  deux défauts ci-dessus sur le morceau le plus fragile de l'app, pour une cible qui DÉFILE — viser
  une section 800 px plus bas n'est pas plus rapide qu'un clic droit. Le déplacement entre sections
  passe par le menu ▸ *Déplacer vers…* et le sélecteur *Quand…*, qui disent explicitement ce que le
  glisser devait deviner. La suite prévue, elle, est le glisser vers la SIDEBAR (cible fixe, qui
  liste toutes les destinations, et qui n'a aucun trou à calculer) — cf. `ROADMAP.md`.
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
- **Une vue HORS-PROCESS de WebKit vit dans ce process, et elle plante dès qu'une fenêtre est
  ordonnée à l'écran.** C'est le dénominateur commun des TROIS plantages du 6 août 2026 — la
  palette d'une en-tête, « Rechercher les mises à jour », et le réveil de l'icône de barre de
  menus. Aucun des trois n'était en cause : chacun ne faisait qu'ordonner une fenêtre. La raison,
  enfin lisible grâce à `CrashLog` :

      NSInternalInconsistencyException
      assertion failed: '<NSRemoteView … SPCompletionListServiceViewController> notified of
      <NSStatusBarWindow …> but expected (null)'
      in -[NSRemoteView containingWindowWillOrderOnScreen:] line 4221 (ViewBridge)

  **Établi** : `Sparkle.framework` lie `WebKit` (il affiche ses notes de version dans une
  WKWebView) — vérifié à l'`otool -L` ; notre binaire, lui, n'a aucun lien direct. Tout le process
  hérite donc de WebKit, WebCore et SafariPlatformSupport au CHARGEMENT, et Today lance exactement
  un `com.apple.SafariPlatformSupport.Helper` (mesuré : 9 → 10 → 9 helpers à l'ouverture puis à la
  fermeture de l'app, reproductible).

  **Réfuté — ne pas réessayer** :
  - `isAutomaticTextCompletionEnabled = false` sur nos `NSTextView` (le nom de la classe fautive
    désigne pourtant la liste de complétion) : le helper est lancé quand même ;
  - retirer entièrement `prewarmRichTextEditing()` : lancé quand même. Ce ne sont donc ni nos vues
    texte ni le préchauffage qui l'allument ;
  - passer à une variante de Sparkle sans interface : elle n'existe pas, son paquet SPM ne fournit
    qu'un framework pré-compilé.

  **Conclusion en l'état** : une assertion d'Apple dans ViewBridge, atteignable chez nous parce que
  Sparkle traîne la pile WebKit, sur un macOS 26 encore en bêta (26A5388g). Pas de correctif de
  notre côté identifié. À reprendre avec un `crash.log` frais si ça se reproduit — et à retester
  sur un macOS non bêta avant d'aller plus loin.
- **`NSSetUncaughtExceptionHandler` ne voit presque RIEN dans une app AppKit**, et `CrashLog` a
  donc parlé dans le vide pendant des semaines. Mesuré le 6 août 2026 en levant une vraie
  `NSException` : toute exception levée pendant que la boucle d'événements tourne est attrapée par
  AppKit, qui appelle `+[NSApplication _crashOnException:]` et déclenche un SIGTRAP **avant**
  `_objc_terminate` — or c'est `_objc_terminate` qui appelle le gestionnaire. Il ne reste couvert
  que ce qui lève hors boucle. C'est ce qui a rendu muets les deux plantages du 6 août (la palette
  d'une en-tête, puis « Rechercher les mises à jour »).

  Le point d'accroche qui marche est `-[NSApplication reportException:]`, qu'AppKit appelle AVEC
  l'exception avant de tuer le process. `CrashLog` l'échange (swizzle) et rappelle l'implémentation
  d'origine — il observe, il ne détourne pas. La voie propre (sous-classe `NSApplication` +
  `NSPrincipalClass`) est fermée : `TodayApp.init` touche `NSApplication.shared` avant que
  `NSApplicationMain` ne lise cette clé, la classe est déjà figée.

  **La raison s'écrit dans un FICHIER**, `~/Library/Application Support/Today/crash.log`, à côté de
  la base — surtout pas dans le journal unifié, qui ne rend rien pour ce process (cf. ci-dessous).
  Vérifié de bout en bout : exception levée pour de vrai, fichier écrit, nom + raison + pile en
  clair.

  **`_CFBundleGetValueForInfoKey + 0` dans une pile d'exception ne veut RIEN dire.** Ce symbole
  apparaît en position 2 de TOUTES ces piles, y compris celle du banc de vérification qui ne lit
  aucun bundle : c'est l'adresse de retour d'`objc_exception_throw` résolue au symbole précédent le
  plus proche, pas un appel réel. Ce fichier a bâti sur lui le diagnostic du « plantage fantôme »
  (l'`Info.plist` réécrit sous les pieds de l'app) — l'explication reste plausible pour le cas de
  `make-app.sh`, mais **cette frame n'en est pas la preuve**.
- **Un plantage sans message se lit dans le journal.** `CrashLog` installe aussi un gestionnaire
  d'exceptions non rattrapées, parce que le rapport système garde la pile mais PAS la raison :
  `log show --last 1h --predicate 'process == "Today"' | grep PLANTAGE`. Il n'attrape en revanche
  QUE les exceptions Objective-C : un `fatalError` de Swift (`EXC_BREAKPOINT`, `brk 1`, pile qui
  part de `_assertionFailure`) passe à côté, et le rapport système n'en garde pas la phrase. La
  seule façon de la lire est de **rejouer le geste hors de l'app** — un test sur une COPIE de la
  vraie base, où le message s'imprime en clair. C'est ce qui a résolu le crash ci-dessous après
  deux fausses pistes.
- **L'annulation et la cascade ne se mélangent pas.** `ContentView` branche l'`UndoManager` de la
  fenêtre sur le contexte (c'est ce qui fait marcher ⌘Z). Avec lui branché, enregistrer une cascade
  à PLUSIEURS niveaux — un projet emporte ses listes, qui emportent leurs tâches — fait tomber
  SwiftData sur `DataUtilities.swift:541: A snapshot should exist before creating a new snapshot
  for undo`. Supprimer un projet depuis la sidebar plantait l'app à tous les coups (6 août 2026).
  Mesuré en rejouant la suppression sur une copie neuve de la vraie base, un projet par copie :
  **sans** manager, les 6 projets partent sans un mot ; **avec**, le premier fait tomber le
  processus. D'où `ModelContext.deleteCascadeAndSave`, qui débranche le manager le
  temps de la cascade et VIDE sa pile (elle parle peut-être d'objets que la cascade vient
  d'effacer). Réservé aux deux appelants qui cascadent : tout y passer retirerait ⌘Z de la
  suppression d'une tâche, qui marche et qui compte. Gardé par `CascadeDeleteTests` — qui ne
  reproduit RIEN si l'on oublie de rouvrir le store entre le semis et la suppression : il faut des
  objets relus du disque, sans instantané en mémoire.

  **Ce n'est PAS la profondeur de la cascade qui décide.** Ce fichier a affirmé le contraire
  (« une tâche, sous-tâches comprises, ne pose aucun problème — c'est le niveau supplémentaire qui
  casse »), et c'est faux. Mesuré le 6 août 2026 en écrivant `CascadeDeleteTests` : avec le manager
  branché, supprimer UNE tâche relue du disque fait tomber la même assertion — y compris après avoir
  effacé ses sous-tâches d'abord. Ce qui change tout, c'est de **LIRE ses propriétés avant** : la
  même suppression passe alors sans un mot. C'est l'instantané qui manquait, pas un niveau de trop.

  Conséquence pratique : ⌫ est hors de portée du défaut parce qu'une ligne supprimable a forcément
  été RENDUE, donc lue. Le corollaire compte pour la suite — **toute suppression écrite hors du
  chemin de l'affichage** (une passe de synchro, un ménage au lancement, un futur import) travaille
  sur des objets que personne n'a lus, et retombe donc dans le cas qui casse. Là, il faudra
  `deleteCascadeAndSave`, quelle que soit la profondeur.

  Les deux fausses pistes valent d'être connues, parce qu'elles étaient plausibles et qu'elles ont
  coûté deux tours : une variable mal nommée dans le code de suppression (réelle, sans rapport),
  puis l'écriture EventKit intercalée dans la cascade (réelle aussi — corrigée, à garder — mais le
  crash est resté identique à la ligne près). Ce qui a tranché : comparer les rapports de crash
  AVANT et APRÈS le correctif. Mêmes frames SwiftData, même assertion. Un correctif qui ne déplace
  pas la pile n'a pas touché la cause.
- **EventKit s'écrit APRÈS SwiftData, jamais pendant.** Effacer un rappel fait écrire EventKit, qui
  poste `.EKEventStoreChanged`, qui relance la synchro de `ContentView`, qui RÉENREGISTRE le même
  contexte — au milieu de la mutation en cours. Le motif tient en trois temps : lire les
  IDENTIFIANTS de rappel (des `String`, qui survivent à ce que SwiftData efface), supprimer et
  enregistrer, puis effacer les rappels. Écrit une fois dans `ModelContext.deleteTasksAndSave` et
  dans `TodoList.delete` ; les cinq pages faisaient l'inverse, chacune de son côté.
- **La synchro Rappels se réveille pour son propre bruit — et il faut DEUX déclencheurs, pas un.**
  `.EKEventStoreChanged` sonne à chacune de NOS écritures, et le fil principal la livre PENDANT la
  passe (chaque `await` lui rend la main). Sans temporisation, une passe qui pousse dix rappels
  relançait dix fois la relecture des complétions, chacune posant un `calendarItem(withIdentifier:)`
  synchrone par tâche liée : le carré du nombre de tâches, sur le fil qui dessine. D'où la seconde
  d'attente et TOUT sous `withSyncLock` (cf. `ContentView.syncWithReminders`).

  Symétriquement, cette notification ne dit rien de NOS écritures à nous : dater une tâche n'écrit
  que dans SwiftData. Le sens app → Rappels n'avait donc aucun déclencheur, et partait au prochain
  réveil venu d'ailleurs — une quinzaine de secondes, mesurées à l'usage. `ModelContext.didSave` est
  son pendant exact, et c'est ce qui manquait.
- **Le push effaçait la preuve que la suppression attendait.** Supprimer un rappel dans l'app
  Rappels ne supprimait pas la tâche, et le rappel réapparaissait dans la seconde. La chaîne : la
  passe note l'absence (première des deux preuves de `reminderVanished`), puis le push, juste
  derrière, voit « pas de rappel » — indiscernable de « jamais poussé » — et le RECRÉE avec un
  identifiant neuf. La passe suivante trouve un rappel vivant : plus rien n'a jamais disparu, la
  seconde preuve ne peut pas exister. D'où `wasSeenAlive` dans `RemindersSync.needsPush`, qui
  départage les deux façons d'être introuvable : **jamais vu vivant** = identifiant périmé (base
  restaurée) ⇒ recréer, ce qui rend ses rappels à une sauvegarde qu'on remonte ; **vu vivant puis
  disparu** = l'utilisateur vient de le supprimer ⇒ ne rien faire, et laisser la preuve s'accumuler.
  La règle générale : *une passe qui répare ne doit pas effacer ce qu'une autre passe est en train
  de constater.*

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
- **Tout dépliant s'anime avec `disclosureFlow`.** Un chevron qui tourne et un contenu qui
  apparaît, c'est le MÊME geste partout : repli d'un projet dans la sidebar, section
  d'« Aujourd'hui » ou de « Tâches », archives d'une liste, sous-tâches d'une ligne. Quatre valeurs
  avaient divergé (`.snappy(0.2)`, `.snappy(0.22)`, `.easeInOut(0.2)`, le défaut de
  `DisclosureGroup`) — assez pour que le même clic ne se sente pas pareil d'un onglet à l'autre.
  Un nouveau dépliant prend `disclosureFlow` (défini dans `TaskPageChrome.swift`, avec les autres
  courbes), jamais une durée inventée sur place — et TOUJOURS en enveloppant la MUTATION, pas le
  rendu : `withAnimation(disclosureFlow) { … }` autour de l'écriture de l'état (`isCollapsed.toggle()`,
  `toggled.insert/remove`, `undatedExpanded = …`), jamais un `.animation(value:)` posé sur la vue.
  Un `DisclosureGroup` change son binding depuis son propre bouton AppKit, hors de notre code : un
  `.animation(value:)` à côté n'attrape pas cette transaction-là — testé, résultat instantané et
  saccadé. Passer par un `Binding` maison dont le `set` fait le `withAnimation` (cf.
  `TodayPageView.undatedExpansion`, `AllTasksPageView.expansion(of:)`) au lieu du binding brut.

  **Le contenu fond en s'ouvrant, en plus de la hauteur qui s'anime — et toujours EXPLICITEMENT,**
  jamais laissé au défaut implicite de SwiftUI (un ancêtre qui pose un jour `.transition(.identity)`
  l'éteindrait sans qu'on le voie). Deux cas, selon si le contenu est démonté ou pas :
  - **retrait/insertion réel** (`if isOpen { rows }`, comme la sidebar ou les archives d'une liste) →
    `.transition(.opacity)` sur ce bloc (au besoin `Group { … }` s'il contient plusieurs vues) ;
  - **`DisclosureGroup`** — son contenu reste MONTÉ, replié par hauteur seulement, un `.transition`
    n'y change donc rien → `.opacity(isOpen ? 1 : 0)` sur le contenu, qui suit la même transaction
    que le `withAnimation` du binding puisqu'il lit le même booléen.

  Un nouveau dépliant applique les DEUX : `disclosureFlow` sur la mutation, fondu sur le contenu.

  **Les sections de « Tâches » ne sont plus des `DisclosureGroup`** (6 août 2026) : elles relèvent
  donc du PREMIER cas, pas du second. Un `DisclosureGroup` rogne son contenu à son propre cadre, et
  la ligne qu'on tire en sortait — elle se faisait couper net en pleine course. Remplacés par un
  dépliant fait main (bouton + `if open { rows }`), qui ne rogne rien. Bénéfice au passage : le
  contenu est vraiment RETIRÉ quand la section est repliée, au lieu d'être seulement replié en
  hauteur — une section fermée ne coûte donc plus rien à rendre. Le binding maison
  (`AllTasksPageView.expansion(of:)`) reste, lui : c'est ce qui met la mutation dans la transaction
  animée, quel que soit le dépliant.

  **L'état du dépliant n'est JAMAIS un `@AppStorage`, même s'il doit survivre au relancement.**
  Mesuré : un dépliant piloté par `@AppStorage` reste totalement instantané sous `withAnimation` —
  son écriture passe par `UserDefaults`, hors du mécanisme d'observation que SwiftUI sait capturer
  dans une transaction animée. C'était le bug de « Tâches sans date » (Aujourd'hui), invisible tant
  que personne ne comparait à un dépliant voisin. Un `@State` ordinaire, avec la persistance écrite
  à la main dans son `set` (cf. `TodayPageView.undatedExpansion`), donne le même résultat SANS ce
  piège.
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

## Le contrôle systématique — à relire AVANT d'écrire, pas après

Ce ne sont pas des bonnes intentions : **chaque ligne ci-dessous a coûté un bug MESURÉ**, et la
plupart la même journée, le 6 août 2026. Un correctif ou une fonctionnalité qui arrive se confronte
à cette liste AVANT la première ligne de code — sinon on rachète un défaut déjà payé.

### 1. Ce qui se rend à chaque image

- **Une page qui se réordonne au doigt se construit EN ENTIER.** Jamais `LazyVStack` : les décalages
  font entrer et sortir les rangées du viewport paresseux, qui les détruit et les reconstruit en
  boucle, menus contextuels compris. Mesuré : fil principal **saturé à 100 % contre 9 %**.
- **Une propriété calculée d'un `@Model` ne se lit JAMAIS depuis une rangée** — `progress`,
  `remainingCount`, `orderedTasks`… Chaque lecture traverse SwiftData. Elle se calcule UNE fois en
  tête du `body` qui rend la collection, puis se distribue (cf. `SidebarCounts`, `TodayPage.build`).
- **Le corps d'une vue qui porte un `@Query` se rejoue bien plus souvent qu'on ne le croit** :
  SwiftData l'invalide sans qu'AUCUNE écriture n'ait lieu (vérifié — ni `didSave`, ni `willSave`, ni
  `ObjectsDidChange`). Il doit donc être **bon marché**, pas rare.
- Pour savoir QUI invalide : `Self._printChanges()`. Un `sample` dit où part le temps, jamais quelle
  dépendance a bougé.

### 2. Deux pièges de layout que le compilateur ne voit pas

- **`VStack` ne propose pas sa largeur à ses enfants**, contrairement à `LazyVStack` : chacun se
  réduit à sa taille idéale. Invisible sur du texte (qui a une largeur intrinsèque), **fatal sur un
  `TextField` focalisé** — son rendu passe au field editor d'AppKit, de largeur idéale nulle, et le
  champ disparaît purement et simplement. D'où une largeur EXPLICITE ; `maxWidth: .infinity` ne
  résout rien quand la proposition entrante est déjà indéterminée.
- **`VStack` distribue la hauteur restante à ses enfants FLEXIBLES.** Une forme (`RoundedRectangle`,
  `Circle`, `Capsule`) est flexible dans les deux dimensions : posée en FRÈRE dans un `ZStack`, elle
  fait gonfler sa rangée jusqu'à avaler la page. Une décoration se pose en `.background` /
  `.overlay` de ce qu'elle habille — elle en reçoit alors la taille. Jamais en frère.

### 3. Les animations

- **Une transition d'état est déclenchée par la PAGE, en `withAnimation`.** Un `.animation(value:)`
  posé sur la rangée ne couvre que ce qui le PRÉCÈDE dans la chaîne : le contenu part sur une
  courbe, le cadre sur une autre, et la carte se déforme en s'ouvrant.
- Un `.animation(value:)` ne se justifie que pour un changement qu'AUCUNE transaction de page ne
  couvre — une relation SwiftData notifiée hors transaction, un survol local à la rangée.
- Une courbe partagée (`taskInsert`, `taskFlow`, `disclosureFlow`, `taskDrop`) est partagée : la
  changer change TOUTES les pages. Si le besoin est local, il faut une courbe nommée, pas un
  ajustement en douce de celle des autres.

### 4. Les fenêtres

- **Un popover est une FENÊTRE, et SwiftUI la présente depuis le LAYOUT.** Dans cette app, ça tue le
  process. Une palette, un sélecteur, un panneau se révèlent DANS la fenêtre.

### 5. Le fil principal

- **Rien de synchrone vers un service système sur le fil qui dessine.** EventKit interrogé par
  identifiant est un aller-retour XPC bloquant : 97 échantillons de fil principal gelés, app AU
  REPOS. Une passe qui interroge N éléments fait UNE requête asynchrone, pas N.

### 6. Ce qui doit rester vrai après

- `swift build` et `swift test` verts, **et le cliquet d'avertissements** (`FULL_WARNING_CHECK=1`).
- **Un changement d'UI se REGARDE.** `screencapture` fonctionne, et un `.task` temporaire piloté par
  une variable d'environnement rejoue un geste sans souris — c'est ainsi qu'ont été trouvés le titre
  disparu en édition et le pavé bleu géant d'une en-tête tirée.
- **Aucun banc de mesure ne se committe.**
- Un commentaire devenu faux se corrige DANS le même commit. Ce fichier a menti sur cinq points ;
  chacun a coûté une fausse piste.

### 7. Quand REFUSER, et le dire

Une demande qui exige l'un de ces points ne s'implémente pas en l'état :

- rétablir `LazyVStack` sur une page qui glisse ;
- lire un compteur de `@Model` par rangée « juste pour cette fois » ;
- présenter un popover depuis un item de menu ;
- poser un `.animation(value:)` sur une rangée dont la page pilote déjà l'état ;
- appeler un service système en synchrone depuis une vue.

La conduite à tenir : **dire lequel des sept points est en cause, proposer l'alternative qui le
respecte — et si elle n'existe pas, proposer d'ABANDONNER la fonctionnalité** plutôt que de la
livrer en dette. Ce projet a déjà retiré trois faux-semblants pour cette raison : *une
fonctionnalité est branchée ou elle n'existe pas.*

## Déjà essayé et REJETÉ — ne pas refaire

- **YouTube comme source de la musique du pomodoro** (8 août 2026). La seule voie sanctionnée est
  une `WKWebView` + l'API IFrame, et une WebView demande une FENÊTRE — or on joue justement quand la
  fenêtre de Today est fermée. Ordonner une fenêtre est la famille de plantages non résolue de ce
  projet (cf. `NSRemoteView` plus haut), et on n'a aucun `WKWebView` à nous aujourd'hui : WebKit
  n'est là que traîné par Sparkle. S'ajoute que le lecteur caché est contraire aux conditions de
  YouTube, ce qui compte pour une app destinée à être vendue. Retenu à la place : AppleScript vers
  Spotify ou Musique, qui exposent déjà `play`, `pause` et `sound volume`.
- **L'API web de Spotify pour lister les playlists de l'utilisateur** (8 août 2026). Son dictionnaire
  AppleScript n'expose que `application` et `track` — aucun accès à la bibliothèque, rien à
  contourner. L'API web le ferait, au prix d'un compte développeur, d'OAuth PKCE, du Trousseau, et
  d'un plafond à **25 utilisateurs** tant qu'une extension de quota n'est pas accordée par Spotify.
  Écarté pour épargner un collage qu'on fait une fois. Retenu à la place : l'endpoint `oembed`
  PUBLIC, sans authentification, qui rend le NOM d'une playlist depuis son lien — de quoi nommer
  l'entrée toute seule et dire « lien non reconnu ». Musique, lui, expose bien `user playlist` : là,
  le menu déroulant existe.

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
- **`LazyVStack` sur une page qui se RÉORDONNE au doigt.** Essayé sur « Aujourd'hui », mesuré,
  rejeté : le glisser en devient PIRE, pas meilleur — les décalages font entrer et sortir les
  rangées du viewport paresseux, qui les détruit et les reconstruit en boucle.

  **La leçon n'avait pas été appliquée à la page d'une LISTE**, restée en `LazyVStack` — et c'est
  exactement pour ça que son glisser était saccadé alors que celui de « Tâches » est fluide. Le
  différentiel est venu de l'usage, pas du code : « dans Tâches c'est parfaitement fluide, dans une
  liste c'est tout l'inverse ». Mesuré le 6 août 2026, même glissement simulé sur 24 lignes,
  fenêtre de 2 s : **fil principal saturé à 100 % en `LazyVStack`** (964 échantillons de travail,
  dont 134 dans `TaskRow.body` et 38 dans `TaskRow.taskMenu` — le menu contextuel entier
  reconstruit en boucle) **contre 9 % en `VStack`** (124). Les trois pages qui glissent sont
  désormais toutes en `VStack`.

  **Le remplacement ne se fait PAS à l'identique, et l'oubli casse l'édition.** Un `LazyVStack`
  impose d'office la largeur proposée à ses rangées ; un `VStack`, non — il leur propose une
  largeur INDÉTERMINÉE et chacune se réduit à sa taille idéale. Invisible sur une ligne au repos
  (son texte a une largeur intrinsèque), **fatal sur la ligne en ÉDITION** : son `TextField`
  focalisé délègue son rendu au field editor d'AppKit, dont la largeur idéale est nulle — le titre
  disparaît purement et simplement, carte ouverte et vide. Constaté à l'usage, puis reproduit et
  corrigé à la capture d'écran. D'où la largeur EXPLICITE
  (`.frame(width: geo.size.width - 2 * gutter)`) et non un `maxWidth: .infinity`, qui ne résout
  rien quand la proposition entrante est déjà indéterminée. Re-mesuré après correction : le gain
  du glissement tient (7 %).

  Corollaire pour la suite : **une page qui glisse se construit en entier.** Le jour où une liste
  se comptera en centaines de lignes, la réponse ne sera toujours pas `LazyVStack` — ce sera de
  borner ce qu'on rend, ou de ne plus déplacer les rangées elles-mêmes.
- **Faire taire les diagnostics de chemins de clé** en marquant les `@Model` `@unchecked Sendable`.
  Ce serait un mensonge (ce sont des classes mutables) et le rafistolage que le projet refuse. Trou
  entre SwiftData et Swift 6, à laisser tel quel.
- **Le popover pour choisir une couleur** (en-tête de section, projet). Écrit d'abord, et il TUE
  l'app : une fenêtre présentée depuis le layout, cf. les Pièges. Remplacé par une révélation dans
  la fenêtre — la palette s'ouvre dans la pilule de l'en-tête, sous la rangée du projet. Le
  sous-menu, lui, avait déjà été rejeté avant (un menu contextuel macOS ne dessine pas les images
  de ses items : sept lignes de texte identiques à lire une par une).
- **Le curseur « main » sur toute la ligne.** Sur macOS, la main signale un bouton ou un lien, jamais
  une ligne sélectionnable (Finder, Mail, Rappels gardent la flèche). Le comportement actuel — main
  sur la case à cocher seulement — est correct. Si un repère de survol manque, la bonne réponse est
  un fond de survol, pas un changement de curseur.
- **Le glisser d'une section à l'autre sur « Tâches »**, et son corollaire « la section repliée
  s'ouvre au survol ». Écrit, mesuré, retiré le 6 août 2026 : le détail et les deux défauts sont
  dans les Pièges. La répartition d'une tâche vers une liste passe par la SIDEBAR, qui est une
  cible fixe et n'a aucun trou à calculer — c'est fait (cf. `Models/SidebarDrop.swift`).

  **Le déplier-au-survol de la SIDEBAR, lui, est voulu et il reste** : survoler une ligne de projet
  pendant un glissement la déplie pour révéler ses listes. Ce n'est PAS le rétablissement de ce qui
  a été rejeté, et la nuance est toute la différence entre les deux : ici rien n'est calculé au
  survol — pas de trou à ouvrir, pas d'ordre à deviner, la sidebar ne fait que montrer des cibles
  qu'elle avait cachées. Sur « Tâches », déplier changeait la géométrie DU CALCUL en cours.

## Outils

- **`swift build` ET `swift test` sont imposés à la fin de chaque tour**, pas laissés à la mémoire :
  `Scripts/build-check.sh`, branché en hook `Stop` (cf. `.claude/settings.local.json`), refuse de
  rendre la main et remonte les erreurs. C'est ce qui fait tourner les deux cliquets de schéma
  AVANT qu'on lance l'app — sans ça, « Rouge ⇒ ne pas lancer l'app » était une consigne sans
  exécution derrière. Coût : ~2 s à chaud. Une seule passe de correction automatique
  (`stop_hook_active`), pour ne pas boucler.
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
rangement par glisser vers la barre latérale (cf. `Models/SidebarDrop.swift` — seules les LISTES
accueillent ; survoler un projet le déplie pour montrer les siennes),
renommage, complétion, projets, sous-tâches, notes en texte riche, saisie rapide (`@demain`,
`#liste`), raccourcis texte et combinaisons globales, archivage, pomodoro (avec sa musique de
session — cf. `Services/MusicPlayer.swift` : le lecteur de l'utilisateur piloté par AppleScript,
fondu jusqu'au silence avant l'alarme, playlists enregistrées dans les défauts comme les raccourcis ;
la règle qui porte tout est `PomodoroTimer.syncMusic` — *elle joue si et seulement si un travail est
en cours*), rappels et calendrier
Apple (lecture, report de complétion, et pont bidirectionnel optionnel — cf. `RemindersSync` : une
liste Rappels désignée dans les Réglages, les tâches datées y partent, ses rappels datés en
reviennent ; c'est `needsPush` qui empêche la boucle — il compare les JOURS quand la tâche n'a pas
d'heure, ce qui préserve celle d'un rappel importé, et l'instant COMPLET quand elle en a une, sans
quoi changer l'heure d'une tâche ne partirait jamais), recherche (`QuickFindPanel`),
capsule de saisie rapide hors
app, et les quatre pages intelligentes — **Tâches**, **Aujourd'hui**, **À venir**, **Archives** —
toutes réelles.

Le pont Rappels est **branché dans les deux sens et vérifié à la main le 6 août 2026** : une tâche
datée part dans la liste-pont, un rappel coché là-bas coche la tâche ici, un rappel supprimé là-bas
emporte la tâche, et changer l'heure d'un côté la met à jour de l'autre — sans que rien ne reparte
en boucle. Il avait été coupé le 5 août après avoir supprimé trois tâches ; ce qui a rendu la
suppression sûre est dans les Pièges (les deux preuves de `reminderVanished`, et `wasSeenAlive`,
sans lequel la suppression depuis Rappels ne pouvait pas fonctionner du tout).

`HUDWindow` est la pastille d'accusé de réception, en bas de l'ÉCRAN : elle ne parle QUE des gestes
dont le résultat n'est pas à l'écran — une tâche déposée par la capsule depuis une autre app, un
Pomodoro piloté au clavier (cf. les commandes `!pomodoro…` d'`AppCommand`, à qui elle sert de seul
retour, puisqu'elles n'activent délibérément pas la fenêtre). Là où la rangée apparaît sous les yeux,
elle n'a rien à dire, et l'y ajouter la transformerait en bruit.

Les cinq pages se comportent pareil, et ça a été vérifié à la main, dans les deux thèmes :
sélection au clic, ⌫, ↑/↓, clic dans le vide qui relâche, ⌘Z après une suppression. Le glisser
existe sur une liste, « Aujourd'hui » et « Tâches » — sur cette dernière, borné à sa propre section
(cf. Pièges). « À venir » et « Archives » n'en ont pas, et c'est un choix : elles sont ordonnées par
une date, il n'y a pas d'ordre manuel à y mettre. **La page d'un PROJET non plus**, et pas par
choix d'ordre : c'est un tableau de cartes (une carte par liste), il n'y a aucune ligne de tâche à
y glisser. Ce fichier a longtemps prétendu le contraire.

**Plus rien n'est du décor.** Les trois derniers faux-semblants ont été retirés le 2 août 2026, et
le principe qui les a fait partir vaut pour la suite : *une fonctionnalité est branchée ou elle
n'existe pas.* Du code en pause ment sur ce que l'app sait faire, et se paie deux fois — une fois
en le maintenant, une fois en le débranchant.

- l'**icône tag**, décorative faute de modèle qui porte des tags → retirée ;
- **`TaskItem.hasTime`**, jamais mis à vrai par aucun chemin (l'app ne posait que des JOURS), ce qui
  rendait l'affichage d'heure d'« À venir » inatteignable → retiré du schéma (cf. `SchemaV1`).
  Revenu le 5 août 2026 sous la forme de `TaskItem.whenMinutes` (schéma 5.0.0) — AVEC son sélecteur
  (`WhenPicker`), comme la règle l'exigeait : le jour reste dans `when`, l'heure vit à côté ;
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
