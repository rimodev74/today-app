# Pièges de Today — les récits

`CLAUDE.md` porte les règles. Ce fichier porte ce qui les a produites : le symptôme, la mesure, les
fausses pistes, ce qui a tranché. **Il ne se lit pas en entier** — on ouvre la section de la zone
qu'on touche, et seulement celle-là.

Chaque section a coûté au moins un bug réel. Une règle de `CLAUDE.md` qui semble arbitraire a son
explication ici ; avant de la contourner, la lire.

---

## Fenêtres et plantages

### Un popover est une FENÊTRE, et SwiftUI la présente depuis le LAYOUT

`PopoverBridge.preferencesDidChange` → `updatePresentations` → `NSPopover.showRelativeToRect:`, le
tout sous `NSHostingView.layout()`. Or cette app fait circuler des préférences en continu (chaque
ligne republie son cadre, `TaskRowFrameKey`, à chaque mise en page). Ordonner une fenêtre enfant en
plein calcul de layout fait passer AppKit par `addChildWindow:` → `_rebuildOrderingGroup:`, qui
réordonne les autres fenêtres du groupe ; l'une d'elles héberge une vue hors-process,
`-[NSRemoteView containingWindowWillOrderOnScreen:]` lève une exception, et comme on est sous
`_NSViewLayout` AppKit la convertit en `+[NSApplication _crashOnException:]` : **SIGTRAP, sans un
mot**, et le gestionnaire de `CrashLog` ne la voit JAMAIS (AppKit passe devant). Pile complète :
`Today-2026-08-06-164404.ips`, geste « ••• → Couleur… » sur une en-tête. Trois plantages de la même
famille le 5 août.

**Ce n'est pas le menu qui se ferme derrière.** Hypothèse plausible, et FAUSSE : mesurée avec un
reproducteur AppKit nu, un `NSPopover` présenté dans le même tour de boucle qu'un `NSMenu` qui se
ferme passe 12 fois sur 12. C'est la présentation depuis le layout qui casse.

Conséquence : **une palette, un sélecteur, un panneau ne prennent pas de fenêtre** — ils se révèlent
DANS la fenêtre (cf. `PalettePicker`, et `QuickFindPanel` avant lui). Les popovers qui restent
(`WhenPicker`, `DeadlinePicker`, la date d'une liste) sont sous la même menace ; celui de `TaskRow`
se referme avant d'écrire, ce qui traite le symptôme, pas la cause.

### Donner le premier répondeur dans une fenêtre JAMAIS affichée arme un plantage différé

27 plantages entre le 6 et le 9 août 2026, tous la même assertion, tous mortels :

    NSInternalInconsistencyException
    assertion failed: '<NSRemoteView … SPCompletionListServiceViewController> notified of
    <NSStatusBarWindow …> but expected (null)'
    in -[NSRemoteView containingWindowWillOrderOnScreen:] line 4221 (ViewBridge)

**Ce que la fenêtre citée n'est PAS** : la coupable. Elle ne fait qu'ORDONNER. 23 fois l'icône de
barre de menus (la pile le dit : `NSStatusItemVariantSceneDelegate scene:willConnectToSession:` →
`_wakeStatusItem` → `orderWindowFrontInAppKitOnly`, c'est-à-dire la CRÉATION du status item au
lancement, pas l'ouverture de son menu), 4 fois la capsule de saisie rapide.

**La cause** : `prewarmRichTextEditing()`. Donner le premier répondeur à un champ de texte fait
créer la liste de complétion d'AppKit, qui vit HORS PROCESS (`SPCompletionListServiceViewController`,
via ViewBridge). Cette vue distante s'abonne à « une fenêtre va s'afficher ». Dans une fenêtre jamais
ordonnée à l'écran — exactement ce qu'était le préchauffage — elle garde son abonnement sans jamais
avoir de fenêtre conteneur, et la PROCHAINE fenêtre affichée dans le process fait lever l'assertion.
D'où le décalage qui a égaré : le geste qui meurt n'a aucun rapport avec celui qui a armé le piège.

**Mesuré**, banc reproductible (poster la notification distribuée d'ouverture de capsule, compter les
bascules avant la mort ; 5 manches, plafond 80) :

| variante                                  | manches mortes | mortes dès la 1re bascule |
| ----------------------------------------- | -------------- | ------------------------- |
| préchauffage tel quel (témoin)            | 4/5            | 4                         |
| + les deux fenêtres retenues à vie        | 3/5            | 3                         |
| + `isAutomaticTextCompletionEnabled=false` | 4/5           | 2                         |
| + les fenêtres ordonnées à l'écran        | 4/5            | 2                         |
| préchauffage réduit aux notes seules      | 3/5            | 1                         |
| **préchauffage RETIRÉ**                   | **1/5**        | **0**                     |

Retiré, donc. Le flash de panneau système au tout premier focus est revenu : c'est le prix, et il est
sans commune mesure avec un process qui meurt.

**Réfuté — ne pas réessayer** :

- **Sparkle / WebKit n'y sont pour RIEN.** L'hypothèse tenait : `Sparkle.framework` lie bien `WebKit`
  (`otool -L`), et notre binaire est le seul du bundle à lier Sparkle. Elle est fausse : compilée
  SANS Sparkle (dépendance retirée du `Package.swift`, `otool -L` propre), l'app charge quand même
  WebKit, WebCore, WebKitLegacy, JavaScriptCore et SafariPlatformSupport, et lance quand même son
  helper. Aucune de nos dépendances directes ne lie WebKit (`dyld_info -dependents` sur AppKit,
  SwiftUI, EventKit, SwiftData, Foundation, Carbon : zéro) — il arrive par un `dlopen` d'AppKit en
  cours de route. **Le compter comme établi a coûté deux jours.**
- retenir les fenêtres de préchauffage, les ordonner à l'écran, couper la complétion automatique,
  n'en garder qu'une moitié : les quatre mesurés ci-dessus, aucun ne corrige.
- chercher une variante de Sparkle sans interface : elle n'existe pas, son paquet SPM ne fournit
  qu'un framework pré-compilé. (Sans objet désormais.)

**Le résidu, et sa cause — même famille** : 3 plantages subsistaient sur 594 bascules, tous au même
endroit. `QuickEntryWindow.show` DÉTRUISAIT le panneau pour en reconstruire un neuf à chaque
ouverture ; le champ de texte du panneau mourant laissait le même orphelin, que le panneau neuf,
ordonné juste après, réveillait. C'est la MÊME cause vue par l'autre bout : là le préchauffage ne
donnait jamais de fenêtre conteneur à la vue distante, ici il la lui retirait.

Le panneau est donc désormais créé UNE fois et gardé pour la vie du process ; ce qui est neuf à
chaque ouverture, c'est son `contentView` — donc l'état SwiftUI et le canal. Il est REMPLACÉ par une
`NSView` vide à la fermeture, sans quoi les trois `@Query` de la capsule (listes, projets, TOUTES les
tâches) continueraient de se rejouer capsule fermée. **Mesuré : 5 manches de 150 bascules, 750 au
total, zéro mort.** En prime, les 85 échantillons de `setContentView` par ouverture ne sont plus
payés qu'une fois.

**Règle qui en sort** : ne jamais donner le premier répondeur à un champ de texte dans une fenêtre
qu'on n'affichera pas — et ne pas jeter une fenêtre qui a hébergé un champ focalisé. Les deux moitiés
de la même règle : la vue distante de complétion veut une fenêtre conteneur, et elle la veut du début
à la fin.

#### Le 10 août 2026 : la règle rattrape l'heure d'une tâche

`Today-2026-08-10-115358.ips`, même pile au mot près (`_CFBundleGetValueForInfoKey` →
`-[NSRemoteView containingWindowWillOrderOnScreen:]`, réveil de l'icône de barre de menus en
ordonnateur). Geste : régler l'heure de plusieurs tâches d'affilée ; mort à la 5e. Un popover EST une
fenêtre jetée à chaque fermeture, et `WhenPicker` y posait un `DatePicker(.hourAndMinute)` — sur
macOS un `NSDatePicker` champ+incrémenteur, donc un CHAMP DE TEXTE. Chaque heure réglée laissait donc
un abonné hors process sans fenêtre conteneur. C'est la moitié « ne pas jeter une fenêtre qui a
hébergé un champ focalisé », vue depuis un panneau qu'on croyait inoffensif parce qu'il ne contenait
« qu'un sélecteur ».

Remplacé par deux menus déroulants (heure, minutes au pas de 5) : un `NSPopUpButton` ne prend jamais
le premier répondeur texte. **Ça ne rend pas les popovers sûrs** — `WhenPicker`, `DeadlinePicker`, la
date d'une liste et la feuille `SchedulePlannerView` (qui, elle, a encore un champ Titre ET deux
champs d'heure) restent des fenêtres présentées depuis le layout. Le correctif de fond reste le même
qu'ailleurs : se révéler DANS la fenêtre.

### Reconstruire le bundle sous les pieds d'une instance vivante

`Scripts/make-app.sh` REFUSE de tourner si une instance de Today est en cours : reconstruire sous
ses pieds lui retire son `Info.plist`, la première lecture CFBundle lève une exception, et l'app
meurt en « Abort trap: 6 » sans aucun rapport avec le code qu'on vient d'écrire. C'était LE plantage
fantôme de la phase de dev.

**Ne JAMAIS poster la notification d'ouverture de la capsule à une instance dont on refait le
bundle.** C'est ce qui a tué l'app le 4 août 2026, et la pile le dit mot pour mot :
`QuickEntryWindow.show` → `makeKeyAndOrderFront` → `NSRemoteView` → `_CFBundleGetValueForInfoKey` →
exception → « Abort trap: 6 ». Ordonner une fenêtre à l'écran fait lire l'`Info.plist` du bundle par
une vue hors-process ; si `make-app.sh` est en train de le réécrire, il n'y a rien à lire. `run.sh`
tue bien l'instance AVANT de reconstruire, mais un script qui parle à l'app par
`DistributedNotificationCenter` court-circuite cette garantie.

### `NSSetUncaughtExceptionHandler` ne voit presque RIEN dans une app AppKit

`CrashLog` a parlé dans le vide pendant des semaines. Mesuré le 6 août 2026 en levant une vraie
`NSException` : toute exception levée pendant que la boucle d'événements tourne est attrapée par
AppKit, qui appelle `+[NSApplication _crashOnException:]` et déclenche un SIGTRAP **avant**
`_objc_terminate` — or c'est `_objc_terminate` qui appelle le gestionnaire. Il ne reste couvert que
ce qui lève hors boucle. C'est ce qui a rendu muets les deux plantages du 6 août.

Le point d'accroche qui marche est `-[NSApplication reportException:]`, qu'AppKit appelle AVEC
l'exception avant de tuer le process. `CrashLog` l'échange (swizzle) et rappelle l'implémentation
d'origine — il observe, il ne détourne pas. La voie propre (sous-classe `NSApplication` +
`NSPrincipalClass`) est fermée : `TodayApp.init` touche `NSApplication.shared` avant que
`NSApplicationMain` ne lise cette clé, la classe est déjà figée.

