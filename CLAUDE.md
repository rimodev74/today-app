# Today

Clone natif macOS de Things (Cultured Code). SwiftPM (pas de `.xcodeproj`), SwiftUI + SwiftData,
~12 400 lignes dans `Sources/Today/` (+ ~2 670 de tests). Le produit s'appelle **Today** ;
« ThingsClone » ne survit que dans le nom de `ThingsCloneApp.swift`.

- Scope, décisions produit et découpage : `ROADMAP.md`.
- **Les récits derrière les règles d'ici — mesures, fausses pistes, ce qui a tranché : `PIEGES.md`.**
  Ce fichier PRESCRIT, `PIEGES.md` EXPLIQUE. On y ouvre la section de la zone qu'on touche, jamais le
  fichier entier. Une règle qui semble arbitraire y a sa justification : la lire avant de la
  contourner.

## Lancer

```bash
./run-dev.sh      # POUR TOUT DEV/TEST : bundle "TodayDev.app" isolé — process, base SwiftData,
                  # sauvegardes et raccourci global (⌃⌥Espace) séparés de l'app du quotidien.
                  # C'est CE script qui vérifie un changement d'UI.
./run.sh          # L'INSTANCE DU QUOTIDIEN, en RELEASE. Jamais pour itérer : il tue le process
                  # "Today" en cours, donc l'app qu'on utilise pour de vrai.
                  # `./run.sh debug` pour le pas-à-pas.
swift build       # compilation seule (~0,2 s incrémental)
swift test        # en mémoire ou sur un store temporaire — jamais la vraie base
```

**Jamais `swift run`** : l'exécutable nu n'est pas un bundle, macOS ne lui donne pas la chrome de
fenêtre native. `Scripts/make-app.sh` fabrique bundle + Info.plist + signature, et refuse de tourner
si une instance de Today est en cours (→ `PIEGES.md` § Fenêtres).

## Architecture — ce qui porte le reste

Ces pièces tiennent des invariants que rien d'autre ne garantit. Les modifier demande de lire leur
en-tête AVANT d'écrire.

| Pièce                                                    | Rôle                                                                        |
| -------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `Models/SortedByKey.swift`                               | trier des `@Model` en ne lisant les clés qu'UNE fois par élément             |
| `Models/Reorder.swift`                                   | l'arithmétique du glissement : repli, écartement, trou, ordre obtenu         |
| `Models/TaskFocus.swift`                                 | quelle ligne est sélectionnée, laquelle est en édition                       |
| `Models/TaskPageRows.swift` (`TaskPageBlock`)            | ce qu'une page affiche : des pans de lignes, visibles ou repliés             |
| `Models/TaskPageReorder.swift`                           | l'état d'un glissement : cadres, séquence figée, décalages, ordre obtenu     |
| `Models/SidebarDrop.swift`                               | lâcher une tâche sur la barre latérale + `TaskItem.move(to:)`                |
| `Models/TodayPage.swift`, `AllTasksPage`, `UpcomingPage`, `ArchivePage` | ce que chaque page intelligente présente                       |
| `Views/TaskList/TaskPageChrome.swift` (`TaskPageBase`)   | le socle de TOUTE page de tâches : ⌫, ↑/↓, clic dans le vide, cadres         |
| `Models/TodaySchema.swift` + `Tests/…/DeployedSchemaSnapshot.swift` | la forme des données, écrite deux fois et confrontée à chaque test |
| `Services/StoreBackup.swift`                             | copie la base AVANT de l'ouvrir, quand la forme des modèles a changé         |
| `TodayApp.openStore`                                     | l'unique façon d'ouvrir un store                                             |

Toutes existent parce que la même logique vivait en double dans des vues. Ce que chacune a remplacé,
et le bug que ça coûtait : `PIEGES.md`.

### Comment une page de tâches se construit

Les CINQ pages (`ListPageView`, `TodayPageView`, `AllTasksPageView`, `UpcomingPageView`,
`ArchivePageView`) passent par le même socle. Une sixième s'y branche sans une ligne de plus :

