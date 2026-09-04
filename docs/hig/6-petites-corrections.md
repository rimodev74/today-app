# 6 — Deux corrections d'une ligne

Deux écarts relevés par l'audit, sans rapport entre eux, trop petits pour un chantier chacun.

## 6.1 — La fenêtre n'a pas de taille minimale

**Critère HIG** : 1.1.4 · **État** : à faire

Rien dans le code ne borne la taille de la fenêtre : ni `.windowResizability`, ni `minWidth` sur le
contenu. `.defaultSize(width: 1400, height: 900)` ne fixe que la taille d'OUVERTURE.

Conséquence : on peut réduire la fenêtre jusqu'à ce que la page devienne inutilisable — la colonne
de contenu vaut alors `max(largeur - 130, 1)`, les deux gouttières de 65 pt mangeant tout.

**Ce qu'on fait** : un `minWidth` / `minHeight` sur `ContentView`, ou
`.windowResizability(.contentMinSize)` sur le `WindowGroup`. Valeur à choisir en regardant à partir
de quand la barre du bas et l'en-tête de page se marchent dessus — donc à l'œil, pas au jugé.

**Attention** : la barre latérale est repliable et sa largeur est persistée ; le minimum doit valoir
pour la fenêtre **sidebar repliée**, sinon on interdit une taille qui marche.

## 6.2 — La sélection ne se désature pas quand la fenêtre perd le focus

**Critère HIG** : 1.4.2 · **État** : à faire

Aucune lecture de `controlActiveState` dans le projet. La surbrillance lavande d'une ligne
sélectionnée (`thingsSelectionFill`) garde exactement la même intensité quand la fenêtre passe à
l'arrière-plan, alors qu'AppKit atténue normalement toute sélection dans une fenêtre inactive.

Sur deux fenêtres côte à côte — Today et autre chose — on ne voit plus laquelle a le clavier.

**Ce qu'on fait** : lire `@Environment(\.controlActiveState)` là où la teinte est appliquée, et
baisser l'alpha quand l'état vaut `.inactive`.

**Attention** :

- `thingsSelectionFill` est une couleur globale résolue par apparence
  (`NSColor(name:) { appearance in … }`) : elle ne connaît pas l'environnement SwiftUI. Soit elle
  gagne une variante « inactive » choisie par la vue, soit la vue applique une opacité par-dessus.
  **Ne pas** figer une couleur claire en dur — règle du projet : une couleur figée se double.
- Le changement doit passer par la page, pas par un `.animation(value:)` posé sur la rangée.