**La raison s'écrit dans un FICHIER**, `~/Library/Application Support/Today/crash.log`, à côté de la
base. Vérifié de bout en bout : exception levée pour de vrai, fichier écrit, nom + raison + pile en
clair.

`CrashLog` n'attrape que les exceptions Objective-C : un `fatalError` de Swift (`EXC_BREAKPOINT`,
`brk 1`, pile qui part de `_assertionFailure`) passe à côté, et le rapport système n'en garde pas la
phrase. La seule façon de la lire est de **rejouer le geste hors de l'app** — un test sur une COPIE
de la vraie base, où le message s'imprime en clair.

**`_CFBundleGetValueForInfoKey + 0` dans une pile d'exception ne veut RIEN dire.** Ce symbole
apparaît en position 2 de TOUTES ces piles, y compris celle du banc de vérification qui ne lit aucun
bundle : c'est l'adresse de retour d'`objc_exception_throw` résolue au symbole précédent le plus
proche, pas un appel réel. Ce fichier a bâti sur lui le diagnostic du « plantage fantôme » —
l'explication reste plausible pour le cas de `make-app.sh`, mais **cette frame n'en est pas la
preuve**.

### Le journal système ne remonte rien de ce process

`log show --predicate 'process == "Today"'` rend 0 ligne, y compris pour un `NSLog` que le binaire
exécute vraiment. Tracer un geste passe par un fichier plat — l'app n'a aucun entitlement de
sandbox, `/tmp` lui est ouvert. Pour un `print`, poser `setvbuf(stdout, nil, _IONBF, 0)` : sinon la
sortie reste dans le tampon et on croit que rien ne s'exécute.

---

## SwiftData

### Un `@Query` se ré-invalide SANS qu'aucune écriture n'ait lieu

Mesuré le 6 août 2026 avec `Self._printChanges()` : ouvrir la carte d'édition d'une tâche imprime, à
chaque fois, `SidebarView: \_QueryController<TodoList, String>.<computed (Bool)> changed` — puis
pareil à la fermeture. Or **rien n'est écrit** : vérifié en écoutant `ModelContext.didSave`,
`ModelContext.willSave` et `NSManagedObjectContextObjectsDidChange`, aucune des trois ne sonne.
C'est une sur-notification de SwiftData (l'accès à une relation suffit), et **on ne peut pas
l'empêcher depuis ici**.

Conséquence, et c'est elle qui compte : **le corps d'une vue qui porte un `@Query` se rejoue bien
plus souvent qu'on ne le croit** — il faut donc qu'il soit BON MARCHÉ, pas qu'il soit rare.
`SidebarView.body` coûtait ~13 ms, soit plus d'une image entière à 120 Hz, et il tombait pile au
démarrage de l'animation d'ouverture d'une carte : le décrochage se voyait.

La cause du prix : `listRow` lisait `list.progress` puis `list.remainingCount` DEUX fois, soit trois
traversées de la relation `TodoList.tasks` PAR RANGÉE. D'où `Models/SidebarCounts.swift` — tous les
compteurs en UNE passe, distribués aux rangées, exactement le motif de `TodayPage.build` et des
décalages de `projectsGroup`. Mesuré au `sample` sur le geste rejoué en boucle : travail du fil
principal par ouverture/fermeture **1264 → ~940 échantillons** (deux runs : 970 et 907, contre 1264
avant), soit ~6,6 ms → ~4,9 ms par image. Il y a de nouveau de la marge sous les 8,3 ms d'une image
à 120 Hz.

