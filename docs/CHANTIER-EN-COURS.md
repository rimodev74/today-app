# Chantier en cours — reprise de session

**Lire `CLAUDE.md` d'abord** (architecture, pièges, conventions). Ce fichier-ci ne dit que ce qui
reste à faire et *pourquoi* — il ne répète pas ce qui y est déjà écrit.

Repères au moment d'écrire : commit `899530b`, **159 tests verts**, cliquet de concurrence **inchangé**
(que des chemins de clé SwiftData, cf. `Package.swift`), `TaskListView.swift` à 2 764 lignes.

---

## L'objectif, dans les mots du propriétaire du projet

> Une base unique de fonctionnalités pour tous les onglets, puis des contraintes ajoutées au cas par
> cas — jamais l'inverse.

Et sur la qualité attendue : solide, évolutif, cohérent, fondé sur des conventions solides, **sans
rafistolage qui se paie plus tard**.

Ce principe est écrit dans `CLAUDE.md`. Il n'est **pas encore vrai** : c'est tout l'objet de ce
chantier.

---

## Où on en est vraiment

| Page | ⌫ | ↑ ↓ | clic dans le vide | glisser |
|---|:--:|:--:|:--:|:--:|
| Page d'une liste (`ListPageView`) | ✅ | ✅ | ✅ | ✅ |
| Aujourd'hui (`TodayPageView`) | ✅ | ✅ | ✅ | ✅ |
| Tâches (`AllTasksPageView`) | ✅ | ✅ | ✅ | ✅ |
| À venir (`UpcomingPageView`) | ✅ | ✅ | ✅ | — |
| Archives (`ArchivePageView`) | ✅ | ✅ | ✅ | — |

Toutes les pages passent par le MÊME socle (`TaskPageBase`) : elles déclarent leurs pans, il leur
rend le clavier et le clic dans le vide. Une sixième page se construira avec, sans une ligne de
plus.

« — » = pas de glissement, et c'est un choix : « À venir » est un aperçu par date (l'ordre y est la
date), « Archives » un journal (l'ordre y est la date de complétion). Rien à réordonner à la main.
Le jour où une page en veut, elle se branche : `reorder:` + `taskRowDragLayer` + `taskReorderPlaceholder`.

Tout le tableau a été vérifié à la main dans l'app, dans les deux thèmes — pas seulement au
compilateur. ⌘Z compris.

---

## ① Le défaut de conception — FAIT (`fefb9f4`)

`TaskPageBase` demandait à chaque page de lui **redécrire à la main** l'ordre de ses lignes, via une
closure `rows` que rien ne reliait au `body` — ni le compilateur, ni un test. L'erreur avait déjà été
commise (la boîte de réception de « Tâches » oubliée) et son symptôme est « la touche ne marche
pas » : rien à l'écran, aucun test rouge.

**Ce qui a été fait : une page ne décrit plus un ORDRE, elle déclare ses PANS.** `TaskPageBlock`
(`Models/TaskPageRows.swift`) = des lignes + « visibles ? ». La page passe les MÊMES valeurs que son
`body` parcourt ; l'aplatissement (sauter les pans repliés) n'est écrit qu'une fois, dans le socle,
et il est testé (`TaskPageRowsTests`).

« Tâches » va plus loin : son `body` rend une seule énumération, `ForEach(page.sections)`. La boîte
de réception y est une section **sans bandeau** (`AllTasksPage.Kind.inbox`) au lieu d'un rendu à
part — c'est-à-dire que l'oubli d'origine n'est plus exprimable.

### Ce que ça ne donne PAS

**Pas les cadres des lignes.** ② reste entier : le clic dans le vide et le glisser demandent de
savoir OÙ chaque ligne est, et ça, aucune valeur ne le sait — seule la mesure le sait.

---

## ② Clic dans le vide et glisser — FAITS

Les lignes publient leur cadre (`TaskRowFrameKey`, repère `taskPageSpace`) et le socle compare le
point de chaque clic de la fenêtre. C'est la brique de `ListPageView` généralisée.

Le glisser a demandé quatre corrections, toutes dans des pièges que le projet connaissait déjà :

1. **la séquence des lignes doit être figée** à l'empoignade (une vue intelligente la recalcule à
   chaque rendu) ;
2. **les cadres aussi**, et il ne suffit pas d'ignorer la nouvelle mesure : il ne faut pas
   l'ÉCRIRE. Un `@State` réécrit à l'identique invalide quand même la vue, et c'est l'invalidation
   qui boucle. Deux stockages de cadres coexistaient, un seul gelait — d'où la saccade ;
