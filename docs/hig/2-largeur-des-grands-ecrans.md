# 2 — La largeur sur grand écran

**Critères HIG** : 1.1.1 (tirer parti des grands écrans), 3.1 (densité), 2.3 (plein écran pensé pour
la concentration).
**État** : ⛔ tentative écrite le 24 août 2026, **entièrement annulée le même jour**. Le code est
revenu à son état d'avant.

## Constat

Mesuré le 22 août 2026, plein écran sur l'écran 5K (2056 pt utiles) : une page affiche exactement ce
qu'elle affiche dans une fenêtre de 1400 pt — une colonne unique collée à gauche, ~1400 pt de vide à
droite. Une ligne de tâche s'étire sur 1666 pt : son titre à un bout, sa date à l'autre. Une note
tient ~130 caractères par ligne.

Le tableau d'un PROJET, lui, se remplit correctement : sa grille est adaptative (cartes de 250 à
340 pt), la largeur y sert à montrer plus de cartes.

## Ce qui a été essayé, et pourquoi c'est annulé

Plafond de 800 pt sur la colonne de contenu + centrage, appliqué aux six pages via un modificateur
partagé (`centeredPageColumn`). Le tableau d'un projet a d'abord gardé un plafond plus large
(1200 pt), puis a été ramené à 800 pour que le titre d'un projet et celui de ses listes tombent au
même endroit.

**Deux erreurs, dans cet ordre :**

1. **Plafonner le tableau était un mauvais échange.** La grille passait de trois cartes de front à
   deux (800 pt moins le retrait de colonne laissent 780 ; il en faut 802 pour trois). On retirait
   de la densité RÉELLE — des cartes visibles en moins — pour gagner un alignement de titre, qui
   est cosmétique. C'est l'inverse de ce que demande le HIG.
2. **Plafonner sans remplir ne rend rien.** Sur les pages de tâches, l'argument tenait (une colonne
   étirée ne montre pas une tâche de plus), mais le résultat à l'écran est une app qui abandonne
   la moitié de la fenêtre sans contrepartie. Le gain de lisibilité ne compense pas l'impression
   d'espace gâché — verdict à l'usage, sur capture, le 24 août 2026.

## La règle qui en sort

> **La largeur se REMPLIT, ou ne se touche pas.**

Un plafond n'a de sens que s'il libère la place pour autre chose. Tant qu'il n'y a rien à mettre à
droite, les pages restent pleine largeur.

Corollaire : ne pas reproposer « on centre la colonne » comme correctif isolé. C'est écrit, essayé,
annulé.

## La suite envisagée — un panneau de détail

La seule façon honnête d'occuper la largeur : y mettre du contenu. Panneau à droite montrant la
tâche sélectionnée — notes, sous-tâches, date, liste, priorité, durée.

À trancher AVANT d'écrire une ligne :

- **Ce qu'il remplace.** Aujourd'hui l'édition ouvre une carte DANS la ligne (`TaskRow`). Deux
  surfaces d'édition ne peuvent pas coexister sans règle : soit le panneau prend le relais au-delà
  d'une largeur donnée et la carte inline ne s'ouvre plus, soit l'un des deux disparaît.
- **À partir de quelle largeur** il apparaît, et ce qui se passe en dessous.
- **S'il est optionnel** (réglage, bouton de barre d'outils) ou automatique.
- **Ce qu'il montre exactement**, et ce qui reste au clic droit.

Pièges du projet à respecter dans ce chantier :

- Aucun popover, aucune fenêtre : le panneau vit DANS la fenêtre (cf. `PIEGES.md` § Fenêtres).
- Pas de lecture de propriété calculée d'un `@Model` par rangée : le panneau lit UNE tâche, une fois.
- Les transitions sont pilotées par la page en `withAnimation`, pas par un `.animation(value:)`
  posé sur le panneau.
- Un champ focalisé veut une fenêtre conteneur du début à la fin — le panneau ne doit jamais être
  monté « caché » avec un premier répondeur dedans.

## État du code

Rien. Les six pages sont telles qu'avant le 24 août 2026 :
`.frame(width: max(geo.size.width - 2 * gutter, 1), alignment: .leading)` + `.padding(.horizontal,
gutter)` pour celles qui éditent en place, `.frame(maxWidth: .infinity, alignment: .leading)` pour
les autres, `gutter` de 65 pt partout.
