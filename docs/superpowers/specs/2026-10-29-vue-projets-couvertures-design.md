# Vue « Projets » et couvertures de projet — design

_29 octobre 2026. Statut : validé et livré le 30 octobre 2026._

## Pourquoi

L'utilisateur retourne sur Notion pour piloter ses projets. Today sait ranger (sidebar, page d'un
projet en cartes de listes) mais n'a **aucun endroit qui montre tous les projets à la fois** : pour
savoir où en est chacun, il faut ouvrir les dossiers un par un. Ce qui manque, dans ses mots :
« un onglet qui permet de tout afficher en même temps pour voir la progression de tous les projets
réunis », « l'ensemble des tâches et de l'avancement en un clic ». Et une **image par projet**, comme
Notion, stockée en local, pour donner du « peps » à l'app.

Succès : ouvrir « Projets » répond en un coup d'œil à « où en est chaque projet, et lequel
avance ? », sans ouvrir de dossier — et Notion n'a plus de raison d'être ouvert pour ça.

## Objectifs

1. Une destination **« Projets »** dans la sidebar : une grille de cartes, une par projet, dans
   l'ordre de la sidebar.
2. Chaque carte montre : la couverture (ou, à défaut, un bandeau à la teinte du projet), le titre,
   l'**avancement cumulé** (barre + « 18 / 25 »), et ses listes en cours avec leur propre
   avancement (une ligne par liste : nom + mini-barre + compte).
3. Clic sur la carte → page du projet. Clic sur une ligne de liste → page de la liste.
4. Une **couverture par projet** : choisie par fichier (bouton) ou déposée depuis le Finder, affichée
   en bandeau en tête de la page du projet et en tête de sa carte dans la vue Projets. Retirable.

## Non-objectifs

- Éditer depuis la vue Projets (renommer, créer, cocher). C'est une vitrine, comme les cartes de la
  page projet : le travail se fait dans la liste.
