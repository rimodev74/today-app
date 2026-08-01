# Chantier en cours — reprise de session

**Lire `CLAUDE.md` d'abord** (architecture, pièges, conventions). Ce fichier-ci ne dit que ce qui
reste à faire et *pourquoi* — il ne répète pas ce qui y est déjà écrit.

Repères au moment d'écrire : commit `b0f1e28`, **122 tests verts**, cliquet de concurrence à **37**
(tous des chemins de clé SwiftData, cf. `Package.swift`), `TaskListView.swift` à 2 763 lignes.

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
| Aujourd'hui (`TodayPageView`) | ✅ | ✅ | ❌ | ❌ |
| Tâches (`AllTasksPageView`) | ⚠️ | ⚠️ | ❌ | ❌ |
| À venir (`UpcomingPageView`) | — | — | — | — |
| Archives (`ArchivePageView`) | — | — | — | — |

⚠️ = **signalé non fonctionnel par l'utilisateur, non résolu.** Une première correction (ajouter
`inboxTasks` à `rows`, cf. plus bas) n'a pas suffi — la cause réelle n'est pas trouvée. À
diagnostiquer, pas à re-corriger à l'aveugle.

« — » = ces pages n'ont **aucune notion de sélection** : ni `TaskFocus`, ni clic qui sélectionne.
Leur donner le socle demande d'abord de leur donner une sélection.

---

## ① Le défaut de conception à corriger EN PREMIER

`TaskPageBase` (dans `Views/TaskList/TaskPageChrome.swift`) demande à chaque page de lui
**redécrire à la main** l'ordre de ses lignes, via une closure `rows` :

```swift
.taskPageBase(
  focus: $focus,
  rows: { inboxTasks + sections.filter(isExpanded).flatMap(\.tasks) },  // ← doit refléter le body
  delete: delete
)
```

**Rien ne garantit que cette description corresponde au `body`.** Ni le compilateur, ni un test.
L'erreur a déjà été commise une fois (la boîte de réception de « Tâches » était oubliée), et le
symptôme est « la touche ne marche pas » — sans rien de visible à l'écran, sans test rouge.

C'est une couture molle dans un composant partagé : sa justesse dépend de la vigilance de
l'appelant. Exactement ce que le projet refuse.

### La correction, qui règle aussi ② et ③

**Que les lignes se déclarent elles-mêmes en se rendant.** Chaque `TaskRow` publie son identité ET
son cadre par une `PreferenceKey` ; la page les reçoit dans l'ordre du rendu.

Conséquences en cascade :

- l'ordre ne peut plus diverger du `body` — il en *est* dérivé ; la closure `rows` disparaît ;
- **on obtient les cadres des lignes**, qui sont précisément ce qui manque au clic dans le vide et au
  glisser (cf. ②) ;
- une page devient interrogeable (« quelles lignes présentes-tu, dans quel ordre ? »), donc
  **testable** (cf. ③).

Le mécanisme existe déjà dans le projet : `RowFrameKey` + `.coordinateSpace(name:)` dans
`ListPageView`. Il s'agit de le généraliser, pas de l'inventer.

---

## ② Ce qui en découle : clic dans le vide, puis glisser

Les deux reproches de l'utilisateur (« la tâche ne se désélectionne pas », « impossible de
glisser ») **reposent sur la même brique manquante** : les pages intelligentes ne mesurent pas la
position de leurs lignes.

- Sans cadres → impossible de savoir si un clic est tombé à côté d'une tâche.
- Sans cadres → impossible de savoir où ouvrir le trou d'insertion.

Une fois ① fait, il ne reste qu'à brancher ce qui **existe déjà et est testé** :

| Brique | Où | État |
|---|---|---|
| `LeftClickOutsideObserver` | `Views/AppKitBridges.swift` | prêt, utilisé par `ListPageView` |
| `ReorderLayout` / `ReorderTarget` | `Models/Reorder.swift` | prêt, **21 tests** |
| `TaskFocus` | `Models/TaskFocus.swift` | prêt, **17 tests** |

### Puis : `TaskItem.smartOrder`

Décision produit **déjà prise** par le propriétaire : *sur les vues intelligentes, l'ordre manuel
prend le dessus* (comportement de Things — on planifie sa journée en glissant).

