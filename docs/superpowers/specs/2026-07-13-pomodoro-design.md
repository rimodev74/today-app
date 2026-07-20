# Onglet Pomodoro + timer live en menu bar

Date : 2026-07-13

## Contexte

Ajout d'un minuteur Pomodoro, accessible depuis un nouvel onglet dans la
sidebar, avec un affichage live du compte à rebours dans la barre de menus
macOS. Scope volontairement minimal (fondamentaux) : durée de travail,
pause courte, pause longue, et une alarme sonore en fin de phase.

## 1. Modèle — `PomodoroPhase` + `PomodoroTimer`

Nouveau fichier `Models/PomodoroPhase.swift` :

```swift
enum PomodoroPhase {
    case work
    case shortBreak
    case longBreak
}
```

Nouveau fichier `Models/PomodoroTimer.swift`, classe `@Observable
PomodoroTimer` — source de vérité unique, une seule instance créée dans
`ThingsCloneApp` et injectée via `.environment()` (partagée entre la
fenêtre principale et la menu bar, pas de duplication d'état) :

- `phase: PomodoroPhase`, `remaining: TimeInterval`, `isRunning: Bool`,
  `completedWorkSessions: Int` (compteur pour savoir quand déclencher la
  pause longue).
- Durées réglables, persistées en `@AppStorage` (défauts classiques :
  25 / 5 / 15 min). Un changement de durée ne s'applique qu'à la prochaine
  fois que la phase concernée démarre (pas de resize en cours de compte à
  rebours, pour rester simple).
- `start()` / `pause()` / `reset()` : `reset()` remet `phase = .work` et
  `remaining` à la durée de travail configurée.
- Un seul `Timer` (1s) décrémente `remaining` pendant `isRunning`. À 0 :
  `NSSound.beep()`, puis enchaînement automatique :
  - `.work` → `.shortBreak`, sauf toutes les 4 sessions de travail
    complétées → `.longBreak` (`completedWorkSessions` incrémenté
    uniquement en sortie de `.work`).
  - `.shortBreak` / `.longBreak` → `.work`.
- Pas de persistance de l'état du minuteur entre lancements de l'app :
  redémarre à `.work` / arrêté si l'app est relancée (hors scope).

## 2. Sidebar — nouvel onglet

`SidebarSelection` gagne un cas `pomodoro`, séparé de `smartList` (n'est
pas une liste de tâches) :

```swift
enum SidebarSelection: Hashable {
    case smartList(SmartList)
    case project(Project)
    case area(Area)
    case pomodoro
}
```

`SidebarView` : nouveau groupe à une ligne (même pattern que `topLists`),
label "Pomodoro", icône `timer`.

## 3. Vue détail — `PomodoroView`

`TaskListView.body` route `.pomodoro` vers une nouvelle vue
`PomodoroView` (nouveau fichier `Views/PomodoroView.swift`) au lieu de
`content(for:)` — le Pomodoro n'a rien à voir avec le rendu de liste de
tâches existant.

Contenu de `PomodoroView` :
- Libellé de la phase en cours + compte à rebours `MM:SS` en gros.
- Boutons Start/Pause/Reset.
- Trois steppers (travail / pause courte / pause longue, en minutes) liés
  aux réglages `@AppStorage` de `PomodoroTimer`.

## 4. Menu bar — `MenuBarExtra`

Nouvelle scène dans `ThingsCloneApp` :

```swift
MenuBarExtra {
    // phase en cours + Start/Pause/Reset (même PomodoroTimer partagé)
} label: {
    Text(timeLabel) // "23:41", ou icône seule si arrêté
}
```

Lit/écrit la même instance `PomodoroTimer` que `PomodoroView` (aucune
logique dupliquée) — clic ouvre un petit menu avec les mêmes contrôles
que la vue principale, en plus compact.

## 5. Test

Un seul test unitaire (nouveau target `Tests/ThingsCloneTests`, ajouté à
`Package.swift`) sur la seule logique non triviale du feature :
l'enchaînement des phases, en particulier le déclenchement de la pause
longue tous les 4 cycles de travail.

## Hors périmètre

- Pas de persistance du minuteur entre lancements de l'app.
- Pas de notification macOS (son uniquement, validé avec l'utilisateur).
- Pas d'enchaînement manuel (l'utilisateur ne choisit pas la phase
  suivante, tout est automatique, validé avec l'utilisateur).
- Pas de configuration du nombre de sessions avant pause longue (fixé à 4,
  non exposé en réglage).