- Réordonner les projets depuis la vue Projets — la sidebar le fait déjà.
- Galerie d'images fournie, recadrage, repositionnement vertical de l'image (Notion le fait ; à
  ajouter si le cadrage par défaut déçoit à l'usage).
- Échéances, tags, statut de projet, vue tableau/calendrier « à la Notion ». Rien de tout ça n'est
  demandé.
- Les listes hors projet et l'Inbox : ce ne sont pas des projets, elles n'apparaissent pas.

## Anti-objectifs (échec même si « ça marche »)

- La vue Projets saccade à l'ouverture ou ralentit les autres pages. Elle ne doit rien coûter tant
  qu'elle n'est pas affichée.
- Décoder une image sur le fil principal, ou relire un fichier d'image à chaque rendu.
- Un changement de schéma SwiftData pour stocker des octets décoratifs sur la vraie base.
- Deux chiffres d'« avancement » qui se contredisent sans qu'on comprenne pourquoi (cf. § La règle
  d'avancement).
- Un popover ou un `.fileImporter` présenté depuis la fenêtre principale (→ `PIEGES.md` § Fenêtres :
  ça tue le process).

## Architecture

### 1. La destination

`SidebarSelection` gagne `case projects` — à côté de `case pomodoro`, **pas** dans `SmartList` :
`SmartList` filtre et trie des TÂCHES (`scopeMatches`, `filter`, `sort`), une vue de projets n'y a
aucune branche sensée. Le compilateur liste chaque `switch` à compléter (`tint`, `TaskListView.page`,
`ContentView.recordRecent`, etc.).

- Sidebar : une rangée « Projets » (`square.grid.2x2.fill`) dans le groupe du haut, après
  « Archives », avant « Pomodoro ».
- Menu « Aller » : « Projets », **⌘6**. Pomodoro garde ⌘5 — on ne déplace pas un raccourci déjà
  appris.
- Teinte : `PageTint.projects`, via `dualColor(light:dark:)`, distincte des cinq existantes (un bleu
  franc — à valider à l'œil dans les deux thèmes).

### 2. Ce que la page présente : `Models/ProjectsOverview.swift`

Type de valeur, sans SwiftUI, testé — même raison d'être que `ProjectBoard` et `TodayPage` :

```swift
struct ProjectsOverview {
  struct Card: Identifiable {
    let project: Project
    let uuid: UUID                       // clé de la couverture, lue UNE fois
    let total: SidebarCounts.Row         // tout le projet, listes archivées comprises
    let lists: [(list: TodoList, row: SidebarCounts.Row)]  // listes EN COURS, ordre manuel
  }
  let cards: [Card]
  static func build(projects: [Project], counts: SidebarCounts) -> ProjectsOverview
}
```

**Aucun nouveau comptage.** `SidebarCounts(tasks:bounds:)` fait déjà la passe unique par liste ;
avec `DayBounds(progressResetsDaily: false)` il rend exactement les comptes cumulés. `build`
n'additionne que les `Row` des listes de chaque projet (quelques dizaines de lectures de relation,
pas une par tâche). `Row` gagne au besoin un `+` — rien d'autre.

La page (`Views/TaskList/ProjectsPageView.swift`) porte `@Query` sur `Project` (trié comme la
sidebar) et sur `TaskItem` (table entière, comme `SidebarTally` — mesuré le 8 octobre : un `@Query`
bat la traversée des relations), construit `SidebarCounts` puis `ProjectsOverview` **une fois en
tête de `body`**, et distribue. Montée seulement quand elle est sélectionnée (branche du `switch` de
`TaskListView`) : zéro coût ailleurs.

Grille : `LazyVGrid` adaptative, même colonnes et même entrée de cartes (`enteringCard`,
`cardEntrance`) que `ProjectPageView`. `LazyVGrid` est permis ici : la page ne se réordonne pas au
doigt (la règle du § 1 de `CLAUDE.md` ne vise que les pages qui glissent).

Une liste affichée sur la carte : au plus 5, puis « + N autres » ; la carte est une vitrine, pas un
inventaire (la leçon de « Tâches », § Déjà rejeté n° 10).

### 3. La règle d'avancement — LA décision à valider

L'anneau d'une liste se remet à zéro chaque jour par défaut (`progressRingResetsDaily`, PIEGES
§ L'anneau) : il mesure l'élan du JOUR. Sur une vue de projets, cette règle afficherait **tous les
projets à ~0 % chaque matin** — l'inverse de ce qui est demandé.

Proposition : la vue Projets montre l'**avancement cumulé** (faites / total, depuis toujours,
listes archivées comprises, en-têtes exclues) — c'est la « deuxième version » de PIEGES, que ce
même récit dit juste « pour une liste qu'on termine une fois », et un projet est exactement ça.

Pour qu'il ne contredise pas l'anneau :
- il s'affiche en **barre + « 18 / 25 »**, jamais en anneau — forme différente, quantité différente ;
- la même barre apparaît sous le titre de la page du projet, qui PERD son anneau (remplacé par le
  dossier du projet, 30 octobre 2026 : deux jauges superposées se lisaient comme une contradiction) ;
- les anneaux des listes, de la sidebar et de la page projet gardent leur règle du jour, inchangée.

### 4. Les couvertures : `Services/ProjectCovers.swift`

**Des fichiers, pas un champ SwiftData.** `~/Library/Application Support/<StoreLocation.directoryName>/Covers/<project.uuid>.jpg`.

Pourquoi pas `@Attribute(.externalStorage) var cover: Data?` sur `Project` :
- montée de schéma 8.0.0 + étape + empreintes, sur une base qui porte de la vraie donnée, pour un
  octet décoratif ;
- SwiftData range ces blobs dans un dossier caché à côté du store, que `StoreBackup`,
  `StoreQuarantine` et `StoreLocation.companionSuffixes` ignorent — une sauvegarde ou une quarantaine
  perdrait les images sans un mot, et il faudrait apprendre ce dossier aux trois ;
- lire l'attribut depuis une vue est une lecture de fichier synchrone, sur le fil qui dessine.

Les fichiers donnent gratuitement : aucune migration, l'isolation dev/prod (`TODAY_APP_SUPPORT_DIR`
→ `directoryName`), et une clé déjà stable (`Project.uuid`, présent depuis le schéma 4).

`// ponytail:` hors `StoreBackup` et hors synchro — une image perdue se re-choisit. Le jour où
CloudKit arrive, migrer vers un attribut `externalStorage` (le modèle est déjà prêt pour CloudKit).

Le service, `@Observable`, injecté par `.environment` dans la fenêtre principale (comme
`RemindersService`) :

- `stamps: [UUID: Date]` — quels projets ont une couverture, et sa version (date de
  modification). Rempli UNE fois au lancement par un listage du dossier ; c'est la seule chose
  qu'une vue lit pendant un rendu. Pas de fichier → bandeau de couleur, sans toucher au disque.
- `set(from url: URL, for uuid: UUID) async` — **hors fil principal** : lecture, réduction à
  2 000 px de large max (ImageIO `CGImageSourceCreateThumbnailAtIndex`), JPEG qualité 0,85, écriture
  atomique ; puis, sur le fil principal, mise à jour de `stamps`. Refuse ce qui ne se décode pas.
- `remove(for uuid: UUID)` — efface le fichier, retire la clé.
- `image(for uuid: UUID, maxPixelWidth: Int) async -> CGImage?` — décodage **hors fil principal**,
  réduit à la taille d'affichage (×2 Retina), avec `kCGImageSourceShouldCacheImmediately` pour que le
  décodage se fasse là et pas au premier dessin. Cache `NSCache` clé `(uuid, stamp, largeur)`.

La vue `ProjectCoverView(uuid:stamp:tint:height:)` : `.task(id: stamp)` charge l'image dans un
`@State`, le bandeau de couleur s'affiche d'ici là, l'image arrive en fondu court (`timingCurve`,
pas de `spring`). `Image(decorative:scale:)`, `.resizable().scaledToFill()`, cadre explicite,
`.clipped()`. Aucun `.blur` sur l'image.