3. **la translation se lit dans un repère FIXE** (`taskPageSpace`), jamais dans le repère local :
   celui-ci est celui de la rangée, que le geste déplace. Mesurer un déplacement dans un repère que
   ce déplacement bouge fait trembler la ligne, et c'était LA cause du « ingérable » ;
4. **l'ordre écrit et le retour des décalages à zéro tiennent dans UNE transaction.** Séparés, la
   rangée saute à sa nouvelle place pendant que son décalage s'anime depuis l'ancienne : elle part
   à l'opposé avant de revenir ;
5. **la page RÉAFFICHE sa séquence vivante**, jamais la copie figée. Rendre celle-ci pendant le
   geste puis rebasculer sur celle-là au relâchement produit le MÊME symptôme que le point 4, pour
   une autre raison : le `ForEach` réordonne ses identités au moment où les décalages retombent.
   Rien n'écrit pendant un geste, la séquence vivante ne bouge donc pas d'elle-même — la figer à
   l'affichage ne protège de rien. Le calcul, lui, garde bien sa copie.

Tout ça vit dans `TaskPageChrome` et `TaskPageReorder`, pas dans les pages : `taskRowDragLayer`,
`taskReorderPlaceholder`, `track`, `dropTaskDrag`, `taskDrop`. Une page qui glisse ne redécrit rien.

Ce qui reste à la page, et à elle seule, c'est ce qu'elle ÉCRIT au relâchement — un rang sur
« Aujourd'hui », un rang plus un rattachement sur « Tâches » (`AllTasksPage.applyDrop`). C'est la
même frontière que celle posée en tête de `Reorder.swift`.

---

## ③ Les premiers tests de page — FAIT (`27eb929`)

`TodayPageTests` et `AllTasksPageTests` posent enfin la question qu'on ne posait qu'à l'œil :
*avec ces tâches-là, que montre la page, et dans quel ordre ?* Ce qu'ils tiennent :

- une tâche du jour QUITTE sa liste et son projet — sinon la même ligne se sélectionnerait à deux
  endroits ;
- une tâche en retard n'est repêchée nulle part ;
- un dépliant fermé n'offre aucune ligne au clavier ;
- les listes d'un projet ne fabriquent pas un second dépliant.

Ce qui reste sans test : les pages « À venir » et « Archives », dont le regroupement vit encore dans
la vue (`agenda`, `archiveMonths`). Même mouvement à faire, plus petit.

---

## ⚠️ Points ouverts — SOLDÉS

1. ~~**⌘Z n'est pas vérifié.**~~ Il l'est, et il ne marchait pas : `container.mainContext.undoManager`
   recevait un `UndoManager` neuf, que RIEN ne pouvait atteindre — le menu *Édition ▸ Annuler* parle
   à celui de la FENÊTRE. Branché dans `ContentView` (`.onChange(of: undoManager)`), vérifié à la
   main. Le filet sous ⌫ existe donc pour de bon.
2. ~~**⌫ sur « Tâches »**~~ : fonctionne. Le symptôme rapporté visait en réalité le glisser (les
   flèches ↑/↓ avaient été lues comme « glisser-déposer »). Rien à corriger.

## Déjà essayé et REJETÉ — ne pas refaire

- **Un fond transparent (`.background { Color.clear … onTapGesture }`) pour attraper le clic dans le
  vide.** Essayé deux fois, rejeté deux fois. Un `ScrollView` capte les clics de toute sa surface, et
  un fond de contenu ne couvre de toute façon ni les marges (`gutter`) ni le vide sous la dernière
  ligne. C'était **déjà documenté** dans l'en-tête de `LeftClickOutsideObserver` avant d'être refait.
  La seule réponse qui marche est celle de `ListPageView` : moniteur `NSEvent` + cadres des lignes.
- **Faire taire les 37 diagnostics de chemins de clé** en marquant les `@Model` `@unchecked Sendable`.
  Ce serait un mensonge (ce sont des classes mutables) et le rafistolage que le projet refuse. Trou
  entre SwiftData et Swift 6, à laisser tel quel.