Pour diagnostiquer un rendu de trop : `Self._printChanges()` dit QUELLE dépendance a bougé, ce qu'un
`sample` ne dira jamais. Pour déclencher un geste sans souris, un `.task` temporaire piloté par une
variable d'environnement vaut mieux qu'un clic simulé.

### Lire une propriété d'un `@Model` n'est PAS un accès mémoire

Ça traverse la machinerie SwiftData (`_$backingData`). Conséquence non évidente : un comparateur
ordinaire relit ses clés à chaque comparaison, soit n·log n fois — ~4 400 accès pour trier 86 tâches
sur cinq clés, et le tri coûtait dix fois le filtrage alors qu'il fait moins de travail. D'où
`sortedByKey`, qui décore avant de trier.

Corollaire à ne pas sur-appliquer : sur des types de valeur (dates, chaînes, `EKEvent`), la
décoration est une allocation pour rien.

### TOUT changement de forme d'un `@Model` demande une montée de version ET une étape

Y compris un ajout. `CurrentSchema` pointe les classes VIVANTES et son numéro de version ne bouge
pas tout seul — SwiftData compare les NUMÉROS, jamais les formes. Deux issues, toutes deux muettes à
la compilation :

- **numéro inchangé** → il conclut « rien à faire », ne joue aucune étape, et **l'ouverture échoue** :
  la vraie base part en quarantaine et l'app démarre VIDE. Mesuré le 3 août 2026 en ajoutant
  `Project.colorRaw`, un simple `String?` — « un ajout est absorbé tout seul » était faux, ça a
  coûté une restauration.
- **numéro monté mais étape manquante** sur un renommage / une suppression / un changement de type →
  `swift build` passe, le store s'ouvre SANS erreur, et **la donnée part**.

Marche à suivre : les cinq points en tête de `TodaySchema.swift`. **Rouge ⇒ ne pas lancer l'app.**
Deux cliquets le disent, et ils ont été vérifiés en REJOUANT la faute :

1. `SchemaFingerprintTests` — l'empreinte SHA de la forme (`StoreBackup.fingerprint`, qui la
   calculait déjà pour décider d'une sauvegarde) confrontée à une constante versionnée. Modifier un
   `@Model` la fait bouger, point. Ne JAMAIS recopier l'empreinte pour faire taire le test : c'est
   l'oubli qu'il attrape.
2. `StoreFixtureTests` — une VRAIE base par version livrée (`Tests/TodayTests/Fixtures/`), rouverte
   par `TodayApp.openStore`. À chaque montée de version, y déposer la base de la version sortante et
   l'ajouter à `shipped` ; les fichiers déjà là ne se retouchent jamais.

Pourquoi ces deux-là et pas `SchemaCompatibilityTests` seul : ce dernier fabrique ses bases à partir
d'une DESCRIPTION en code (`DeployedSchemaSnapshot`), éditable — et éditée le 3 août dans le même
commit que les modèles, ce qui l'a laissé vert pendant que la vraie base partait en quarantaine.
Mesuré en rejouant ce commit : les 4 `SchemaCompatibilityTests` verts, les 2 cliquets rouges. Un
binaire versionné ne dérive pas. `DeployedSchemaSnapshot` se retouche EN DERNIER.

Troisième filet, à l'exécution : `StoreBackup` copie la vraie base AVANT de l'ouvrir dès que la
forme a bougé, dans `~/Library/Application Support/Today-Backups/` (3 copies gardées, journal SQLite
compris). Restaurer = recopier les trois fichiers par-dessus `default.store`, app fermée.

**Une migration se répète à blanc sur une COPIE de la vraie base avant de lancer l'app.** Les tests
portent sur des fixtures ; la vraie base peut contenir ce qu'aucune fixture ne décrit. Copier
`default.store` + ses deux journaux ailleurs, l'ouvrir par `TodayApp.openStore`, compter.

### Une valeur par défaut est évaluée UNE fois, pas une fois par ligne

Mesuré le 3 août 2026 : ajouter `var uuid: UUID = UUID()` en migration `.lightweight` remplit TOUTES
les lignes existantes avec le MÊME identifiant (`Schema.Attribute.defaultValue` contient un UUID
concret, pas un générateur). Un identifiant d'identité partagé par tout le monde ne distingue rien —
c'est le doublon en masse dès le premier jour de synchro. D'où l'étape `.custom` 3→4 et son
`didMigrate`, gardée par `SchemaMigrationV4Tests`. Règle générale : dès qu'un champ ajouté doit
valoir quelque chose de DIFFÉRENT par ligne, `.lightweight` ne peut pas convenir.

### Le modèle est prêt pour CloudKit, et un test le tient

`CloudKitReadinessTests` vérifie sur le `Schema` lui-même les quatre contraintes qu'iCloud impose :
toute propriété optionnelle ou pourvue d'une valeur par défaut, aucune `@Attribute(.unique)`, toute
relation « à un » optionnelle et pourvue d'un inverse, une identité stable (`uuid`) sur chaque
entité. Elles ne coûtent rien tant que la synchro n'est pas branchée — c'est justement pourquoi
elles se cassent sans qu'on le voie.

### Le store contient de la VRAIE donnée

Pas des jeux d'essai — et il vit dans `~/Library/Application Support/Today/default.store` (cf.
`Services/StoreLocation.swift`, qui déménage aussi l'ancienne base au premier lancement). Le compter
avant d'y toucher : `sqlite3 default.store "select count(*) from ZTASKITEM;"`.

**Il vivait à la RACINE de `~/Library/Application Support/`**, sans sous-dossier, parce que SwiftData
nomme son fichier par défaut `default.store` et le pose là quand rien ne lui dit où aller. Le 5 août
2026, une autre app a écrit SON `default.store` par-dessus le nôtre : deux applications sans rapport
se disputaient le même chemin, et la première à écrire gagnait. C'est pour ça que le dossier au nom
de l'app n'est pas cosmétique.

### Un store laissé sale par un plantage se répare tout seul — à la DEUXIÈME tentative

Le 4 août 2026, l'app a été tuée en plein travail et a laissé un journal WAL de 2,4 Mo non rejoué.
L'ouverture suivante a ÉCHOUÉ, la base est partie en quarantaine, l'app est repartie vide — mais
cette tentative ratée avait rejoué le journal au passage, et les MÊMES octets se rouvrent depuis
sans une erreur (21 tâches, 5 listes, vérifié par `TodayApp.openStore` sur une copie). La
quarantaine avait donc coûté une app vide pour une panne qui n'existait déjà plus. D'où la seconde
tentative dans `TodayApp.container`, avant toute mise à l'écart.

### La quarantaine se DIT à l'utilisateur