**Choisir / retirer** — en tête de la page du projet, au survol du bandeau : « Changer la
couverture… » et « Retirer ». Le choix passe par `NSOpenPanel` lancé depuis l'**action** du bouton
(même chemin que `OnboardingView.choosePhoto`, et pour la même raison) ; un projet sans couverture
montre « Ajouter une couverture » au survol de l'en-tête. **Déposer** une image depuis le Finder
sur le bandeau : `.dropDestination(for: URL.self)`, filtré sur les types image.

**Supprimer un projet** efface sa couverture, dans l'unique chemin qui supprime un projet
(`SidebarView.delete(_ project:)`), APRÈS l'enregistrement SwiftData — même ordre qu'EventKit.

### 5. Ce qui change sur la page d'un projet

- Bandeau de couverture en tête, **bord à bord de la colonne de détail** (il ignore `gutter`, le
  titre reste dans la colonne), hauteur fixe ~160 pt, titre et anneau dessous, comme Notion. Sans
  couverture : rien de plus qu'aujourd'hui, sauf l'invite au survol. 2 000 px de large stockés
  couvrent une colonne de 1 000 pt en Retina — au-delà, l'image est légèrement agrandie, accepté.
- La barre d'avancement cumulé sous le titre (cf. § 3). **Même source que la carte** : la page n'a
  pas de `@Query` de tâches, elle construit `SidebarCounts(tasks: project.allTasks,
  bounds: DayBounds(progressResetsDaily: false))` et le même total que `ProjectsOverview` (une
  fonction partagée, pas une seconde somme écrite à la main). Une passe de plus sur les tâches du
  seul projet affiché.
- « Projets » n'entre pas dans `QuickFind` : la recherche trouve des listes et des tâches, la vue
  s'atteint par la sidebar et ⌘6.

## Tests

- `ProjectsOverviewTests` : agrégation (archivées comptées dans le total, absentes de `lists`),
  ordre des cartes = ordre de la sidebar, projet vide (0 / 0 → barre vide, pas `nan`), en-têtes
  exclues, indépendance vis-à-vis du réglage `progressRingResetsDaily`.
- `ProjectCoversTests` sur un dossier temporaire : `set` réduit et écrit, `stamps` suit, `remove`
  efface, un fichier non-image est refusé, un `stamp` change quand on remplace l'image.
- Aucun test de schéma ne bouge — c'est le signe que le choix des fichiers tient.

## Vérification

- Regarder la vue et le bandeau dans les deux thèmes via `./run-dev.sh` (état forcé par variable
  d'environnement, capture par id de fenêtre — cf. la mémoire « vérification visuelle sans souris »).
- Mesurer l'ouverture de la vue Projets avec une dizaine de projets couverts : aucun décodage sur le
  fil principal au `sample`.
- Restent à l'humain : le dépôt depuis le Finder, le survol du bandeau, le ressenti du fondu.

## Laissé au constructeur

Dimensions exactes des cartes et du bandeau, texte des invites, icônes, hauteur de la barre, ordre
des éléments dans la carte, et l'emplacement exact des fichiers neufs dans `Views/`.

## Décisions prises par Claude (à relire)

- `case projects` dans `SidebarSelection`, pas dans `SmartList`.
- Rangée EN TÊTE de la sidebar (demandé le 30 octobre), raccourci ⌘6, teinte bleue.
- Fil d'Ariane « Projets › Projet › Liste » sur la page d'une liste rangée et sur celle d'un projet.
- Couvertures en fichiers et non en SwiftData ; hors sauvegarde.
- Au plus 5 listes par carte.
- Pas de repositionnement de l'image, pas de galerie.
