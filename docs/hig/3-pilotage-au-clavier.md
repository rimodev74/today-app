# 3 — Le pilotage au clavier

**Critères HIG** : 1.3.1 (support complet du clavier), 3.5 (usage 100 % clavier).
**État** : 🟡 partiel. L'essentiel est arrivé avec le point 1.

## Constat de départ (22 août 2026)

Ce qui marchait : ↑/↓ et ⌫ sur les cinq pages (`TaskKeyMonitor`), ⌘N, ⌘⇧N, ⌘B, ⌘K, ⌘Z branché sur
l'`UndoManager` de la fenêtre, Échap, ⇥ dans la capsule, le raccourci global configurable et les
abréviations texte.

Ce qui manquait :

- **La recherche n'avait aucun raccourci** — bouton loupe à la souris uniquement, ⌘F non branché.
- **Aucun raccourci pour changer de page** depuis l'app (les abréviations `!today` existent, mais
  elles passent par la capsule, donc par une autre fenêtre).
- **La barre latérale n'est pas navigable au clavier** — aucune gestion de touches dans
  `SidebarView`.
- **Pas de ⇥** entre la barre latérale et la page.

## Ce qui est fait

Tombé avec le point 1 ([1-barre-de-menus.md](1-barre-de-menus.md)) :

- **⌘F** ouvre la palette de recherche.
- **⌘1…⌘5** changent de page sans quitter le clavier.
- ⌘N, ⌘⇧N, ⌥⌘N, ⌥⇧⌘N, ⌘B sont désormais **visibles** dans les menus — un raccourci qu'on ne peut pas
  découvrir n'existe que pour qui l'a écrit.

## Ce qui reste

| Geste | État | Note |
| ----- | ---- | ---- |
| ⇥ entre la barre latérale et la page | À faire | Le vrai manque : rien ne relie les deux colonnes au clavier. |
| ↑/↓ dans la barre latérale | À arbitrer | **Jugé peu prioritaire à l'usage** (24 août 2026) : la navigation passe déjà par ⌘1…⌘5, les raccourcis globaux et la capsule. À reprendre seulement si le besoin se fait sentir. |
| ↩ pour ouvrir la destination sélectionnée | Dépend du point précédent | Sans flèches dans la sidebar, il n'y a rien à ouvrir. |

## Pièges du projet à respecter

- **Pas de premier répondeur fantôme.** `WindowConfigurator` résigne le focus initial au lancement
  (`makeFirstResponder(nil)`) précisément pour que ⌫ n'aille pas dans un champ que personne n'a
  choisi. Toute navigation clavier dans la sidebar doit vivre avec cette règle.
- **Un moniteur `NSEvent` local écoute TOUTE l'application** : Réglages et capsule compris. Tout
  nouveau moniteur teste sa fenêtre (`event.window === window`), comme `TaskKeyMonitor`.
- **Ce qui s'installe se démonte** : `removeMonitor` sur le chemin de sortie.
- Si un raccourci peut vivre dans un MENU, il y va — c'est la leçon du point 1 : un seul chemin, et
  il s'affiche.