`StoreQuarantine` écarte la base illisible et l'app repart vide ; « ça se remarque » ne suffisait
pas — rien ne disait que le travail était encore là, à côté, sous un autre nom, et le vrai risque
était de tout retaper par-dessus. Le rapport passe par les défauts (`StoreQuarantine.reportKey`)
parce que la quarantaine a lieu pendant la construction du container, avant qu'aucune fenêtre
n'existe ; `ContentView` le consomme et l'affiche une fois.

### L'annulation et la cascade ne se mélangent pas

`ContentView` branche l'`UndoManager` de la fenêtre sur le contexte (c'est ce qui fait marcher ⌘Z).
Avec lui branché, enregistrer une cascade fait tomber SwiftData sur `DataUtilities.swift:541: A
snapshot should exist before creating a new snapshot for undo`. Supprimer un projet depuis la
sidebar plantait l'app à tous les coups (6 août 2026). Mesuré en rejouant la suppression sur une
copie neuve de la vraie base, un projet par copie : **sans** manager, les 6 projets partent sans un
mot ; **avec**, le premier fait tomber le processus.

D'où `ModelContext.deleteCascadeAndSave`, qui débranche le manager le temps de la cascade et VIDE sa
pile (elle parle peut-être d'objets que la cascade vient d'effacer). Réservé aux deux appelants qui
cascadent : tout y passer retirerait ⌘Z de la suppression d'une tâche, qui marche et qui compte.
Gardé par `CascadeDeleteTests` — qui ne reproduit RIEN si l'on oublie de rouvrir le store entre le
semis et la suppression : il faut des objets relus du disque, sans instantané en mémoire.

**Ce n'est PAS la profondeur de la cascade qui décide.** Ce fichier a affirmé le contraire, et c'est
faux. Mesuré le 6 août 2026 en écrivant `CascadeDeleteTests` : avec le manager branché, supprimer
UNE tâche relue du disque fait tomber la même assertion — y compris après avoir effacé ses
sous-tâches d'abord. Ce qui change tout, c'est de **LIRE ses propriétés avant** : la même
suppression passe alors sans un mot. C'est l'instantané qui manquait, pas un niveau de trop.

Conséquence pratique : ⌫ est hors de portée du défaut parce qu'une ligne supprimable a forcément été
RENDUE, donc lue. Le corollaire compte pour la suite — **toute suppression écrite hors du chemin de
l'affichage** (une passe de synchro, un ménage au lancement, un futur import) travaille sur des
objets que personne n'a lus, et retombe donc dans le cas qui casse. Là, il faudra
`deleteCascadeAndSave`, quelle que soit la profondeur.

Les deux fausses pistes valent d'être connues : une variable mal nommée dans le code de suppression
(réelle, sans rapport), puis l'écriture EventKit intercalée dans la cascade (réelle aussi —
corrigée, à garder — mais le crash est resté identique à la ligne près). Ce qui a tranché : comparer
les rapports de crash AVANT et APRÈS le correctif. Mêmes frames SwiftData, même assertion. **Un
correctif qui ne déplace pas la pile n'a pas touché la cause.**

---

## EventKit et la synchro Rappels

### Lire un rappel par son identifiant est un XPC SYNCHRONE

`EKEventStore.calendarItem(withIdentifier:)` fait un aller-retour bloquant vers le démon Rappels :
sur le fil principal, il le GÈLE le temps de la réponse. Trois fonctions en posaient un PAR tâche
liée (`completionStates`, `reminderDay`, `reminderVanished`). Mesuré au `sample`, app AU REPOS :
**97 échantillons de fil principal arrêtés dans
`__NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__` sur une fenêtre de 4 s** — la moitié de
tout le travail non-oisif du fil qui dessine, pour une app à laquelle personne ne touchait. Et c'est
linéaire en tâches liées, rejoué à chaque `.EKEventStoreChanged` **et** à chaque
`ModelContext.didSave`, donc après chaque titre validé, chaque case cochée, chaque dépôt.

Remplacé par UN instantané asynchrone par passe (`RemindersService.passSnapshot`, pris dans
`withSyncLock`) : `fetchReminders` rend la main tout de suite et rappelle hors du fil principal.
Re-mesuré : **97 → 0**. Dans ce service, tout ce qui interroge EventKit par identifiant passe par
l'instantané, jamais par `store` en direct.

### EventKit rend des optionnels implicites

`EKEvent.startDate`, `EKCalendarItem.calendar`, `EKCalendar.cgColor`, `.title` sont
`null_unspecified` : les lire sans garde plante sur un calendrier d'abonnement mal formé. Filtrer À
L'ENTRÉE, dans `RemindersService`, jamais chez chaque appelant.

### EventKit s'écrit APRÈS SwiftData, jamais pendant

Effacer un rappel fait écrire EventKit, qui poste `.EKEventStoreChanged`, qui relance la synchro de
`ContentView`, qui RÉENREGISTRE le même contexte — au milieu de la mutation en cours. Le motif tient
en trois temps : lire les IDENTIFIANTS de rappel (des `String`, qui survivent à ce que SwiftData
efface), supprimer et enregistrer, puis effacer les rappels. Écrit une fois dans
`ModelContext.deleteTasksAndSave` et dans `TodoList.delete` ; les cinq pages faisaient l'inverse,
chacune de son côté.

### La synchro se réveille pour son propre bruit — et il faut DEUX déclencheurs

`.EKEventStoreChanged` sonne à chacune de NOS écritures, et le fil principal la livre PENDANT la
passe (chaque `await` lui rend la main). Sans temporisation, une passe qui pousse dix rappels
relançait dix fois la relecture des complétions, chacune posant un `calendarItem(withIdentifier:)`
synchrone par tâche liée : le carré du nombre de tâches, sur le fil qui dessine. D'où la seconde
d'attente et TOUT sous `withSyncLock` (cf. `ContentView.syncWithReminders`).

Symétriquement, cette notification ne dit rien de NOS écritures à nous : dater une tâche n'écrit que
dans SwiftData. Le sens app → Rappels n'avait donc aucun déclencheur, et partait au prochain réveil
venu d'ailleurs — une quinzaine de secondes, mesurées à l'usage. `ModelContext.didSave` est son
pendant exact, et c'est ce qui manquait.

### Le push effaçait la preuve que la suppression attendait

Supprimer un rappel dans l'app Rappels ne supprimait pas la tâche, et le rappel réapparaissait dans
la seconde. La chaîne : la passe note l'absence (première des deux preuves de `reminderVanished`),
puis le push, juste derrière, voit « pas de rappel » — indiscernable de « jamais poussé » — et le
RECRÉE avec un identifiant neuf. La passe suivante trouve un rappel vivant : plus rien n'a jamais
disparu, la seconde preuve ne peut pas exister.

D'où `wasSeenAlive` dans `RemindersSync.needsPush`, qui départage les deux façons d'être
introuvable : **jamais vu vivant** = identifiant périmé (base restaurée) ⇒ recréer, ce qui rend ses
rappels à une sauvegarde qu'on remonte ; **vu vivant puis disparu** = l'utilisateur vient de le
supprimer ⇒ ne rien faire, et laisser la preuve s'accumuler.

Règle générale : _une passe qui répare ne doit pas effacer ce qu'une autre passe est en train de
constater._