- **Faire publier aux lignes leur identité par `PreferenceKey`, et en dériver l'ordre du clavier.**
  C'était la correction prévue pour ① — elle est FAUSSE sur `ListPageView`, la seule page où tout
  marche : elle est bâtie sur `LazyVStack`, donc les rangées hors écran ne sont pas construites et ne
  publient rien. L'ordre obtenu s'arrête au viewport : ⌫ et ↑/↓ cesseraient d'atteindre les lignes
  non défilées, sur une liste un peu longue, sans que rien ne le montre. Une préférence mesure ce qui
  est RENDU ; l'ordre du clavier est ce qui est AFFICHÉ. Ce n'est pas la même question — d'où
  `TaskPageBlock`, qui est une valeur, pas une mesure. Les cadres, eux, restent bien du ressort d'une
  préférence (②) : eux ne concernent que le visible, c'est leur définition.
- **Le glisser-déposer sur les vues intelligentes, tel quel.** Écrit entièrement (`47dfdd5`), essayé,
  **saccadé à l'usage**, retiré (`6ad6b41`). Le calcul n'y était pour rien : `ReorderTarget` et
  `ReorderLayout` sont partagés avec la page d'une liste, qui glisse parfaitement. La cause est que
  ces pages n'ont pas d'ordre STOCKÉ — leurs lignes sont une requête dérivée, donc chaque image du
  geste réévalue le `body`, refiltre, retrie et regroupe tout le contenu de la page. Ne pas
  reprendre le geste sans avoir d'abord donné à ces pages une séquence stable (cf. ② ci-dessus).
  L'état de geste (`TaskPageReorder`) et le champ d'ordre (`TaskItem.smartOrder`) sont récupérables
  tels quels dans l'historique — ils n'étaient pas faux, ils étaient prématurés.
- **Le curseur « main » sur toute la ligne.** Sur macOS, la main signale un bouton ou un lien, jamais
  une ligne sélectionnable (Finder, Mail, Rappels gardent la flèche). Le comportement actuel — main
  sur la case à cocher seulement — est **correct**. Si un repère de survol manque, la bonne réponse
  est un fond de survol, pas un changement de curseur.

---

## Invariants à ne pas casser

- **`swift test` : 159 tests, tous verts.**
- **Cliquet de concurrence : exactement 37 diagnostics, tous « does not conform to Sendable » sur des
  chemins de clé.** Tout diagnostic d'une AUTRE nature est une régression d'isolation à corriger
  sur-le-champ, pas à ajouter au décompte.
- **Un build incrémental ne montre rien.** Avant de conclure :
  `find Sources Tests -name '*.swift' -exec touch {} +` puis `swift build && swift test`, et
  `-c release` (module entier, diagnostics que le debug tait).
- **`SchemaCompatibilityTests` rouge ⇒ ne pas lancer l'app** : suivre les cinq points en tête de
  `Models/TodaySchema.swift`.
- **La vraie base contient de vraies données** (~85 tâches). Compter avant de toucher :
  `sqlite3 ~/Library/Application\ Support/default.store "select count(*) from ZTASKITEM;"`.

---

## Reporté délibérément

| Sujet | Pourquoi |
|---|---|
| Sélection multiple | `TaskFocus` est conçu pour l'accueillir sans réécrire les pages. Pas urgent. |
| Mode langage Swift 6 | Bloqué par les 37 chemins de clé (trou d'Apple). Vérification déjà active en avertissements. |
| Découpage de `TaskListView`, passe 2 | `TaskRow` (~900 l.) et `ProjectPageView` restent à sortir. Mécanique, sans risque, à faire au fil de l'eau. Attention : `Checkmark` et `NotesBox` devront passer de `private` à interne. |
| `TaskItem.hasTime` | Lu par `UpcomingPageView`, mais **rien ne le met jamais à `true`** : l'app ne pose que des jours. Champ du modèle qui ment. |
| Icône **tag** de la carte d'édition | Ne fait rien — le modèle ne porte pas de tags. |
| Édition en ligne sur « À venir » et « Archives » | Elles ont la sélection, pas la carte d'édition : on ne renomme pas une tâche terminée, et « À venir » est un aperçu par date. `TaskFocus.editing` y reste `nil`, ce qui n'est PAS un oubli. |
| Filtrer le bruit des 37 diagnostics dans `Scripts/quick.sh` | Proposé, non fait. Noyé dans 300 lignes, un VRAI nouveau warning passerait inaperçu — ce qui annule l'intérêt du cliquet. |

---

## Ordre recommandé

1. **Sortir le regroupement de « À venir » et « Archives »** de leurs vues, comme les deux autres
   (`agenda`, `archiveMonths`) — et leurs tests viennent avec. C'est le dernier endroit où une page
   calcule dans son `body`.
2. Le reste est dans « Reporté délibérément » : rien qui presse.
