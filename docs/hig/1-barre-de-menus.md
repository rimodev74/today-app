# 1 — La barre de menus

**Critères HIG** : 2.1 (barre de menus), 3.3 (accès à toutes les commandes), et une bonne part de
3.5 (raccourcis clavier).
**État** : ✅ fait le 23 août 2026. Reste le menu *Tâche*, pas commencé.

## Constat

Relevé à l'écran avant le chantier : `TodayDev · Edit · Format · View · Window · Help`.

- **Aucune** commande du produit dans les menus : ni nouvelle tâche, ni recherche, ni les quatre
  pages intelligentes, ni le pomodoro.
- Pas de menu **Fichier** du tout : il avait été vidé (`CommandGroup(replacing: .newItem) {}`) pour
  empêcher ⌘N d'ouvrir un onglet.
- Les menus système étaient **en anglais** dans une app entièrement française.
- Les raccourcis existants (⌘N, ⌘⇧N, ⌘B) ne s'affichaient nulle part : indevinables.

## Décision

Deux mécanismes, et deux seulement :

- **`AppCommand`** pour ce qui EMMÈNE quelque part ou pilote le minuteur. Il existait déjà pour les
  raccourcis texte (`!today`) et sait ramener une fenêtre fermée au bouton rouge.
- **`FocusedValues`** pour ce qui agit DANS la page affichée. C'est le mécanisme natif prévu pour
  qu'un menu parle à la scène active, et il apporte le grisage sans une ligne de plus.

Ce qui n'y est pas est délibéré : durée, rappel, dupliquer, priorité, couleur, renommer restent au
clic droit. *Un menu qui liste tout est un menu que personne ne lit.*

## Ce qui est en place

| Menu | Items |
| ---- | ----- |
| Today | Rechercher les mises à jour… |
| Fichier | Nouvelle tâche ⌘N · Nouvel en-tête ⌘⇧N · Nouvelle to-do list ⌥⌘N · Nouveau projet ⌥⇧⌘N |
| Édition | Rechercher… ⌘F · Ajouter un lien… ⌘K |
| Présentation | Masquer / Afficher la barre latérale ⌘B |
| Aller | Tâches ⌘1 · Aujourd'hui ⌘2 · À venir ⌘3 · Archives ⌘4 · Pomodoro ⌘5 |
| Pomodoro | Lancer · Pause · Phase suivante · Pause courte · Pause longue |

## Où ça se branche

- `Views/MainMenu.swift` — **nouveau**. `MenuAction` / `SidebarToggle` (valeurs focalisées),
  les clés `FocusedValues`, et `MainMenuCommands`.
- `ThingsCloneApp.swift` — `.commands { TextFormattingCommands(); MainMenuCommands() }`.
- `TaskPageChrome.swift` — `TaskPageBase` publie `newTask` : **un seul point pour les cinq pages**.
- `TaskListView.swift` — publie `newHeader` (les en-têtes n'existent que sur cette page).
- `SidebarView.swift` — publie `newProject` et `newList` (+ `listTarget`, le projet d'accueil).
- `ContentView.swift` — publie `search` et `sidebarToggle`.
- `Scripts/make-app.sh` — `fr.lproj` + `CFBundleDevelopmentRegion`.
- `WindowConfigurator.swift` — `tabbingMode = .disallowed`.

## Ce qui a été RETIRÉ

- Les moniteurs `NSEvent` de ⌘N (socle) et ⌘⇧N (page d'une liste).
- Le type `KeyCommandMonitor` lui-même, devenu sans usage (`AppKitBridges.swift`).
- Le bouton caché qui portait ⌘B dans `ContentView`.

Un seul chemin par raccourci, et il s'affiche dans un menu.

## Pièges rencontrés — à ne pas repayer

**1. ⌘N depuis la capsule créait une tâche dans la fenêtre de derrière.** AppKit propose les
équivalents clavier au MENU avant de les donner à la fenêtre clé. L'ancien moniteur s'en protégeait
par `event.window === window` ; le menu n'a rien de tel. D'où `inMainWindow(_:)` dans
`MainMenuCommands` : `NSApp.keyWindow?.canBecomeMain ?? false`. La capsule et le HUD sont des
panneaux sans bordure, donc jamais `canBecomeMain`. **Mesuré** : garde absente → l'action partait ;
garde en place → fenêtre principale `true`, capsule `false`.
Les Réglages sont une Scene à part : leurs valeurs focalisées ne sont pas celles de la fenêtre
principale, l'item y est déjà grisé.

**2. ⌘1…⌘5 sur un clavier AZERTY.** SwiftUI adapte les équivalents à la DISPOSITION : l'item stocke
`&`, `é`, `"`, `'`, `(` — le menu les affiche tels quels, et la touche répond seule.
**Mesuré** : en `localization: .custom`, l'équivalent reste le chiffre `1`, le menu affiche « ⌘1 »…
mais il faut alors presser **⌘⇧1**. Le défaut est le bon comportement ; ne pas « corriger »
l'affichage.

**3. Lire `isEnabled` à froid ne prouve rien.** `NSMenu.update()` hors ouverture réelle rend un état
qui ne correspond pas à ce que SwiftUI applique. Pour vérifier un grisage, faire AGIR la touche
(`performKeyEquivalent`) plutôt que lire l'état — et se souvenir que `performKeyEquivalent` rend
`true` dès que l'item a pris la frappe, même si l'action se garde elle-même.

**4. Les valeurs focalisées ne sont publiées que si l'app est ACTIVE.** Une sonde qui lit les menus
sans `NSApp.activate` (et sans laisser un tour de boucle passer) voit tout grisé, pour une raison
sans rapport avec le code testé.

## Vérifications faites

Sonde temporaire (retirée), app de dev, 24 août 2026 :

- ⌘N, ⌥⌘N, ⌘F, ⌘B, et les touches physiques 1 et 3 : pris par leur item.
- ⌘⇧N : sans effet sur « Aujourd'hui » (grisé, pas d'en-tête sur cette page), agit sur une liste.
- Menus relevés en français après `fr.lproj`, entrées d'onglets absentes.
- `swift build -c release` complet : 0 avertissement hors chemins de clé. 418 tests verts.

## Reste à faire — le menu *Tâche*

Terminer · Aujourd'hui ⌘T · Demain · Quand… · Assigner ▸ · Supprimer.

Deux questions à trancher AVANT d'écrire :

1. **Comment le menu atteint la tâche sélectionnée.** `TaskFocus` vit dans le `@State` de chaque
   page ; `TaskPageBase` connaît `focus` et `rows`, il peut donc résoudre la sélection et publier un
   jeu d'actions — c'est le même point de branchement que `newTask`.
2. **« Assigner ▸ » a besoin des destinations** (`moveTargets`), qui vivent aujourd'hui dans la
   rangée. Les remonter au socle, ou renoncer à ce sous-menu et le laisser au clic droit.