`needsPush` compare aussi les JOURS quand la tâche n'a pas d'heure, ce qui préserve celle d'un
rappel importé, et l'instant COMPLET quand elle en a une — sans quoi changer l'heure d'une tâche ne
partirait jamais.

---

## Layout, gestes et glissement

### Un glisser qui saccade n'est presque jamais le calcul

`Reorder.swift` est partagé et couvert par 21 tests ; quand un glissement tremble, chercher dans
cette liste — chaque ligne a coûté un aller-retour de vérification manuelle :

1. **la translation se lit dans un repère FIXE** (`.named(taskPageSpace)`), jamais le repère local,
   qui est celui de la rangée — c'est-à-dire celui que le geste déplace. Mesurer un déplacement dans
   un repère que ce déplacement bouge fait trembler la ligne ;
2. **les cadres sont gelés à l'empoignade**, et il ne suffit pas d'ignorer la nouvelle mesure : il ne
   faut pas l'ÉCRIRE. `frame(in:)` inclut le décalage des lignes tirées, et un `@State` réécrit à
   l'identique invalide quand même la vue — c'est l'invalidation qui boucle ;
3. **un seul stockage de cadres par page.** Deux ont coexisté, un seul gelait : la boucle est revenue
   par la porte de derrière ;
4. **l'ordre écrit et le retour des décalages à zéro tiennent dans UNE transaction** (cf.
   `dropTaskDrag`). Séparés, la rangée saute à sa nouvelle place pendant que son décalage s'anime
   depuis l'ancienne : elle part à l'opposé avant de revenir ;
5. **la page réaffiche sa séquence VIVANTE**, jamais la copie figée. Rendre l'une puis rebasculer sur
   l'autre au relâchement produit le même symptôme que le point 4, pour une autre raison : le
   `ForEach` réordonne ses identités au moment où les décalages retombent. Rien n'écrit pendant un
   geste, la séquence vivante ne bouge donc pas d'elle-même. Le CALCUL, lui, garde bien sa copie.

### Une mesure posée APRÈS un `.offset` ne bouge pas

`.offset` est un effet de RENDU : il ne déplace pas la position de layout. Une `GeometryReader`
posée après lui dans la chaîne devient donc la SŒUR de la vue décalée, reste calée sur la place de
repos, et publie un cadre parfaitement immobile pendant tout le geste. Posée AVANT, elle est sous
l'offset et le suit.

C'est la même mécanique que le gel des cadres de `TaskPageReorder`, vue de l'autre côté : là c'est
le piège qui fait boucler, ici c'est le mécanisme qui fait marcher `publishTaskDrag` — le calque du
rangement vers la sidebar. Rien de tout ça ne se voit à la compilation : mesuré le 6 août 2026, le
calque n'apparaissait jamais et aucune ligne de sidebar ne s'allumait, sans un mot nulle part.

### `LazyVStack` sur une page qui se réordonne au doigt

Essayé sur « Aujourd'hui », mesuré, rejeté : le glisser en devient PIRE, pas meilleur — les décalages
font entrer et sortir les rangées du viewport paresseux, qui les détruit et les reconstruit en
boucle.

**La leçon n'avait pas été appliquée à la page d'une LISTE**, restée en `LazyVStack` — et c'est
exactement pour ça que son glisser était saccadé alors que celui de « Tâches » est fluide. Mesuré le
6 août 2026, même glissement simulé sur 24 lignes, fenêtre de 2 s : **fil principal saturé à 100 %
en `LazyVStack`** (964 échantillons de travail, dont 134 dans `TaskRow.body` et 38 dans
`TaskRow.taskMenu` — le menu contextuel entier reconstruit en boucle) **contre 9 % en `VStack`**
(124).

**Le remplacement ne se fait PAS à l'identique, et l'oubli casse l'édition.** Un `LazyVStack` impose
d'office la largeur proposée à ses rangées ; un `VStack`, non — il leur propose une largeur
INDÉTERMINÉE et chacune se réduit à sa taille idéale. Invisible sur une ligne au repos (son texte a
une largeur intrinsèque), **fatal sur la ligne en ÉDITION** : son `TextField` focalisé délègue son
rendu au field editor d'AppKit, dont la largeur idéale est nulle — le titre disparaît purement et
simplement, carte ouverte et vide. D'où la largeur EXPLICITE
(`.frame(width: geo.size.width - 2 * gutter)`) et non un `maxWidth: .infinity`, qui ne résout rien
quand la proposition entrante est déjà indéterminée. Re-mesuré après correction : le gain du
glissement tient (7 %).

**Le même oubli a été repayé sur les deux pages intelligentes** (7 août 2026) : « Aujourd'hui » et
« Tâches » rendaient leur pile dans un `ScrollView` sans la borner, et le titre d'une tâche en
édition s'y effondrait exactement pareil — jamais sur une page de liste, qui avait déjà le
correctif. Les deux portent désormais le même `GeometryReader` + largeur explicite. Les
`.frame(maxWidth: .infinity)` plus bas dans l'arbre (sections, lignes) restent tels quels : une fois
la RACINE bornée à une largeur concrète, ils la relaient sans avoir à la recalculer.

Corollaire pour la suite : le jour où une liste se comptera en centaines de lignes, la réponse ne
sera toujours pas `LazyVStack` — ce sera de borner ce qu'on rend, ou de ne plus déplacer les rangées
elles-mêmes.

### `VStack` distribue la hauteur restante à ses enfants FLEXIBLES

Une forme (`RoundedRectangle`, `Circle`, `Capsule`) est flexible dans les deux dimensions : posée en
FRÈRE dans un `ZStack`, elle fait gonfler sa rangée jusqu'à avaler la page. Une décoration se pose
en `.background` / `.overlay` de ce qu'elle habille — elle en reçoit alors la taille.

### Sur « Tâches », chaque section est sa PROPRE zone de glissement

La séquence donnée au moteur est `section.tasks`, jamais les lignes de la page (cf.
`AllTasksPageView.rowsView`).

Le glisser traversant a existé, avec toute une machinerie pour deviner la section d'accueil
(`SectionBandKey`, `AllTasksPage.emptySection(at:bands:)`, `measureSectionBand` — **tous
supprimés**, ne pas les chercher). Il a été retiré le 6 août 2026 pour deux défauts que cette
machinerie ne pouvait pas corriger, parce qu'ils venaient d'ailleurs : le moteur raisonnait sur une
liste PLATE, alors que les titres de section occupent de la hauteur à l'écran. Plus on traversait de
titres, plus l'écart se creusait entre la ligne dessinée et le trou qui s'ouvre — le « flou »
constaté à l'usage. Et un titre n'étant pas une ligne, lâcher dessus faisait lire la tâche du
DESSUS : on atterrissait dans la section précédente.

Bornée à sa section, la séquence est homogène et contiguë : plus de trou d'air, et les deux bouts du
dépliant deviennent des butées naturelles.

**Ne pas rétablir le glisser entre sections**, et surtout pas pour faire s'ouvrir une section repliée
au survol (la demande est venue, elle a été écartée le 6 août). Ce serait réinstaller les deux
défauts ci-dessus sur le morceau le plus fragile de l'app, pour une cible qui DÉFILE — viser une
section 800 px plus bas n'est pas plus rapide qu'un clic droit. Le déplacement entre sections passe
par le menu ▸ _Déplacer vers…_ et le sélecteur _Quand…_, qui disent explicitement ce que le glisser
devait deviner.

