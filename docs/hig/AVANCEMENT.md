# Conformité macOS — avancement

Suivi des chantiers issus de l'audit HIG (`../../AUDIT-HIG.md`, 22 août 2026 — score initial :
10/22 critères conformes).

Un fichier par chantier, dans ce dossier. Ce fichier-ci ne porte que l'ÉTAT ; le détail, les
mesures et les pièges sont dans le fichier du chantier.

## Les trois points discutés

| # | Chantier | État | Détail |
| - | -------- | ---- | ------ |
| 1 | Barre de menus | ✅ **Fait** (23 août 2026) — reste le menu *Tâche* | [1-barre-de-menus.md](1-barre-de-menus.md) |
| 2 | Largeur sur grand écran | ⛔ **Tentative annulée** (24 août 2026) — à reprendre autrement | [2-largeur-des-grands-ecrans.md](2-largeur-des-grands-ecrans.md) |
| 3 | Pilotage au clavier | 🟡 **Partiel** — l'essentiel est tombé avec le point 1 | [3-pilotage-au-clavier.md](3-pilotage-au-clavier.md) |

### Point 1 — ce qui est en place

Menus *Fichier*, *Aller*, *Pomodoro*, plus *Rechercher…* ⌘F, *Masquer la barre latérale* ⌘B et
*Rechercher les mises à jour…*. Deux mécanismes : `AppCommand` pour ce qui emmène quelque part,
`FocusedValues` pour ce qui agit dans la page. Deux moniteurs `NSEvent` et un bouton caché retirés.

Deux corrections tombées du même chantier : les menus système passent en **français** (`fr.lproj`),
et les six entrées d'**onglets** disparaissent (`tabbingMode = .disallowed`).

Reste : le menu *Tâche* (Terminer, Aujourd'hui, Demain, Quand…, Assigner, Supprimer). Pas commencé —
il demande de décider comment un menu atteint la tâche sélectionnée.

### Point 2 — ce qui s'est passé

Un plafond de 800 pt + centrage a été posé sur les six pages, puis **entièrement annulé** : sur le
tableau d'un projet il retirait des cartes (la grille, elle, montre vraiment plus quand elle
s'élargit), et sur les pages de tâches il ne rendait rien en échange de l'espace qu'il abandonnait.

Le code est revenu à son état d'avant. La leçon est écrite dans le fichier du chantier :
**la largeur se REMPLIT, ou ne se touche pas.**

### Point 3 — ce qui reste

⌘F, ⌘1…⌘5 et les créations sont arrivés avec les menus. Reste : ⇥ entre la barre latérale et la
page, et les flèches dans la barre latérale — ce dernier point est jugé peu prioritaire côté usage
(la navigation passe déjà par les raccourcis globaux et la capsule).

## Les autres chantiers de l'audit

| Chantier | Critère HIG | État | Détail |
| -------- | ----------- | ---- | ------ |
| Menu du Dock | 2.4 ❌ | À faire | [4-menu-du-dock.md](4-menu-du-dock.md) |
| App Intents / Raccourcis | 1.3.4 ❌ | À faire | [5-app-intents-raccourcis.md](5-app-intents-raccourcis.md) |
| Taille minimale de fenêtre · sélection fenêtre inactive | 1.1.4 · 1.4.2 ⚠️ | À faire | [6-petites-corrections.md](6-petites-corrections.md) |
| Export des données | 2.2 ⚠️ | À arbitrer | [7-export-des-donnees.md](7-export-des-donnees.md) |

## Conventions de ce dossier

- Un chantier = un fichier, avec toujours : **Constat** (mesuré), **Décision**, **Où ça se
  branche**, **Pièges du projet**, **État**.
- Ce qui est ABANDONNÉ reste écrit, avec la raison. Ce projet a déjà réimplémenté deux fois des
  choses qu'il avait retirées (cf. `CLAUDE.md` § Déjà rejeté) ; ce dossier sert aussi à ça.
- Une mesure sans chiffre n'est pas une mesure.
