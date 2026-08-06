# Things Clone — Roadmap

## Pitch
Clone natif macOS de [Things](https://culturedcode.com/things/) (Cultured Code), gratuit pour usage perso puis commercialisé en lifetime ~9,99$ (vs 50$ pour Things). Cloner le *concept* et l'UX (légal), pas le code/design/logo (à éviter).

## Découpage en sous-projets (specs séparées)

1. **Core MVP (en cours de brainstorm)** — app Mac locale, mono-appareil, sans sync ni paiement
2. **Sync multi-appareils** — CloudKit (à spécifier après le MVP)
3. **Multi-plateforme** — iOS/iPadOS (après le MVP, pas encore scopé)
4. **Monétisation** — StoreKit, achat lifetime (après le MVP)
5. **Extras post-MVP** — Pomodoro intégré + autres idées à venir de l'utilisateur

## Scope du Core MVP (décisions actées)

### Fonctionnel
- Fidélité complète avec Things côté organisation : **Projets + Zones (Areas) + Tags**
- Vues : Inbox (À classer), Aujourd'hui, À venir, À tout moment, Un jour, Logbook/Archive, Corbeille
- Sous-tâches / checklist items dans une tâche
- **Quick Entry global** dès le v1 (raccourci clavier depuis n'importe quelle app, agent menu bar en arrière-plan, permissions Accessibilité macOS)
- Tâches récurrentes (jours/semaines/mois/années)
- Dates en langage naturel dans le champ de saisie ("lundi prochain", "dans 3 jours")
- Notifications macOS à heure précise pour les tâches

### Différé après le MVP
- Pomodoro intégré
- Sync CloudKit
- iOS/iPadOS
- Monétisation / StoreKit
- (autres features à définir par l'utilisateur)

### Fait le 6 août 2026 — glisser une tâche vers la SIDEBAR

Répartir l'inbox sans passer par clic droit ▸ *Déplacer vers…*. On tire une tâche depuis n'importe
quelle page qui glisse, on la lâche sur une **liste** de la barre latérale, elle y est rattachée.

La sidebar plutôt qu'un glisser entre les sections de « Tâches », et c'était un choix, pas un repli :
la cible ne défile pas, elle liste toutes les destinations, et n'a aucun trou à calculer. Le glisser
entre sections a été essayé et retiré (cf. `CLAUDE.md`).

**Seules les LISTES rangent.** Une ligne de projet est survolable mais n'accueille rien : la
survoler la DÉPLIE, pour révéler ses listes. Choisir sa première liste à la place de l'utilisateur
aurait été une devinette, et un projet vide n'aurait rien eu à offrir.

L'obstacle annoncé — la ligne rognée au bord de la page — s'est réglé sans détacher quoi que ce
soit : la rangée publie son cadre par une `PreferenceKey`, la fenêtre dessine une pilule par-dessus
les deux colonnes, et un seul booléen (`SidebarDrop.isAirborne`) décide laquelle des deux on voit.
Le moteur de réordonnancement n'a pas bougé.

Reste ouvert : ⌘Z sur un rangement remet la tâche en place **sans animation** — le déclencheur du
socle (`TaskPageBase`, `carriedRowCount`) ne voit pas une tâche qui change de section, seulement une
qui entre ou sort. Vrai depuis toujours pour *Déplacer vers…*, juste plus visible maintenant.

## Architecture technique (décisions actées)

- **UI** : SwiftUI (macOS 14+), AppKit ponctuel si besoin de comportements fins (ex: NSTextView, drag & drop avancé)
- **Persistance** : **SwiftData** (recommandé sur GRDB/Core Data — natif SwiftUI, migrations auto, garde la porte ouverte pour CloudKit plus tard sans réécriture)
- **Structure app** : fenêtre principale + agent léger menu bar (Quick Entry + notifications, actif même app fermée)

### Modèle de données (draft)

- `Task` — titre, notes, statut, `when` (date planifiée), `deadline`, ordre, projet/zone optionnels, tags, checklist items, règle de récurrence optionnelle
- `Project` — titre, notes, zone optionnelle, statut actif/terminé, tâches ordonnées
- `Area` — titre, contient projets + tâches libres
- `Tag` — nom, couleur, many-to-many avec `Task`
- `ChecklistItem` — titre, statut, appartient à une `Task`
- `RecurrenceRule` — fréquence, intervalle, jours de semaine

### Vues dérivées (requêtes calculées, pas des tables)
- Inbox = tâches sans projet/zone/date
- Aujourd'hui = `when == today` ou en retard et non complétée
- À venir = `when > today`, groupées par date
- À tout moment = actives sans date mais rattachées à un projet/zone
- Un jour = marquées "someday" sans date
- Logbook = complétées
- Corbeille = soft-delete + purge différée

## État du brainstorm — reprendre ici

Design validé : **Section 1 (architecture + modèle de données)** et **Section 2 (vues/UI + logique de planification)**.

À la demande de l'utilisateur, on a court-circuité la suite du process `brainstorming` (spec écrit formellement + `writing-plans`) pour livrer directement un premier squelette testable — objectif d'apprentissage Swift/SwiftUI en marche (voir mémoire `user_learning_swift`).

Reste à faire à la reprise :
- Section 3 — Mécanisme Quick Entry (agent menu bar, permissions Accessibilité) + stratégie de tests
- `ChecklistItem` et `RecurrenceRule` : pas encore dans le modèle de données (skippés pour le premier squelette)
- Flag "Un jour" (someday) explicite sur `TaskItem` : pas encore modélisé, la vue Someday est vide pour l'instant
- Notifications, parsing NLP des dates, récurrence : pas encore implémentés
- Sync CloudKit / iOS / StoreKit : toujours différés (voir sous-projets ci-dessus)

## Squelette v0 (implémenté)

Projet Swift Package (pas encore un vrai `.xcodeproj`) dans ce dossier :
- `Package.swift` — cible exécutable macOS 14+, SwiftUI + SwiftData
- `Sources/ThingsClone/Models/` — `TaskItem`, `Project`, `Area`, `Tag` (SwiftData `@Model`)
- `Sources/ThingsClone/Views/` — `ContentView` (NavigationSplitView), `SidebarView`, `TaskListView`, `TaskRowView`

Fonctionne : sidebar avec listes système + projets/zones, ajout de tâche, complétion, filtrage Inbox/Aujourd'hui/À venir/À tout moment/Logbook (filtrage en mémoire, pas encore par `#Predicate`).

Pour tester : `swift run` dans ce dossier, ou `open Package.swift` pour ouvrir dans Xcode.