`sortIndex` **ne peut pas servir** : il est attribué PAR LISTE (`list.orderedTasks.last?.sortIndex + 1`,
et le réordonnancement réécrit 0…n dans la liste). Sur « Aujourd'hui », les tâches viennent de listes
différentes — deux d'entre elles peuvent porter le même `sortIndex`. **Elles ne sont pas
comparables.**

Il faut donc un second champ d'ordre sur `TaskItem`. C'est un ajout **additif** : SwiftData l'absorbe
seul, `SchemaCompatibilityTests` reste vert, et `StoreBackup` prendra une copie de la base au premier
lancement. Les garde-fous sont en place, c'est le cas facile — mais **relire la marche à suivre en
tête de `Models/TodaySchema.swift` avant de toucher au modèle.**

`SmartList.sort` cesse alors de trier par priorité/date : ce tri ne sert plus qu'à **placer une tâche
qui arrive** sur la page.

---

## ③ Aucun test ne couvre une vue

122 tests, tous sur des modèles et services. **Zéro sur une page.** Une page peut perdre ⌫ sans
qu'aucun test ne rougisse — c'est arrivé, et c'est ce qui a imposé plusieurs allers-retours de
vérification manuelle avec l'utilisateur.

Il ne s'agit pas de tester des pixels, mais des questions que ① rend enfin adressables : *quelles
lignes cette page présente-t-elle, dans quel ordre, après tel filtre ?*

---

## ⚠️ Points ouverts à vérifier AVANT d'étendre quoi que ce soit

1. **⌘Z n'est pas vérifié.** `container.mainContext.undoManager = UndoManager()` est posé dans
   `ThingsCloneApp.swift`. Que le menu *Édition ▸ Annuler* l'atteigne dépend de la chaîne de
   répondeurs SwiftUI et **n'a jamais été testé**. Or ⌫ agit désormais sur trois pages **sans
   filet** — une suppression est définitive, il n'y a pas de corbeille. À prouver en priorité.
2. **⌫ sur « Tâches »** : signalé non fonctionnel. Diagnostiquer avant de corriger.

---

## Déjà essayé et REJETÉ — ne pas refaire

- **Un fond transparent (`.background { Color.clear … onTapGesture }`) pour attraper le clic dans le
  vide.** Essayé deux fois, rejeté deux fois. Un `ScrollView` capte les clics de toute sa surface, et
  un fond de contenu ne couvre de toute façon ni les marges (`gutter`) ni le vide sous la dernière
  ligne. C'était **déjà documenté** dans l'en-tête de `LeftClickOutsideObserver` avant d'être refait.
  La seule réponse qui marche est celle de `ListPageView` : moniteur `NSEvent` + cadres des lignes.
- **Faire taire les 37 diagnostics de chemins de clé** en marquant les `@Model` `@unchecked Sendable`.
  Ce serait un mensonge (ce sont des classes mutables) et le rafistolage que le projet refuse. Trou
  entre SwiftData et Swift 6, à laisser tel quel.
- **Le curseur « main » sur toute la ligne.** Sur macOS, la main signale un bouton ou un lien, jamais
  une ligne sélectionnable (Finder, Mail, Rappels gardent la flèche). Le comportement actuel — main
  sur la case à cocher seulement — est **correct**. Si un repère de survol manque, la bonne réponse
  est un fond de survol, pas un changement de curseur.

---

## Invariants à ne pas casser

- **`swift test` : 122 tests, tous verts.**
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
| Filtrer le bruit des 37 diagnostics dans `Scripts/quick.sh` | Proposé, non fait. Noyé dans 300 lignes, un VRAI nouveau warning passerait inaperçu — ce qui annule l'intérêt du cliquet. |

---

## Ordre recommandé

1. Vérifier **⌘Z** (5 min, côté utilisateur). Il conditionne la prudence de la suite.
2. **①** les lignes se déclarent en se rendant → supprime la closure `rows`, fournit les cadres.
3. **②** clic dans le vide, puis `smartOrder`, puis le glisser.
4. Sélection sur **« À venir »** et **« Archives »** — le tableau du haut devient vrai.
5. **③** les premiers tests de page.

**1 à 3 forment un bloc indivisible.** Ils ont été découpés en tranches une fois : chaque tranche
livrée seule était invérifiable, et il a fallu trois allers-retours pour rien. Les faire d'une traite,
en montrant chaque étape.
