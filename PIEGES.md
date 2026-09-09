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
(`WhenPicker`, la date d'une liste) sont sous la même menace ; celui de `TaskRow`
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
le premier répondeur texte. **Ça ne rend pas les popovers sûrs** — `WhenPicker`, la date d'une liste
et la feuille `SchedulePlannerView` (qui, elle, a encore un champ Titre ET deux
champs d'heure) restent des fenêtres présentées depuis le layout. Le correctif de fond reste le même
qu'ailleurs : se révéler DANS la fenêtre.

### Une fenêtre fermée reste ABONNÉE, et elle consomme ce qui était pour sa remplaçante

⌘↩ dans la capsule ouvrait l'app sur « Aujourd'hui » au lieu de la liste visée — mais SEULEMENT
quand la fenêtre principale avait été fermée au bouton rouge. Tracé le 13 août 2026 : la sélection
partait bien, elle était bien appliquée, et elle l'était **deux fois**.

```
applyPendingSelection applied -> list(Marketing)   ← la ContentView SORTANTE, fenêtre déjà fermée
applyPendingSelection pending=nil                  ← la NEUVE, 158 ms plus tard : plus rien
```

`AppCommand.activate` recrée la fenêtre (`NSWorkspace.openApplication`) quand il n'y en a plus ;
c'est asynchrone, donc la notification postée juste après ne pouvait viser que l'ancienne — qui
n'est PAS encore démontée et écrit la sélection dans un `@State` que plus personne ne rendra. La
neuve démarre alors sur sa valeur par défaut.

D'où, premier temps : la notification n'est postée QUE si `activate` a trouvé une fenêtre vivante.
Sinon la destination reste posée dans `pendingSelection` et c'est l'`onAppear` de la `ContentView`
neuve qui la lit.

**Ça n'a corrigé que la moitié.** Une fois la fenêtre rouverte, le geste marchait une fois puis plus
jamais : la deuxième destination ramenait l'app sur la page ouverte par la PREMIÈRE. La même trace,
instances numérotées, le dit sans détour :

```
[25A9] onDisappear                   ← la 1re ContentView quitte l'écran, mais reste abonnée
[EEF5] onAppear                      ← la 2e affiche la destination demandée
=== 2e destination ===
[25A9] reçoit … CONSOMME             ← la MORTE est servie EN PREMIER et prend tout
[EEF5] onScreen=true, pending=nil    ← la vivante n'a plus rien
```

`NotificationCenter` sert dans l'ordre d'INSCRIPTION : la plus ancienne gagne toujours, et elle est
justement celle qu'on ne voit pas. Un jeton à consommer une fois, diffusé à N abonnés, va au
mauvais — par construction, pas par malchance.

D'où, second temps : **la destination VOYAGE avec la notification** (`object:`), et chaque
`ContentView` l'applique à son propre `selection`. Les invisibles écrivent dans le vide, celle à
l'écran montre la bonne page. `pendingSelection` ne sert plus QU'au cas « aucune fenêtre » — là où
il n'y a, par définition, personne pour se la disputer.

**La leçon, plus large que ce bug :** une vue dont la fenêtre est fermée n'est pas une vue morte.
Un état « à consommer une fois » ne se diffuse pas ; ou bien on l'adresse, ou bien on transporte la
valeur et chacun s'en sert.

### L'autosave de cadre d'AppKit fait DÉRIVER la capsule

`setFrameAutosaveName` enregistrait le cadre de la capsule avec la configuration d'écrans du moment
(`"1076 228 770 620 0 0 2056 1290"`) et remettait la fenêtre « à l'échelle » dès que cette
configuration changeait. Sur deux écrans branchés et débranchés au fil des jours, la barre finissait
n'importe où — d'où « une position totalement aléatoire », le 22 août 2026.

Remplacé par une position à nous (`quickEntry.barCenter`), en **fractions de la zone utile de
l'écran** — 0,5 / 0,5 tant qu'on ne l'a pas déplacée. Une fraction et pas des points : la capsule doit
paraître sur l'écran où l'on TRAVAILLE, et deux écrans n'ont ni la même taille ni la même origine.
Relue à chaque ouverture, bornée pour que la barre tienne en entier dans l'écran visé.

Trois choses à ne pas confondre :

- **On centre la BARRE, pas la fenêtre.** Le panneau fait 620pt de haut pour loger les résultats, la
  barre en occupe ~56 tout en haut : centrer le cadre poserait la barre très au-dessus du milieu.
- **L'écran actif, c'est celui de la FENÊTRE AU PREMIER PLAN — pas celui de la souris.** La capsule
  s'ouvre au clavier depuis n'importe quelle app ; le pointeur, lui, peut être resté sur l'autre
  écran. Vérifié le 22 août 2026 : souris sur le 5K, Warp au premier plan sur l'écran interne — la
  capsule paraît sur l'interne. `CGWindowListCopyWindowInfo` suffit (`layer 0`, l'avant de la liste)
  et ne demande AUCUNE autorisation, là où l'API d'accessibilité en réclamerait une. Mesuré 0,52 ms
  en moyenne sur 14 fenêtres, une fois par ouverture. La souris ne sert que de repli.
- **`NSScreen.main` est faux ici** : sur une app qui n'est pas au premier plan, « principal » suit la
  fenêtre clé, qui appartient à une AUTRE app.

### `isMovableByWindowBackground` ne déplace pas une fenêtre remplie de SwiftUI

AppKit ne consulte ce réglage que sur la vue que le test de survol lui rend, et seulement si elle
laisse passer le clic. Tout le contenu de la capsule est du SwiftUI qui le consomme : le glissement
ne prenait que sur la marge transparente autour du verre — invisible, donc introuvable — et rien
n'enregistrait ce qu'il posait. D'où « quand je tente de la drag, il ne se passe rien ».

La barre s'attrape maintenant explicitement (`QuickEntryView.windowDrag`), comme une barre de titre.
Deux points qui ont l'air d'un détail et n'en sont pas :

- **Les deltas viennent de `NSEvent.mouseLocation`, pas de la translation du geste.** La fenêtre bouge
  SOUS le curseur : une translation mesurée dans la vue se réinjecte dans elle-même à chaque image et
  la capsule s'emballe. L'ancre (origine du panneau + pointeur) est prise au premier `onChanged`, et
  chaque image repart d'elle — aucune accumulation.
- **Parti du champ de texte, le glissement SÉLECTIONNE** : AppKit traite l'événement avant SwiftUI.
  C'est exactement ce que fait Spotlight ; on attrape la barre par ses bords.

Vérifié le 22 août 2026 avec un banc jetable (`CGWarpMouseCursorPosition` + `NSApp.postEvent`, aucune
autorisation d'accessibilité nécessaire) : le panneau se déplace, et la fraction écrite correspond au
centre de barre posé.

**L'aimant de ⌘** colle chaque axe au centre de l'écran quand la barre en passe à moins de 60pt, les
deux INDÉPENDAMMENT — c'est ce qui en fait une aide au placement et pas un bouton « au centre ».
L'état de la touche se lit sur `NSEvent.modifierFlags`, l'état COURANT du clavier : on peut la
prendre et la lâcher en plein glissement. `DragGesture().modifiers(.command)` ne convenait pas — il
faudrait DEUX gestes, et basculer de l'un à l'autre au milieu d'un glissement ne marche pas.

**Toute cette arithmétique est sortie dans `Models/QuickEntryPlacement.swift`** (`QuickEntryPlacementTests`,
12 cas). Elle faisait cinq calculs de rectangles mêlés à `NSPanel` et `NSScreen`, vérifiables
seulement à l'œil, alors qu'une erreur de signe entre le repère de Cocoa et le décalage de la fenêtre
au-dessus de sa barre s'y voit très mal. Le test le plus utile est celui de l'écran secondaire, à
coordonnées négatives : il fige le couple mesuré en vrai (zone utile `(-479, 1329, 2560, 1410)` →
centre de barre `(801, 2034)`).

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

### Une fenêtre au niveau `.screenSaver` est INVISIBLE à `screencapture`

L'écran plein de fin d'étape du Pomodoro (`PomodoroAlertWindow`) a d'abord été posé au niveau
`.screenSaver`, pour couvrir la barre de menus. Résultat : quatre captures d'écran de suite ne
montraient RIEN, sur les deux écrans, alors que la fenêtre était bien là — tracé depuis le process,
`visible=true key=true alpha=1.0 occlusion=.visible`, au cadre exact de l'écran. Au-delà du niveau
bouclier, le serveur de fenêtres sort la fenêtre des captures, exactement comme il le fait de
l'économiseur d'écran et de la fenêtre d'ouverture de session.

`.statusBar` (25) suffit : il passe déjà au-dessus de la barre de menus (`.mainMenu`, 24) et du Dock,
et c'est le niveau que la pastille utilise depuis toujours. Une fenêtre qu'on ne peut pas capturer
est une fenêtre qu'on ne peut pas vérifier.

**Corollaire de méthode** : quand une capture est vide, tracer l'état de la fenêtre AVANT de
soupçonner le contenu. Le grand rectangle flou au milieu du premier rendu correct n'était pas non
plus un défaut — c'était la fenêtre principale de Today, derrière, vue à travers le flou.

### Le fondu d'entrée d'une fenêtre : ni `alphaValue`, ni le calque d'un `NSVisualEffectView`

Deux façons de faire paraître cet écran en fondu n'ont RIEN joué — l'écran apparaissait d'un coup :

1. `panel.animator().alphaValue = 1` posé dans le même tour de boucle que `makeKeyAndOrderFront` ;
2. une `CABasicAnimation` d'opacité ajoutée au calque du `NSVisualEffectView` lui-même : il gère son
   propre arbre de calques et l'écrase.

Mesuré en échantillonnant `layer.presentation()?.opacity` toutes les 60 ms depuis le process : `1.00`
dès le premier échantillon dans les deux cas. La façon qui marche est celle de la capsule — un
conteneur NEUTRE (`NSView` + `wantsLayer`) qui porte le flou ET le contenu, et dont on anime
l'opacité : `0.20 0.41 0.59 0.74 0.87 0.96 1.00`, et le flou fond avec.

**La sonde vaut mieux que la capture** : `screencapture` prend ~250 ms, il rate un fondu de 450 ms
une fois sur deux. Échantillonner le calque depuis le process dit en une ligne si l'animation joue.

### Le journal système ne remonte rien de ce process

`log show --predicate 'process == "Today"'` rend 0 ligne, y compris pour un `NSLog` que le binaire
exécute vraiment. Tracer un geste passe par un fichier plat — l'app n'a aucun entitlement de
sandbox, `/tmp` lui est ouvert. Pour un `print`, poser `setvbuf(stdout, nil, _IONBF, 0)` : sinon la
sortie reste dans le tampon et on croit que rien ne s'exécute.

---

## Barre de menus et valeurs focalisées

### Deux pages qui publient le MÊME `id` : la PREMIÈRE garde le raccourci

⌘N ne faisait rien de visible — sur « Aujourd'hui », sur une liste, dans un projet — et les tâches
créées s'entassaient dans « Tâches ». Signalé le 9 septembre 2026. Le ⊕ de la barre du bas, lui,
marchait : c'est la MÊME fermeture, appelée directement. Le défaut n'était donc pas dans la
création, il était dans le chemin du MENU.

Sonde sur `MainMenuCommands.inMainWindow` et sur les trois `createTaskInEditMode`. ⌘N sur
« Aujourd'hui », navigation vers « Tâches », ⌘N :

```
MENU fired id=newTask → RUN TodayPageView.createTaskInEditMode   ← « Aujourd'hui », normal
SELECTION -> smartList(all)
MOUNT taskPageBase newTask=true      ← « Tâches » publie la SIENNE…
UNMOUNT taskPageBase                 ← …et « Aujourd'hui » se démonte APRÈS
MENU fired id=newTask → RUN TodayPageView.createTaskInEditMode   ← « Tâches », fermeture d'AVANT
```

Dès que la valeur publiée est optionnelle — c'est notre cas — `focusedSceneValue` prend l'overload
`Equatable` (macOS 14), et celui-ci **n'écrit rien quand la nouvelle valeur est égale à l'ancienne**.
`MenuAction ==` ne compare que l'`id`, et les cinq pages publiaient `"newTask"` : la fermeture de la
première page montée restait en place pour toute la session. ⌘N créait donc une tâche hors de la
page regardée — dans l'Inbox et sans date quand la fermeture figée était celle de « Tâches », ce qui
explique la pile de tâches vides qu'on y trouvait.

L'`id` n'était pas qu'une optimisation contre la réévaluation du menu : il est la seule chose que
SwiftUI regarde. D'où **un `id` qui nomme l'action ET sa cible** — `newTask.today`, `newTask.all`,
`newTask.<uuid de la liste>`. Deux raccourcis portaient le même défaut sans qu'on l'ait vu : ⌘⇧N
(en-tête) figé sur la première liste ouverte, ⌘⌥N (nouvelle liste) figé sur le premier projet visité
— `ListPageView` est RÉUTILISÉE d'une liste à l'autre, et `listTarget` change avec la sélection.

Ce qui n'est PAS en cause, vérifié dans la même passe : le démontage. Une page qui ne publie rien
(un projet) ou qui publie `nil` (« À venir », « Archives ») vide bien la valeur — l'item se grise et
⌘N n'atteint personne.

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

### Comparer deux côtés ne dit pas lequel a bougé

Un créneau déplacé dans Calendrier revenait à sa place en une seconde ; une durée rallongée était
rabotée. Le pont était bidirectionnel pour les COMPLÉTIONS et les SUPPRESSIONS, jamais pour les
dates : l'app imposait.

La cause n'est pas une comparaison ratée, c'est une question mal posée. « La tâche a changé » et
« l'événement a changé » produisent **exactement le même écart** entre les deux côtés. Avec deux
termes, il n'y a pas de réponse — seulement un vainqueur désigné d'avance, et c'était la tâche.

Il fallait un troisième terme : **ce que portait l'élément Apple la dernière fois que les deux
étaient d'accord** (`RemindersService.lastAgreed`, en mémoire seule). Un élément ne bouge pas tout
seul. S'il ne porte plus ce qu'on y avait laissé, c'est l'utilisateur qui l'a modifié chez Apple, et
il fait foi (`.pull`) ; s'il le porte encore, l'écart ne peut venir que d'ici (`.push`). C'est une
fusion à trois, pas une comparaison — la même forme qu'un `git merge`, et pour la même raison.

Trois pièges, chacun payé une fois pendant l'écriture :

- **Le lancement n'a pas de mémoire.** Sans elle, on retombe sur l'écart brut — et Apple fait foi,
  puisque l'app ne peut pas avoir modifié une tâche pendant qu'elle était fermée. Mais la tolérance
  de `needsEventPush` devient alors indispensable : une tâche SANS heure ne réclame qu'un jour, donc
  l'heure par défaut (9 h) posée sur son événement n'est pas un écart. La version qui comparait
  l'instant complet faisait adopter « 09:00 » à toutes les tâches datées au premier réveil.
- **Ce qu'on vient d'écrire EST le nouvel accord.** L'oublier fait lire l'écriture suivante comme un
  changement venu de Calendrier, et les deux côtés se renvoient la balle.
- **La requête bornée ne trouve pas ce qui est parti loin.** `linkedEventTimes` ne relit que les
  jours des tâches concernées (+2) ; un événement déplacé d'un mois en sortait, était lu comme
  absent, donc réécrit — c'est-à-dire ramené. D'où `eventTime(_:)`, une lecture à l'unité pour cette
  seule absence, et le résultat passé à `eventPresence(_:foundInWindow:)` qui payait déjà la même.

Ce qui n'a PAS changé : la suppression garde ses deux preuves, et un événement absent ne se
« reprend » jamais — il se recrée (identifiant périmé) ou se laisse mort. Reprendre une absence,
ce serait effacer la durée sur un hoquet iCloud.

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

### Sur une page à sections, chaque section est sa PROPRE zone de glissement

**Périmé depuis le 12 août 2026 — « Tâches » n'a plus de sections** (cf. « Ce que « Tâches » a cessé
de montrer », plus bas). La règle vaut toujours pour la page à sections que quelqu'un rajouterait :
la séquence donnée au moteur est celle d'UNE section, jamais les lignes de toute la page.

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
maison dont le `set` fait le `withAnimation`. (Plus aucun `DisclosureGroup` dans l'app depuis le
12 août 2026 : tous les dépliants sont faits main, et leur bouton appelle `withAnimation`
directement. La règle vaut pour celui qui en réintroduirait un.)

### Le contenu fond en s'ouvrant, et toujours EXPLICITEMENT

Jamais laissé au défaut implicite de SwiftUI (un ancêtre qui pose un jour `.transition(.identity)`
l'éteindrait sans qu'on le voie). Deux cas, selon si le contenu est démonté ou pas :

- **retrait/insertion réel** (`if isOpen { rows }`, comme la sidebar ou les archives d'une liste) →
  `.transition(.opacity)` sur ce bloc (au besoin `Group { … }` s'il contient plusieurs vues) ;
- **`DisclosureGroup`** — son contenu reste MONTÉ, replié par hauteur seulement, un `.transition` n'y
  change donc rien → `.opacity(isOpen ? 1 : 0)` sur le contenu, qui suit la même transaction que le
  `withAnimation` du binding puisqu'il lit le même booléen.

### Un dépliant qui contient une ligne GLISSABLE n'est pas un `DisclosureGroup`

(6 août 2026, sur les sections de « Tâches » — parties depuis, la leçon reste.) Un
`DisclosureGroup` rogne son contenu à son propre cadre, et la ligne qu'on tire en sortait : elle se
faisait couper net en pleine course. `.zIndex` n'y peut rien — il ordonne des voisines, il ne fait
pas sortir d'un cadre qui rogne. Remplacés par un dépliant fait main (bouton + `if open { rows }`),
qui ne rogne rien. Bénéfice au passage : le contenu est vraiment RETIRÉ quand la section est
repliée, au lieu d'être seulement replié en hauteur — une section fermée ne coûte donc plus rien à
rendre. Le motif est toujours en service dans `ListPageView.archiveSection`.

### L'état du dépliant n'est JAMAIS un `@AppStorage`

Même s'il doit survivre au relancement. Mesuré : un dépliant piloté par `@AppStorage` reste
totalement instantané sous `withAnimation` — son écriture passe par `UserDefaults`, hors du
mécanisme d'observation que SwiftUI sait capturer dans une transaction animée. C'était le bug de
« Tâches sans date » (Aujourd'hui), invisible tant que personne ne comparait à un dépliant voisin.
Un `@State` ordinaire, avec la persistance écrite à la main À CÔTÉ de la mutation animée, donne le
même résultat SANS ce piège. Deux formes en service : un `Binding` maison dont le `set` fait le
`withAnimation` (`TodayPageView.undatedExpansion`), et — quand l'état doit
survivre au relancement — un `@State` qui pilote le rendu doublé d'un enregistrement écrit juste
après lui (`TaskRow` + `SubtaskExpansion`, pour le repli des sous-tâches).

### L'entrée d'une FENÊTRE entière ne s'anime pas en SwiftUI

(22 août 2026, capsule de saisie rapide.) Elle s'ouvrait par un `.scaleEffect(appeared ? 1 : 0.88)`
sous `withAnimation` — la forme recommandée partout ailleurs dans ce fichier, et la bonne dès qu'il
s'agit d'un pan qui s'ouvre ou d'une rangée qui entre. Sur la capsule ENTIÈRE, elle coûtait la
fluidité.

Mesuré, en release, en alternant les variantes dans le MÊME process (entre deux lancements la
variance atteint ±12 ms, plus que l'effet cherché) :

| | CPU de l'app, par cycle ouverture + fermeture |
| --- | --- |
| tel quel | **543 ms** |
| sans le `.scaleEffect` | **259 ms** |
| sans les deux ombres de `paneShadow` | 516 ms |

Soit ~9 ms d'app par image sur un budget de 16,7 (8,3 sur un écran 120 Hz), auxquels s'ajoute le
serveur de rendu, mesuré à ~625 ms par cycle pour composer le verre. Dès qu'autre chose tourne —
une vidéo derrière la capsule, un build — on rate un vsync sur deux et l'ouverture tombe à 30 Hz.
Fenêtre au premier plan sur un fond statique, la même ouverture tient un 60 Hz propre : c'est ce qui
rend le défaut intermittent, donc difficile à croire.

La raison : une échelle animée oblige SwiftUI à RE-RENDRE tout le sous-arbre à chaque image (le
texte est retracé à chaque facteur, il ne peut pas être simplement transformé). Confiée à
CoreAnimation, la même échelle s'applique à une texture rendue UNE fois.

`.compositingGroup()` et `.drawingGroup()` ont été essayés d'abord, pour rester en SwiftUI :
614 → 578 et 528 ms/cycle, dans le bruit. Ils ne rachètent pas le rendu.

L'entrée et la sortie sont donc jouées par `QuickEntryWindow.animate(_:to:)` : une
`CASpringAnimation(perceptualDuration: 0.34, bounce: 0.38)` — les mêmes nombres que le ressort
SwiftUI remplacé, `bounce` valant `1 − dampingFraction` — sur le `transform` et l'`opacity` du
calque. **Résultat : 543 → 202 ms/cycle sur une manche, 102 sur une autre**, et **89** une fois le
reste du chantier du jour en place (cf. plus bas). L'écart entre les manches vient des conditions
(écran de rendu, second moniteur branché) et non du code ; le plancher, lui, est franc : l'app ne
fait plus rien pendant l'animation.

Vérifié à l'image près, les deux thèmes et les deux sens : la capsule grandit depuis son bord HAUT,
sans image parasite à taille pleine avant l'entrée, et la sortie est symétrique. 26 bascules
d'affilée sans plantage.

Ce qui NE change pas : tout ce qui bouge À L'INTÉRIEUR de la capsule (un pan qui s'ouvre, la
fournée qui grandit, la pastille de date) reste en SwiftUI, sous `withAnimation`. La frontière est
la FENÊTRE : ce qui la fait entrer ou sortir appartient au calque, ce qui remue dedans appartient à
SwiftUI.

Deux pièges rencontrés en le faisant :

- le pivot. Le `transform` d'un calque s'applique autour de son `anchorPoint`, et le déplacer fait
  bouger le calque (AppKit le repositionne ensuite). On encadre donc l'échelle de deux translations
  vers le haut de la capsule (`shrunk(in:)`) ;
- la sortie dure ~400 ms pendant lesquelles la fenêtre est ENCORE visible. Sans `isClosing`, le
  raccourci global frappé dans cet intervalle voyait une capsule « ouverte » et redemandait une
  fermeture déjà en cours — donc ne faisait rien. Un compteur de génération invalide le démontage
  différé quand une réouverture le double.

### Ce qu'une capsule paie AVANT de paraître

Même journée, même panneau. `panel.contentView = hosting` bloque le fil principal, et la fenêtre
n'est ordonnée à l'écran qu'après. Mesuré : **51 à 68 ms** pour l'ensemble de `show()`, contre
**1,4 ms** avec un contenu vide en témoin — tout vient donc de notre arbre de vues, pas d'AppKit.

Décomposé, toujours en alternant dans le même process :

| | coût |
| --- | --- |
| matérialisation des `@Query` (dont la table entière des tâches) | ~7 ms |
| copie INVISIBLE de `destinationList`, rendue pour mesurer une hauteur | ~8 ms (36,1 → 28,2) |
| Liquid Glass au premier rendu | ~0 ms (36,1 contre 35,0 — dans le bruit) |

Deux surprises. Le verre, qu'on soupçonnait, ne coûte rien à la construction (il coûte au serveur
de rendu, pas à l'app). Et une vue `.hidden()` coûte plein tarif : elle est rendue, elle n'est
qu'invisible. Celle-ci mesurait un bloc que rien ne pouvait ouvrir à ce moment-là — elle est
désormais bornée à l'étape où le chip de destination existe, ET à tant que la hauteur n'est pas
connue (une fois mesurée elle est en `@State` pour la session).

Le fetch complet d'une table, mesuré en release : **2,4 ms à 136 tâches, 8,7 à 500, 35 à 2 000.**
D'où le `@Query` de la capsule remplacé par un chargement à la première frappe : la capsule s'ouvre
sur une barre vide, qui n'a besoin d'aucune tâche.

#### Le plus gros était la copie VISIBLE, pas la cachée

Une fois la copie cachée bornée, il restait 28 ms. Dix-neuf d'entre eux venaient de la VRAIE liste
des destinations. Le bloc qui la contient est délibérément TOUJOURS monté — c'est ce qui donne la
fusion progressive du verre (cf. `destinationPane`) — et il est simplement replié à hauteur nulle.
Mais **une hauteur nulle ne dispense pas de construire le contenu** : les douze rangées étaient
bâties à chaque rendu de la capsule, chacune lisant `list.progress()`, qui retraverse les tâches de
sa liste.

Mesuré en alternance dans le même process : **27,6 ms contre 8,8** avec le contenu vidé. Le bloc
reste monté ; son CONTENU ne l'est que quand il sert (`showsDestinations`), avec le décalage à la
fermeture qu'utilise déjà `TaskRow.showEditor` — démonté d'un coup, le bloc se viderait sous les
yeux avant d'avoir fini de se replier.

**Total sur le chemin d'ouverture : `setContentView` passe de 36 à 9,6 ms de médiane.**

#### Et la même copie cachée faisait tourner le body sept fois par frappe

Diagnostic à la `Self._printChanges()` (lancé depuis le binaire du bundle, sortie capturée par un
fichier plat — `print` vers un fichier redirigé est bufferisé et perdu au `kill`).

La `GeometryReader` de la copie de mesure publiait sa préférence à chaque passe de layout, ce qui
réécrivait `destinationHeight`, ce qui réinvalidait le body, qui relayoutait. Chaque frappe dans la
barre déclenchait **sept à huit évaluations du body**, chacune reconstruisant toute la palette. En
bornant la copie, on tombe à **une** (deux sur la première frappe, le temps de charger les tâches).

D'où la garde `if $0 > 0` sur `onPreferenceChange` : zéro n'est pas une mesure, c'est le défaut de
la clé — celui que la copie publie en partant. Le retenir la ferait remonter aussitôt, et les deux
se relanceraient sans fin.

### Lire le minuteur dans un corps de vue l'abonne à la SECONDE

(23 août 2026.) La capsule propose « Reprendre : *phase* » quand un pomodoro attend. Le premier jet
construisait son instantané en lisant tout le minuteur — `phase`, `formattedRemaining`, `hasStarted`,
`isRunning` — puis laissait la palette décider. `PomodoroTimer` est `@Observable` : lire
`formattedRemaining`, c'est lire `remaining`, qui décroît d'une unité par seconde. Mesuré, capsule
ouverte et pomodoro en marche : **7 recalculs de palette en 6 secondes**, chacun parcourant toutes
les tâches, toutes les listes et tous les dossiers.

La correction ne coûte rien : sortir AVANT de lire le temps, quand ça tourne. Ce qui reste observé
est un booléen qui ne bouge qu'à l'arrêt — **0 recalcul en 6 secondes**, dans les deux états.

C'est le même piège que celui déjà payé sur `MenuBarTimerLabel`, où lire l'heure restante dans le
corps de la Scene invalidait l'arbre entier chaque seconde. La règle : **avec un `@Observable`, ce
n'est pas ce que la vue AFFICHE qui compte, c'est ce qu'elle LIT** — et l'ordre des lectures fait
partie du code.

### Une rangée qui relit cinq fois la même relation

(22 août 2026.) `TaskRow` lisait `task.subtasks` **cinq fois par rendu** : `orderedSubtasks` pour
savoir s'il y en a (donc un tri, pour un booléen), `isEmpty` pour décider du résumé, `count` puis
`filter` pour le remplir, `count` encore pour la courbe. Les pages se construisent EN ENTIER — pas
de `LazyVStack`, c'est acquis — donc chaque rangée payait à chaque rendu.

Mesuré en release :

| | 136 tâches | 2 000 |
| --- | --- | --- |
| cinq accès par rangée | 0,73 ms | 10,8 ms |
| une passe (`SubtaskTally`) | **0,18 ms** | **3,05 ms** |
| pour comparaison, une propriété STOCKÉE (`title`) | 0,07 ms | 1,0 ms |

Dix fois le prix d'une lecture mémoire. Le correctif est celui du projet — construire une fois,
distribuer — mais posé en tête du body de la RANGÉE plutôt que de la page : cinq accès deviennent
un, sans toucher à la signature de `TaskRow` ni aux cinq pages. Descendre à zéro demanderait à la
page de charger toutes les sous-tâches en une requête et de les grouper ; c'est un autre chantier,
et il n'a pas lieu d'être à cette taille de base.

### Le tableau d'un projet recomptait ce qu'il venait de compter

`ProjectBoard` existe précisément pour ne parcourir les tâches d'une liste qu'UNE fois par carte —
son en-tête le dit. Et `ListCardView` appelait quand même `card.list.progress()` pour son anneau,
soit un second parcours complet par carte, à chaque rendu de la page. L'anneau est désormais
calculé dans la même passe (`Card.progress`), avec la même règle que `TodoList.progress` et
`SidebarCounts` (`countsTowardProgress`, en-têtes exclues) — déplacée, pas réécrite. Quatre tests
la tiennent.

Même motif dans les deux palettes de destinations (`SidebarMenu`, `QuickFindPanel`) : elles
affichent TOUTES les listes quand le champ est vide, et chaque rangée lisait `list.progress()`.
Elles avaient déjà toutes les tâches sous la main — un `SidebarCounts` en tête de leur carte, et
les rangées ne lisent plus rien.

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

### Ce que « Tâches » a cessé de montrer

(12 août 2026.) L'onglet a porté l'inventaire complet : le non-classé à nu, puis « Aujourd'hui »,
puis un dépliant par projet et par liste hors projet, plus les événements du Calendrier du jour. Il
avait sa règle d'or — « une tâche n'apparaît QU'UNE fois » — et toute la mécanique qui allait avec :
`AllTasksPage.Kind`/`Section`/`applyDrop`, un dépliant fait main par section, un repli par section
(`toggled`), le retrait des tâches du jour de partout ailleurs.

Une **barre de tags** a été tentée en remplacement des dépliants (Tout / À classer / Aujourd'hui /
un tag par projet, avec défilement horizontal — pas de « … », qui aurait été un popover). Écrite,
regardée dans les deux thèmes, jetée le même jour : elle rendait la lecture d'un projet plus rapide
sans répondre au vrai reproche, à savoir que la page redisait ce que la barre latérale disait déjà.

Ce qui reste : **la boîte de réception, seule.** Une zone de dépôt — on note ici, on classe après.
Le raisonnement qui a tranché : chaque section répondait à une question à laquelle sa propre page
répond déjà (le projet → sa page, la liste → la sienne, le jour → « Aujourd'hui »), et un événement
du Calendrier n'est rien qu'on puisse classer. Conséquence assumée : la page ressemble de nouveau à
une page de liste, ce qui avait justement motivé l'inventaire en août. La différence est qu'elle
l'assume — c'est bien une liste, celle de l'Inbox, et son titre le dit.

Une tâche datée du jour RESTE désormais dans « Tâches » : elle n'en était retirée que parce que la
section « Aujourd'hui » l'aurait montrée une seconde fois.

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