**Le déplier-au-survol de la SIDEBAR, lui, est voulu et il reste** : survoler une ligne de projet
pendant un glissement la déplie pour révéler ses listes. Ce n'est PAS le rétablissement de ce qui a
été rejeté, et la nuance est toute la différence : ici rien n'est calculé au survol — pas de trou à
ouvrir, pas d'ordre à deviner, la sidebar ne fait que montrer des cibles qu'elle avait cachées. Sur
« Tâches », déplier changeait la géométrie DU CALCUL en cours.

---

### Un `TextField` focalisé DANS la transaction qui change sa largeur fige sa hauteur à 0

(7 août 2026, cadre loggé sur une tâche dont le titre portait un badge de durée.) Ouvrir l'édition
d'une `TaskRow` fait deux choses dans la MÊME transaction : poser `isEditing`, et retirer les badges
(date, durée, provenance) de la `HStack` du titre. Le champ reçoit donc une largeur plus grande dans
cette transaction-là. Focalisé au même instant, `TextField(axis: .vertical)` fige sa hauteur à 0 dès
la première image — avant même que le focus n'arrive — et n'en ressort JAMAIS, parce que le field
editor d'AppKit prend ensuite le relais sur ce cadre déjà cassé.

Le correctif est un décalage d'UN tick (`DispatchQueue.main.async`, gardé par un jeton de session) :
un premier passage NON focalisé, à la largeur déjà stable, mesure la bonne hauteur — le rendu
SwiftUI natif d'un `TextField` non focalisé sait le faire — et le focus, arrivant un tick plus tard,
hérite d'un cadre correct au lieu d'en recalculer un.

Ce focus décalé va dans `taskFlow`, pas hors transaction : posé nu, le petit réajustement que fait
le field editor en prenant le relais (quelques points) sautait sans s'animer. Imperceptible sur un
titre seul, visible en à-coup sur une carte haute.

### Une page de tâches a DEUX colonnes, et cinq endroits l'ont oublié

