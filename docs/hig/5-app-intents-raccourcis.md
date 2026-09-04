# 5 — App Intents (Raccourcis, Siri)

**Critère HIG** : 1.3.4 (intégration Siri / Raccourcis).
**État** : à faire. Rien n'existe.

## Constat

Aucun `AppIntent`, aucun `NSUserActivity`. L'app n'apparaît donc pas dans Raccourcis, ne répond pas
à Siri, et n'est pas atteignable depuis une automatisation système.

Il existe bien une porte d'entrée extérieure — une notification distribuée qui ouvre la capsule
(`QuickEntryWindow.toggleNotification`, appelable en `osascript` d'une ligne) — mais elle n'est
documentée nulle part pour l'utilisateur, et elle ne sait faire qu'une chose.

## Ce qu'on fait

Deux intents pour commencer :

| Intent | Paramètres | Effet |
| ------ | ---------- | ----- |
| Ajouter une tâche | titre (texte), date (optionnelle), liste (optionnelle) | Crée la tâche, comme la capsule |
| Démarrer un pomodoro | — | `AppCommand.pomodoroStart` |

Plus `AppShortcutsProvider` pour les phrases Siri.

## Où ça se branche

- Le parseur de saisie rapide (`QuickEntry`) sait déjà lire `@demain`, `#liste`, `@14h30` : un
  intent qui reçoit une phrase brute peut le réutiliser tel quel plutôt que de refaire une API de
  paramètres.
- L'écriture passe par le même chemin que la capsule (même `ModelContainer`, cf.
  `TodayApp.container`), donc par `deleteCascadeAndSave` / `insertAndSave` selon le cas.

## Points d'attention

- **Un intent peut s'exécuter app NON lancée.** Le container s'ouvre alors dans le process de
  l'extension ou au lancement : vérifier que `StoreBackup` / `StoreQuarantine` ne sont pas joués
  deux fois, et qu'aucune écriture ne part avant que le store soit prêt.
- **Deux processus ne doivent pas écrire dans le même store SwiftData en même temps.** Si l'intent
  vit dans une extension, c'est un vrai sujet ; le tenir dans le process de l'app (intent « in-app »)
  l'évite entièrement. **Commencer par là.**
- EventKit s'écrit APRÈS SwiftData, jamais pendant (règle du projet) : un intent qui date une tâche
  suit le même ordre que le reste.
- Le minimum du projet est macOS 14 : `AppIntent` y est disponible, mais vérifier chaque API
  utilisée — le build ne signale pas un `@available(macOS 15+)`.