1. un `@State TaskFocus` pour la sélection, et `.rowPressGesture` sur chaque ligne — un geste UNIQUE
   qui sélectionne, renomme et glisse (`ListPageView` a le sien, plus riche : il emmène aussi les
   blocs d'en-tête). Surtout pas deux gestes séparés : dès qu'une vue porte un tap double, AppKit
   retient le tap simple le temps de la fenêtre de double-clic ;
2. `.measureTaskRow(task)` sur chaque ligne — sans ça la page reste aveugle : le clic dans le vide ne
   peut pas savoir qu'il est dans le vide, et rien ne peut se glisser ;
3. `.taskPageBase(focus:blocks:delete:reorder:newTask:)`, en déclarant ses pans dans l'ordre du
   rendu. `reorder` ET `newTask` sont sans valeur par défaut : la page se prononce, `nil` compris ;
4. pour glisser, en plus : un `@State TaskPageReorder`, `.taskRowDragLayer` sur les lignes,
   `.taskReorderPlaceholder` sur la page, `reorder.track(…)` à l'empoignade et `dropTaskDrag(…)` au
   relâchement.

Ce qui reste à la page, et à elle seule, c'est ce qu'elle ÉCRIT au relâchement — un rang sur
« Aujourd'hui », un rang plus un rattachement sur « Tâches » (`AllTasksPage.applyDrop`). C'est la
frontière posée en tête de `Reorder.swift` : l'arithmétique est commune, la règle métier ne l'est pas.

**Deux axes d'ordre, et ils ne se mélangent pas.** `TaskItem.sortIndex` est attribué PAR LISTE : sur
une vue qui mélange les provenances, deux tâches peuvent porter le même rang, elles ne sont pas
comparables. D'où `TaskItem.smartOrder`, l'ordre manuel des vues intelligentes — **0 = jamais posée à
la main**, ce qui laisse `SmartList.sort` PLACER ce qui arrive et garantit qu'une base d'avant garde
exactement l'ordre qu'elle avait.

Les pages partagent aussi `TaskRow`, les courbes `taskFlow`/`taskSelectFade`/`taskInsert`/`taskDrop`
et les métriques `gutter`/`rowInset`. Une page se construit AVEC ces briques, jamais à côté d'elles.

## Le contrôle systématique — à relire AVANT d'écrire, pas après

Chaque ligne a coûté un bug MESURÉ. Un correctif ou une fonctionnalité se confronte à cette liste
AVANT la première ligne de code — sinon on rachète un défaut déjà payé.

### 1. Ce qui se rend à chaque image

- **Une page qui se réordonne au doigt se construit EN ENTIER.** Jamais `LazyVStack` — mesuré : fil
  principal **saturé à 100 % contre 9 %**. Et le remplacement impose une largeur EXPLICITE aux
  rangées, sinon la ligne en édition disparaît. → `PIEGES.md` § Layout.
- **Une propriété calculée d'un `@Model` ne se lit JAMAIS depuis une rangée** — `progress`,
  `remainingCount`, `orderedTasks`… Chaque lecture traverse SwiftData. Elle se calcule UNE fois en
  tête du `body` qui rend la collection, puis se distribue (cf. `SidebarCounts`, `TodayPage.build`,
  `ProjectBoard.Card`, `SubtaskTally`). Vaut aussi pour une RELATION relue plusieurs fois dans la
  même rangée : mesuré 0,73 ms par rendu de page contre 0,18 une fois lue en une passe.
- **Une vue invisible coûte plein tarif.** `.hidden()` est rendu ; un bloc replié à hauteur nulle
  construit tout son contenu. Mesuré sur la capsule : 8 ms pour une copie cachée servant à mesurer
  une hauteur, 19 ms pour une liste repliée que personne ne regardait — sur 36 ms d'ouverture.
  Une `GeometryReader` posée dans une telle copie coûte en plus : sa préférence réécrit un `@State`
  à chaque passe de layout, et le body se rejouait **sept fois par frappe**. → `PIEGES.md`.
- **Le corps d'une vue qui porte un `@Query` se rejoue bien plus souvent qu'on ne le croit** :
  SwiftData l'invalide sans qu'AUCUNE écriture n'ait lieu. Il doit être **bon marché**, pas rare.
- **Tout nouveau tri sur un `@Model` passe par `sortedByKey`**, jamais par `.sorted { }` — une
  comparaison ordinaire relit ses clés à travers SwiftData. (Inutile sur des types de valeur.)
- Pour savoir QUI invalide : `Self._printChanges()`. Un `sample` dit où part le temps, jamais quelle
  dépendance a bougé.

### 2. Trois pièges de layout que le compilateur ne voit pas

- **`VStack` ne propose pas sa largeur à ses enfants**, contrairement à `LazyVStack` : chacun se
  réduit à sa taille idéale. Fatal sur un `TextField` focalisé (field editor de largeur idéale nulle,
  le champ disparaît). Largeur EXPLICITE ; `maxWidth: .infinity` ne suffit pas.
- **`VStack` distribue la hauteur restante à ses enfants FLEXIBLES.** Une forme posée en FRÈRE dans un
  `ZStack` fait gonfler sa rangée jusqu'à avaler la page. Une décoration se pose en `.background` /
  `.overlay` de ce qu'elle habille. Jamais en frère.
- **Une mesure posée APRÈS un `.offset` ne bouge pas** — `.offset` est un effet de rendu, pas de
  layout. Une `GeometryReader` va AVANT.

### 3. Les animations

- **Une transition d'état est déclenchée par la PAGE, en `withAnimation`.** Un `.animation(value:)`
  posé sur la rangée ne couvre que ce qui le PRÉCÈDE dans la chaîne : le contenu part sur une courbe,
  le cadre sur une autre, et la carte se déforme en s'ouvrant.
- Un `.animation(value:)` ne se justifie que pour un changement qu'AUCUNE transaction de page ne
  couvre — une relation SwiftData notifiée hors transaction, un survol local à la rangée.
- Une courbe partagée (`taskInsert`, `taskFlow`, `disclosureFlow`, `taskDrop`) est partagée : la
  changer change TOUTES les pages. Besoin local ⇒ courbe nommée, pas un ajustement en douce.
- **Tout dépliant : `disclosureFlow` sur la MUTATION + un fondu EXPLICITE sur le contenu.** Jamais un
  `@AppStorage` comme état — son écriture échappe à la transaction animée. → `PIEGES.md` § Animations.
- **L'entrée et la sortie d'une FENÊTRE se jouent sur le CALQUE, pas en SwiftUI.** Une échelle animée
  fait re-rendre tout le sous-arbre à chaque image — mesuré sur la capsule : 543 ms de CPU par cycle
  contre 89 une fois confiée à une `CASpringAnimation` (`QuickEntryWindow.animate`). La frontière
  est la fenêtre : ce qui la fait paraître appartient au calque, ce qui remue dedans reste en
  SwiftUI. → `PIEGES.md` § Animations.

### 4. Les fenêtres

- **Un popover est une FENÊTRE, et SwiftUI la présente depuis le LAYOUT.** Dans cette app, ça tue le
  process. Une palette, un sélecteur, un panneau se révèlent DANS la fenêtre. → `PIEGES.md`.
- **Un champ focalisé veut une fenêtre conteneur, du début à la fin.** Le premier répondeur fait
  créer la liste de complétion d'AppKit, HORS PROCESS ; privée de fenêtre — jamais affichée, ou
  détruite sous elle — son abonnement survit et la prochaine fenêtre ordonnée à l'écran tue le
  process. C'était les 27 plantages d'août 2026. D'où : pas de premier répondeur dans une fenêtre
  qu'on n'affichera pas (`prewarmRichTextEditing`, retiré), et une fenêtre qui a hébergé un champ
  focalisé se GARDE (la capsule réutilise son `NSPanel` et ne renouvelle que son contenu).
  → `PIEGES.md` § Fenêtres.

### 5. Le fil principal

- **Rien de synchrone vers un service système sur le fil qui dessine.** EventKit interrogé par
  identifiant est un aller-retour XPC bloquant : 97 échantillons de fil principal gelés, app AU
  REPOS. Une passe qui interroge N éléments fait UNE requête asynchrone, pas N.

### 6. Les données — rouge ⇒ ne pas lancer l'app

- **TOUT changement de forme d'un `@Model`** (ajout compris) demande une montée de version ET une
  étape de migration. Marche à suivre : les cinq points en tête de `TodaySchema.swift`. Deux cliquets
  le vérifient (`SchemaFingerprintTests`, `StoreFixtureTests`) — ne jamais recopier l'empreinte pour
  faire taire le test. → `PIEGES.md` § SwiftData.
- **Une migration se répète à blanc sur une COPIE de la vraie base** avant de lancer l'app.
- **Le store contient de la VRAIE donnée** : `~/Library/Application Support/Today/default.store`.
  Compter avant d'y toucher : `sqlite3 default.store "select count(*) from ZTASKITEM;"`.
- **EventKit s'écrit APRÈS SwiftData, jamais pendant** : lire les identifiants → supprimer et
  enregistrer → effacer les rappels.
- **Une suppression écrite hors du chemin de l'affichage** (synchro, ménage au lancement, import)
  passe par `deleteCascadeAndSave` : sans instantané en mémoire, l'`UndoManager` fait tomber le
  process.

### 7. Ce qui doit rester vrai après

- `swift build` et `swift test` verts, **et le cliquet d'avertissements** (`FULL_WARNING_CHECK=1`).
  Un build incrémental n'a rien vérifié du reste du module.
- **Un changement d'UI se REGARDE — via `./run-dev.sh`, jamais `./run.sh`** — et **dans les deux
  thèmes** : les régressions de mode sombre sont la rechute la plus fréquente du projet.
  `screencapture` fonctionne ; un `.task` temporaire piloté par une variable d'environnement rejoue
  un geste sans souris.
- **Le minimum macOS (`.v14`) n'est pas vérifié par le build** — une API `@available(macOS 15+)`
  compile sans broncher. À vérifier à l'œil.
- **Aucun banc de mesure ne se committe.**
- Un commentaire devenu faux se corrige DANS le même commit. Ce fichier a menti sur cinq points, tous
  listés en fin de `PIEGES.md`.

### 8. Quand REFUSER, et le dire

Une demande qui exige l'un de ces points ne s'implémente pas en l'état :

- rétablir `LazyVStack` sur une page qui glisse ;
- lire un compteur de `@Model` par rangée « juste pour cette fois » ;
- présenter un popover depuis un item de menu ;
- poser un `.animation(value:)` sur une rangée dont la page pilote déjà l'état ;
- appeler un service système en synchrone depuis une vue ;
- rétablir l'inventaire par sections sur « Tâches » (et avec lui le glisser entre sections).

Conduite à tenir : **dire lequel de ces points est en cause, proposer l'alternative qui le respecte —
et si elle n'existe pas, proposer d'ABANDONNER la fonctionnalité** plutôt que de la livrer en dette.
Ce projet a déjà retiré trois faux-semblants pour cette raison : _une fonctionnalité est branchée ou
elle n'existe pas._

## Déjà essayé et REJETÉ — ne pas reproposer

Chacune a été écrite, mesurée, retirée. **Deux l'ont été DEUX fois, par oubli** — d'où cette liste.
Chiffres et détail : `PIEGES.md` § Déjà rejeté.

1. **YouTube** comme source de la musique du pomodoro (+330 Mo et ~6 % CPU en continu, mesuré).
2. **L'API web de Spotify** pour lister les playlists (OAuth + plafond à 25 utilisateurs).
3. Un **fond transparent** pour attraper le clic dans le vide.
4. Un **`PreferenceKey`** pour dériver l'ordre du clavier.
5. **`LazyVStack`** sur une page qui se réordonne au doigt.
6. **`@unchecked Sendable`** pour taire les diagnostics de chemins de clé.
7. Le **popover de choix de couleur** (et le sous-menu avant lui).
8. Le **curseur « main »** sur toute la ligne.
9. Le **glisser entre sections de « Tâches »**, et l'ouverture d'une section au survol. (Le
   déplier-au-survol de la SIDEBAR, lui, est voulu et il reste — rien n'y est calculé au survol.)
10. **L'inventaire complet sur « Tâches »** — le non-classé, « Aujourd'hui », un dépliant par projet
    et par liste, les événements du Calendrier. Puis, en remplacement des dépliants, une **barre de
    tags** (Tout / À classer / Aujourd'hui / les projets) : écrite, regardée, jetée le même jour.
    Les deux répondaient à la même question qu'ailleurs — la page ne montre plus que l'Inbox.

## Conventions

- **Natif d'abord, toujours.** Les régressions de ce projet viennent toutes de réimplémentations de ce
  que macOS fait déjà. Si l'API native ne convient pas, dire pourquoi en commentaire avant d'écrire
  du custom.
- **La logique non triviale sort de la vue, et elle est testée.** Un calcul d'indices, une machine à
  états, un parseur, une règle de tri vont dans `Models/` — type de valeur, sans SwiftUI — avec leur
  fichier de tests. **Une vue orchestre et anime ; elle ne calcule pas.** Une propriété calculée
  d'une `View` repart de zéro à CHAQUE rendu : construire une fois en tête de `body`, puis distribuer.
- **Avant d'ajouter un `@State`, chercher le type qui porte déjà ce comportement** (sélection,
  édition, brouillon, glissement). Un second état pour une notion existante est exactement la façon
  dont deux pages se mettent à diverger sans que personne ne le voie.
- **Une couleur figée se double.** Quand une valeur de maquette s'impose, passer par
  `NSColor(name:) { appearance in … }` avec sa version sombre (cf. `SidebarView.rowFill`,
  `thingsSelectionFill`, `HeaderRow.dragLayer`). Une `Color(red:…)` nue est un bug de mode sombre en
  attente.
- **Ce qui s'installe se démonte.** Moniteur `NSEvent`, observateur `NotificationCenter`, `Timer` :
  chacun a son `removeMonitor` / `removeObserver` / `invalidate` sur le chemin de sortie
  (`dismantleNSView`, `onDisappear`).
- **Un réglage qui peut s'oublier en silence est un bug en attente.** `TaskPageBase.reorder` et
  `.newTask` n'ont PAS de valeur par défaut : les cinq pages se prononcent, `nil` compris. Une valeur
  par défaut se justifie quand l'omission est un CHOIX raisonnable ; pas quand elle produit une page
  à moitié branchée.
- **Les commentaires disent _pourquoi_, jamais _quoi_.**
- **Un nom qui ment coûte plus cher qu'un commentaire manquant.** Si la doc d'un type existe pour
  démentir son propre nom, c'est le nom qu'il faut changer.
- **En français.** Identifiants en anglais, commentaires et documentation en français.
- `// ponytail:` marque une simplification délibérée et son plafond.
- Pas de trailer `Co-Authored-By` ni de mention d'outil dans les commits.

## Outils

- **`swift build` ET `swift test` sont imposés à la fin de chaque tour** par `Scripts/build-check.sh`,
  branché en hook `Stop` (cf. `.claude/settings.local.json`). ~2 s à chaud, une seule passe de
  correction automatique. C'est ce qui fait tourner les cliquets de schéma AVANT qu'on lance l'app.
- **Contrôle complet des avertissements** :
  `find Sources Tests -name '*.swift' -exec touch {} +` puis `swift build -c release && swift test`.
  Un build incrémental à 0,2 s n'a rien vérifié (mesuré : 0 avertissement contre 40).
- **sourcekit-lsp est installé** : utiliser les outils `lsp_*` plutôt que deviner un type ou grep des
  références. Après création ou renommage d'un fichier, son index remonte des erreurs fantômes —
  **`swift build` fait foi**.
- Formatage : `xcrun swift-format -i -r Sources Tests` (valeurs par défaut).
- Publier : `./Scripts/quick.sh "message"` (bump + DMG signé + release + appcast + push). Il fait
  `git add -A` et le commit LUI-MÊME — ne rien commiter avant, ça ferait deux commits.
- **`/push`** enveloppe ce script : cliquet d'avertissements complet, tests, revue du diff contre la
  liste ci-dessus, contrôle visuel si l'UI bouge, **arrêt obligatoire pour faire valider à la main
  le message de mise à jour**, puis `quick.sh`. Un point rouge et il s'arrête.
  Sa définition est dans `.claude/commands/push.md`.

## État réel

Tout ce qui suit est branché et vérifié à la main, dans les deux thèmes. **Plus rien n'est du
décor** — _une fonctionnalité est branchée ou elle n'existe pas._

Listes, tâches, en-têtes de section, réordonnancement (tâches et blocs d'en-tête), rangement par
glisser vers la barre latérale (seules les LISTES accueillent ; survoler un projet le déplie),
renommage, complétion, projets, sous-tâches, notes en texte riche, saisie rapide (`@demain`,
`#liste`), raccourcis texte et combinaisons globales, archivage, recherche (`QuickFindPanel`),
capsule de saisie rapide hors app, et les quatre pages intelligentes — **Tâches**, **Aujourd'hui**,
**À venir**, **Archives**.

- **Pomodoro** — sons réglables par étape, musique de session pilotée par AppleScript (Spotify ou
  Musique, cf. `Services/MusicPlayer.swift`), fondu jusqu'au silence avant l'alarme, playlists dans
  les défauts. La règle qui porte tout est `PomodoroTimer.syncMusic` : _elle joue si et seulement si
  un travail est en cours._
- **Rappels / Calendrier Apple** — lecture, report de complétion, et pont bidirectionnel optionnel
  (`RemindersSync`) : une liste Rappels désignée dans les Réglages, les tâches datées y partent, ses
  rappels datés en reviennent. `needsPush` empêche la boucle. Vérifié à la main le 6 août 2026 dans
  les deux sens, suppression comprise.
- **`HUDWindow`** ne parle QUE des gestes dont le résultat n'est pas à l'écran — une tâche déposée par
  la capsule depuis une autre app, un pomodoro piloté au clavier (`!pomodoro…` d'`AppCommand`, qui
  n'active délibérément pas la fenêtre). Là où la rangée apparaît sous les yeux, l'y ajouter en
  ferait du bruit.
- **Le glisser** existe sur une liste, « Aujourd'hui » et « Tâches ». « À venir » et « Archives »
  n'en ont pas : elles sont ordonnées par une date. La page d'un PROJET non plus — c'est un tableau
  de cartes, il n'y a aucune ligne de tâche à y glisser.
- **« Tâches » ne montre QUE la boîte de réception** — une zone de dépôt, l'endroit où l'on note sans
  classer. Elle a porté l'inventaire complet (sections par projet, par liste, « Aujourd'hui »,
  Calendrier) : retiré le 12 août 2026, chaque section répondait à une question à laquelle sa propre
  page répondait déjà.

### Dette connue, par ordre de coût

1. **Le champ « Nouvelle tâche » et ⌘N ne créent pas la même chose**, et c'est voulu : le champ note
   vite (titre + valider), ⌘N crée une tâche VIDE ouverte en édition. Une tâche restée entièrement
   vide est supprimée à la fermeture de son édition (`TaskItem.isBlank`), sinon ⌘N puis Échap laisse
   un « Sans titre » en base. **Le champ ne s'affiche que sur un pan VIDE** (ou focalisé, pour la
   saisie enchaînée) : `ListPageView.showsNewTaskField` porte la règle, et `physicalRows` DOIT la
   relire — une ligne physique de plus d'un côté décale tous les trous d'insertion. Sans champ
   affiché, le ⊕ de la barre du bas retombe sur ⌘N.
2. **Toutes les `@Query` lisent la table entière** puis filtrent et trient en mémoire. Sans objet à 87
   tâches (0,46 ms pour « Aujourd'hui » ; 11,7 ms à 2 000). Plafond à connaître, pas à corriger —
   passer en `#Predicate` le jour où la base se comptera en milliers.
3. **Le mode langage reste Swift 5.** La concurrence stricte est vérifiée et tous les diagnostics
   restants sont le même : `SortDescriptor(\Model.x)` veut un chemin de clé `Sendable`, qu'un
   `@Model` ne peut pas être. Trou d'Apple, pas dette du projet. **Ce cliquet porte sur leur NATURE,
   pas leur nombre** — tout diagnostic qui n'est PAS un chemin de clé est une régression d'isolation
   à corriger sur-le-champ.

## Style de communication

ON OPTIMISE LES TOKENS DE SORTIE EN ÉVITANT LES MOTS ET PHRASES INUTILES.

- Opinions tranchées. Prendre position, pas « ça dépend ».
- Jamais « Bonne question », « Je serais ravi », « Absolument ». Répondre directement.
- Concision obligatoire. Si ça tient en une phrase, une phrase.
- Humour autorisé quand naturel. Pas forcé.
- Dire les choses franchement. Avec tact mais sans édulcorer.
- Être l'assistant avec qui on voudrait parler à 2h du mat. Pas un robot corporate.
