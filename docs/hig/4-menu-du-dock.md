# 4 — Le menu du Dock

**Critère HIG** : 2.4 (menus du Dock).
**État** : à faire. Rien n'existe.

## Constat

Aucun `NSApplicationDelegate`, aucun `applicationDockMenu(_:)`. Clic droit sur l'icône du Dock : les
seules entrées sont celles que macOS fournit d'office (Ouvrir, Options, Quitter). Zéro action de
l'app.

C'est d'autant plus dommage ici que Today est une app qu'on garde ouverte en permanence, avec une
icône de barre de menus et un raccourci global : elle est faite pour être atteinte de l'extérieur.

## Ce qu'on fait

Trois entrées, pas plus :

```
Nouvelle tâche
Aujourd'hui
Démarrer un pomodoro
```

Toutes existent déjà comme `AppCommand` ou comme action de page — c'est du câblage.

## Où ça se branche

- Un `NSApplicationDelegate` via `@NSApplicationDelegateAdaptor` dans `TodayApp`, avec
  `applicationDockMenu(_:)` qui rend un `NSMenu` construit à la main.
- Les items appellent `AppCommand.reveal(.smartList(.today))` et
  `AppCommand.pomodoroStart.run()` — les mêmes chemins que la barre de menus et les raccourcis
  texte, qui savent déjà ramener une fenêtre fermée au bouton rouge.

## Points d'attention

- **« Nouvelle tâche » depuis le Dock n'a pas de page sous la main** : contrairement au menu
  *Fichier*, il n'y a pas de valeur focalisée à lire (l'app peut être en arrière-plan, fenêtre
  fermée). Deux options : ouvrir la capsule de saisie rapide (cohérent avec le reste de l'app), ou
  ramener la fenêtre sur « Tâches » et y créer une ligne. **La capsule est la bonne réponse** :
  c'est déjà le geste « noter sans quitter ce qu'on fait ».
- Le menu du Dock est construit hors de tout arbre SwiftUI : ne rien y lire qui vienne d'un
  `@Environment` ou d'une `@Query`.
- Ne pas dupliquer les libellés : `AppCommand.label` les porte déjà.