`taskContentColumn` (les repères de section : bandeau de page, encadré toujours affiché, pilule
d'en-tête, libellé d'un dépliant, en-tête de jour) et `taskRowColumn` (le contenu d'une ligne : case
à cocher, ＋ de création, encadré d'un événement), séparées d'un `rowInset`. Le décrochement entre
les deux est ce qui donne la hiérarchie — une case se cale sur le TEXTE d'une en-tête, pas sur le
bord de sa pilule.

Se caler sur `rowInset` nu, ou sur une valeur recalculée à la main, a désaligné cinq endroits, l'un
après l'autre : `EventRow`, le dépliant « archivées », son `NotesBox`, la grille de cartes d'un
projet, et la pilule d'en-tête. Cinq fois le même oubli, cinq corrections séparées — d'où les deux
constantes nommées et la règle posée à leur définition (`TaskPageChrome`).

**Le critère n'est pas « est-ce un encadré ? », c'est « est-ce que ça COIFFE des lignes, ou est-ce
que c'en est une ? »** `EventRow` a d'abord été rangé sur `taskContentColumn` parce qu'il est
encadré, comme `NotesBox` — mais un événement est le contenu d'une journée, pas son titre : posé
là, il se lisait au même niveau que la section qui le coiffe et la hiérarchie disparaissait. Il est
passé sur `taskRowColumn` (11 août 2026), avec la case d'un rappel, qui traînait encore à `rowInset`
nu.

« À venir » n'avait, elle, jamais eu ce passage : dans une même journée, la case d'une tâche était à
0, celle d'un rappel à 10 et l'encadré d'un événement à 20. Trois retraits pour trois sortes de
lignes qui se suivent. Corrigé en même temps — sans quoi « aligner les événements sur les cases » n'y
voulait rien dire.

Seule exception assumée : la carte d'édition d'une `TaskRow`, qui déborde délibérément à gauche pour
s'ouvrir autour d'un contenu qui, lui, ne bouge pas au clic.

---

## Animations et dépliants

### Tout dépliant s'anime avec `disclosureFlow`

Un chevron qui tourne et un contenu qui apparaît, c'est le MÊME geste partout : repli d'un projet
dans la sidebar, section d'« Aujourd'hui » ou de « Tâches », archives d'une liste, sous-tâches d'une
ligne. Quatre valeurs avaient divergé (`.snappy(0.2)`, `.snappy(0.22)`, `.easeInOut(0.2)`, le défaut
de `DisclosureGroup`) — assez pour que le même clic ne se sente pas pareil d'un onglet à l'autre.

La courbe enveloppe TOUJOURS la MUTATION, pas le rendu : `withAnimation(disclosureFlow) { … }`
autour de l'écriture de l'état (`isCollapsed.toggle()`, `toggled.insert/remove`,
`undatedExpanded = …`), jamais un `.animation(value:)` posé sur la vue. Un `DisclosureGroup` change
son binding depuis son propre bouton AppKit, hors de notre code : un `.animation(value:)` à côté
n'attrape pas cette transaction-là — testé, résultat instantané et saccadé. Passer par un `Binding`
maison dont le `set` fait le `withAnimation` (cf. `TodayPageView.undatedExpansion`,
`AllTasksPageView.expansion(of:)`).

### Le contenu fond en s'ouvrant, et toujours EXPLICITEMENT

Jamais laissé au défaut implicite de SwiftUI (un ancêtre qui pose un jour `.transition(.identity)`
l'éteindrait sans qu'on le voie). Deux cas, selon si le contenu est démonté ou pas :

- **retrait/insertion réel** (`if isOpen { rows }`, comme la sidebar ou les archives d'une liste) →
  `.transition(.opacity)` sur ce bloc (au besoin `Group { … }` s'il contient plusieurs vues) ;
- **`DisclosureGroup`** — son contenu reste MONTÉ, replié par hauteur seulement, un `.transition` n'y
  change donc rien → `.opacity(isOpen ? 1 : 0)` sur le contenu, qui suit la même transaction que le
  `withAnimation` du binding puisqu'il lit le même booléen.

### Les sections de « Tâches » ne sont plus des `DisclosureGroup`

(6 août 2026.) Un `DisclosureGroup` rogne son contenu à son propre cadre, et la ligne qu'on tire en
sortait — elle se faisait couper net en pleine course. Remplacés par un dépliant fait main (bouton +
`if open { rows }`), qui ne rogne rien. Bénéfice au passage : le contenu est vraiment RETIRÉ quand
la section est repliée, au lieu d'être seulement replié en hauteur — une section fermée ne coûte
donc plus rien à rendre. Le binding maison (`AllTasksPageView.expansion(of:)`) reste, lui : c'est ce
qui met la mutation dans la transaction animée, quel que soit le dépliant.

### L'état du dépliant n'est JAMAIS un `@AppStorage`

Même s'il doit survivre au relancement. Mesuré : un dépliant piloté par `@AppStorage` reste
totalement instantané sous `withAnimation` — son écriture passe par `UserDefaults`, hors du
mécanisme d'observation que SwiftUI sait capturer dans une transaction animée. C'était le bug de
« Tâches sans date » (Aujourd'hui), invisible tant que personne ne comparait à un dépliant voisin.
Un `@State` ordinaire, avec la persistance écrite à la main À CÔTÉ de la mutation animée, donne le
même résultat SANS ce piège. Deux formes en service : un `Binding` maison dont le `set` fait le
`withAnimation` (`AllTasksPageView.calendarExpansion`, `expansion(of:)`), et — quand l'état doit
survivre au relancement — un `@State` qui pilote le rendu doublé d'un enregistrement écrit juste
après lui (`TaskRow` + `SubtaskExpansion`, pour le repli des sous-tâches).

---

## L'anneau de progression

### Trois versions de la même règle, dont deux fausses

`TodoList.progress` (et son jumeau `Project.progress`) a été réécrit trois fois. Les deux premières
sont instructives, parce qu'elles échouent de façons opposées.

**La première mesurait le flux VISIBLE** : une tâche sortie de la page ne comptait ni au numérateur
ni au dénominateur, pour qu'une liste au long cours n'affiche pas un disque quasi plein devant une
page où rien n'est fait. Retirée — vu d'un anneau il n'y a AUCUNE page, et la règle retombait alors
sur `CompletedTaskRetention`, dont le mode « 1,5 s » faisait sortir toute tâche cochée une seconde
et demie après le clic. Mesuré : 2 faites sur 4 → 0,0. L'anneau montait puis retombait à zéro tout
seul, partout. Une jauge qui ne retient rien ne mesure rien.

**La deuxième ignorait donc l'âge d'une coche** : une tâche complétée compte pour toujours. Juste
pour une liste qu'on termine une fois ; faux pour une liste au long cours jamais terminée (« Bugs &
fix ») — chaque tâche archivée reste au dénominateur, l'anneau plafonne près du plein, et une tâche
neuve ne le fait quasiment plus bouger.

**La troisième ancre l'exclusion sur le JOUR CALENDAIRE** (`TaskItem.countsTowardProgress`) et non
sur `CompletedTaskRetention` : la borne ne bouge qu'une fois par jour, à minuit — jamais en cours de
journée comme le mode « 1,5 s », donc jamais le clignotement qui avait tué la première version. Une
tâche cochée aujourd'hui compte encore ; une tâche archivée avant aujourd'hui ne compte plus dans
AUCUN des deux termes, comme si elle n'avait jamais existé — exactement ce que fait déjà une liste
neuve. Le réglage `progressRingResetsDaily` (Réglages ▸ Tâches) redonne la deuxième à qui la
préfère.

`completedAt` manquant (donnée d'avant l'ajout du champ) compte comme « pas encore archivée » : on
ne sait pas trancher, donc on ne masque pas une progression qu'on ne peut pas dater.

### Le réglage se lit UNE fois par passe, pas une fois par tâche

`countsTowardProgress` est appelé par tâche (`SidebarCounts`, `TodoList.progress`,
`Project.progress`). Il lisait `UserDefaults` à chaque appel. Mesuré : 0,665 ms pour 2 000 lectures,
soit le coût d'un `SidebarCounts` entier à cette taille. Le drapeau vit donc dans `DayBounds`, avec
les autres valeurs calculées une fois par filtrage — et il devient injectable, ce qui sort les tests
des défauts utilisateur.

---

## Build et outillage

### Le minimum macOS n'est pas vérifié par le build

`Package.swift` déclare `.macOS(.v14)` mais `swift build` compile pour l'hôte. Une API
`@available(macOS 15+)` compile sans broncher et casserait sur une vraie cible 14. À vérifier à
l'œil.

### `swift build` qui passe ne veut pas dire que ça marche

L'essentiel des bugs ici sont des bugs de layout et d'interaction, invisibles au compilateur. Un
changement d'UI se vérifie en lançant `./run-dev.sh` et en regardant — **dans les deux thèmes** : les
régressions de mode sombre sont la rechute la plus fréquente du projet.

### Un `swift build` incrémental ne montre pas les warnings des fichiers qu'il ne recompile pas

Un build à 0,2 s n'a rien vérifié du reste du module. Mesuré : **0 avertissement** quand il n'y a
rien à refaire, **40** après un `touch` de tout. D'où
`find Sources Tests -name '*.swift' -exec touch {} +` puis `swift build && swift test` — et
`-c release`, qui compile en module entier et sort des diagnostics que le debug tait.

`make-app.sh` applique ce constat plutôt que de le laisser à la mémoire de chacun : il résume les
avertissements connus en UNE ligne, **s'arrête net** sur tout ce qui n'est pas un chemin de clé
(échappatoire `ALLOW_NEW_WARNINGS=1`), et **refuse de conclure** quand rien n'a été recompilé — un ✓
dans ce cas-là serait exactement le mensonge que le contrôle doit empêcher. `release.sh` pose
`FULL_WARNING_CHECK=1`.

### `cp -r` DÉTRUIT un framework versionné

Sparkle n'est qu'une arborescence de liens symboliques (`Sparkle` → `Versions/Current/Sparkle`) ;
`cp -r` les SUIT et copie les cibles — mesuré : 3,0 Mo deviennent 8,9 Mo, chaque binaire en double,
et le bundle n'a plus la forme d'un framework. Conséquence : `codesign --verify --deep --strict`
sort en erreur (« bundle format is ambiguous »), or c'est ce sceau que Sparkle compare entre l'app
installée et celle qu'il télécharge avant d'installer une mise à jour. `ditto` partout où l'on copie
un bundle (cf. `make-app.sh`).

---

## Déjà essayé et REJETÉ — ne pas refaire

Chacune de ces approches a été écrite, essayée, et retirée. Deux l'ont été DEUX fois, par oubli.

### YouTube comme source de la musique du pomodoro

(8 août 2026.) La seule voie sanctionnée est une `WKWebView` + l'API IFrame, et une WebView demande
une FENÊTRE — or on joue justement quand la fenêtre de Today est fermée. Ordonner une fenêtre est la
famille de plantages non résolue de ce projet, et on n'a aucun `WKWebView` à nous aujourd'hui :
WebKit n'est là que traîné par Sparkle. S'ajoute que le lecteur caché est contraire aux conditions
de YouTube, ce qui compte pour une app destinée à être vendue. Retenu à la place : AppleScript vers
Spotify ou Musique.

**Repris et re-rejeté le 9 août 2026, cette fois avec des CHIFFRES** — la question posée était
« l'impact est-il réel ou insignifiant ? », et l'intuition disait insignifiant. Banc jetable :
`WKWebView` 256×144 hors écran, lecteur IFrame, lecture VÉRIFIÉE (`state-1`, `t=51 s` — sans cette
preuve on mesure une page morte et on conclut « insignifiant »). Mesuré au `ps` sur 30–40 s :

|                            | process | RSS    | CPU       |
| -------------------------- | ------- | ------ | --------- |
| app nue, sans WebView      | 1       | 59 Mo  | 0 %       |
| la même + YouTube qui joue | 6       | 423 Mo | 5,7–7,5 % |

Soit **+330 Mo et ~6 % de CPU en continu** (`WebContent` 220, `GPU` 45, `Networking` 31,
`MTLCompilerService` 22, `audio.SandboxHelper` 11) pendant les 25 minutes de chaque pomodoro, pour
1,7× la mémoire de Today entière (198 Mo mesurés). **Et ce coût n'est PAS déjà payé** par le WebKit
que traîne Sparkle : Today lance bien un helper `SafariPlatformSupport` (28 Mo), mais AUCUN
`WebContent` — les process de contenu n'apparaissent qu'avec une `WKWebView`.

Trois faits mesurés qui tuent le « on l'optimisera au maximum » :

1. **la définition ne se choisit pas.** `vq=tiny` dans les `playerVars` ET
   `setPlaybackQuality('tiny')` appelé deux fois : le lecteur rend `medium` quand même (l'API est
   dépréciée, YouTube décide). Donc pas d'audio seul — la vidéo se décode, et c'est elle qui allume
   le process GPU à ~3 % ;
2. **beaucoup de vidéos refusent l'intégration** : `error 150` sur le flux lofi de Lofi Girl, soit
   exactement la musique de pomodoro type. Et `error 152` tant que la page hôte n'a pas d'origine
   HTTP valide, ce qui obligerait à un serveur local DANS l'app ;
3. **la fenêtre reste obligatoire** : il faut `orderFrontRegardless()` pour que ça joue.

### L'API web de Spotify pour lister les playlists de l'utilisateur

(8 août 2026.) Son dictionnaire AppleScript n'expose que `application` et `track` — aucun accès à la
bibliothèque, rien à contourner. L'API web le ferait, au prix d'un compte développeur, d'OAuth PKCE,
du Trousseau, et d'un plafond à **25 utilisateurs** tant qu'une extension de quota n'est pas accordée
par Spotify. Écarté pour épargner un collage qu'on fait une fois. Retenu à la place : l'endpoint
`oembed` PUBLIC, sans authentification, qui rend le NOM d'une playlist depuis son lien — de quoi
nommer l'entrée toute seule et dire « lien non reconnu ». Musique, lui, expose bien `user playlist` :
là, le menu déroulant existe.

### Un fond transparent pour attraper le clic dans le vide

`.background { Color.clear … onTapGesture }` : un `ScrollView` capte les clics de toute sa surface,
et un fond de contenu ne couvre de toute façon ni les marges (`gutter`) ni le vide sous la dernière
ligne. La seule réponse qui marche est celle du socle : moniteur `NSEvent` + cadres des lignes.

### Faire publier aux lignes leur identité par `PreferenceKey` pour en dériver l'ordre du clavier

Faux sur `ListPageView`, qui était en `LazyVStack` : les rangées hors écran ne sont pas construites
et ne publient rien, donc l'ordre s'arrête au viewport. Une préférence mesure ce qui est RENDU ;
l'ordre du clavier est ce qui est AFFICHÉ — d'où `TaskPageBlock`, qui est une valeur, pas une mesure.
Les cadres, eux, restent bien du ressort d'une préférence : ils ne concernent que le visible, c'est
leur définition.

### `LazyVStack` sur une page qui se RÉORDONNE au doigt

Cf. § Layout ci-dessus : mesuré 100 % de fil principal contre 9 %.

### Faire taire les diagnostics de chemins de clé en marquant les `@Model` `@unchecked Sendable`

Ce serait un mensonge (ce sont des classes mutables) et le rafistolage que le projet refuse. Trou
entre SwiftData et Swift 6, à laisser tel quel.

### Le popover pour choisir une couleur (en-tête de section, projet)

Écrit d'abord, et il TUE l'app : une fenêtre présentée depuis le layout, cf. § Fenêtres. Remplacé
par une révélation dans la fenêtre — la palette s'ouvre dans la pilule de l'en-tête, sous la rangée
du projet. Le sous-menu, lui, avait déjà été rejeté avant (un menu contextuel macOS ne dessine pas
les images de ses items : sept lignes de texte identiques à lire une par une).

### Le curseur « main » sur toute la ligne

Sur macOS, la main signale un bouton ou un lien, jamais une ligne sélectionnable (Finder, Mail,
Rappels gardent la flèche). Le comportement actuel — main sur la case à cocher seulement — est
correct. Si un repère de survol manque, la bonne réponse est un fond de survol, pas un changement de
curseur.

### Le glisser d'une section à l'autre sur « Tâches », et « la section repliée s'ouvre au survol »

Écrit, mesuré, retiré le 6 août 2026. Détail et les deux défauts : § Layout ci-dessus.

### Les trois faux-semblants retirés le 2 août 2026

Du code en pause ment sur ce que l'app sait faire, et se paie deux fois — une fois en le maintenant,
une fois en le débranchant. D'où : _une fonctionnalité est branchée ou elle n'existe pas._

- l'**icône tag**, décorative faute de modèle qui porte des tags → retirée ;
- **`TaskItem.hasTime`**, jamais mis à vrai par aucun chemin (l'app ne posait que des JOURS), ce qui
  rendait l'affichage d'heure d'« À venir » inatteignable → retiré du schéma. Revenu le 5 août 2026
  sous la forme de `TaskItem.whenMinutes` (schéma 5.0.0) — AVEC son sélecteur (`WhenPicker`), comme
  la règle l'exigeait : le jour reste dans `when`, l'heure vit à côté ;
- la **barre de capacité** d'« Aujourd'hui », écrite, testée et masquée — avec son réglage « Fin de
  journée » resté VISIBLE dans les Réglages, où il ne pilotait plus rien → supprimée, avec
  `DayCapacity`. `Estimate` (la durée d'une tâche) reste : elle sert ailleurs.

---

## Ce que ce fichier a raconté FAUX

Chacune de ces affirmations a été écrite ici, crue, et démentie par une mesure. Elles ont coûté une
fausse piste chacune.

- « Un ajout de propriété est absorbé tout seul par SwiftData » → non, il faut monter le numéro de
  version (§ SwiftData).
- « C'est la profondeur de la cascade qui fait tomber l'assertion d'undo » → non, c'est l'absence
  d'instantané (§ SwiftData).
- « `_CFBundleGetValueForInfoKey` dans la pile prouve que l'`Info.plist` était réécrit » → non, c'est
  une résolution de symbole approximative (§ Fenêtres).
- « C'est le `NSMenu` qui se ferme derrière qui casse le popover » → non, 12 fois sur 12 sans
  incident (§ Fenêtres).
- « La page d'un projet permet de glisser des tâches » → non, c'est un tableau de cartes, il n'y a
  aucune ligne de tâche à y glisser.
- « C'est Sparkle qui traîne WebKit, donc la vue hors-process qui plante » → non : compilée sans
  Sparkle, l'app charge quand même toute la pile WebKit. La cause était `prewarmRichTextEditing()`
  (§ Fenêtres). Cette section-ci l'avait même écrit « Réfuté » — en mesurant le lancement du helper
  au lieu du PLANTAGE. **Mesurer la mauvaise grandeur innocente le vrai coupable.**

Un commentaire devenu faux se corrige DANS le même commit que la mesure qui le dément.
