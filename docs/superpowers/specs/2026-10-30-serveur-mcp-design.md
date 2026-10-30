# Serveur MCP de Today — design

_30 octobre 2026. Statut : en attente de validation._

## Pourquoi

L'utilisateur suit l'avancement de ses projets de code (ex. « Monflix », un Netflix maison) dans
des fichiers de roadmap que Claude Code tient à jour pendant qu'il code. Pour voir où il en est, il
doit ouvrir l'éditeur. Today centralise déjà tous ses projets : il veut que l'avancement y arrive
aussi, envoyé par Claude Code, sans quitter l'app.

Ses mots : « que Today ait un MCP à lui », et c'est lui qui dit à Claude, projet par projet,
« synchronise ça avec Today ». Claude crée alors le projet (« Monflix »), ses listes, ses tâches et
sous-tâches, puis les fait avancer au fil de la conversation.

Succès : dans une session Claude Code, « synchronise la roadmap avec Today » fait apparaître ou
mettre à jour le projet dans Today, sans doublon, et ce qu'on coche d'un côté peut être relu de
l'autre.

## Objectifs

1. Today expose un serveur MCP que Claude Code branche en une commande (`claude mcp add …`).
2. Claude peut lire l'état des projets (listes, tâches, sous-tâches, ce qui est coché).
3. Claude peut créer projet, liste, tâche, sous-tâche ; renommer ; modifier les notes ; cocher et
   décocher.
4. Claude peut supprimer, **uniquement sur demande explicite de l'utilisateur** (cf. Décisions).
5. Ce qui arrive par le MCP apparaît en direct dans l'app et suit tous les chemins habituels
   (synchro Rappels comprise).

## Non-objectifs

- **Today ne connaît aucun fichier.** Pas de lien projet ↔ `.md`, pas de surveillance de fichier,
  pas d'analyse de markdown. La correspondance roadmap ↔ Today est l'affaire de Claude, côté CLI.
- Pas de synchro automatique ni en continu : rien ne part tant que l'utilisateur ne l'a pas demandé
  à Claude.
- Pas d'outils au-delà de la hiérarchie Projet → Liste → Tâche → Sous-tâche : dates, durées,
  priorités, en-têtes de section, archivage, réordonnancement, Pomodoro, Aujourd'hui. Chacun
  s'ajoutera le jour où un vrai usage le réclame.
- Pas d'accès distant : le serveur n'écoute que la machine locale.
- Today n'a pas à se lancer tout seul : app fermée ⇒ le MCP est indisponible, Claude le dit.

## Anti-objectifs (raté même si ça marche)

- Claude **supprime quelque chose que l'utilisateur n'a pas demandé** de supprimer.
- Relancer une synchro **duplique** le projet ou ses tâches.
- Un site web ouvert dans le navigateur, ou n'importe quel process local sans la clé, peut écrire
  dans la base.
- Une requête MCP fait **saccader l'interface** ou bloque le fil principal.
- Un bug du serveur fait **tomber l'app** du quotidien.

## Contraintes (celles du projet, `CLAUDE.md`)

- **Aucun changement de schéma.** Les quatre modèles portent déjà un `uuid` stable : c'est
  l'identifiant exposé. Pas de champ « source externe ».
- **Natif d'abord** : `Network.framework` (`NWListener`) pour le HTTP, `JSONSerialization` /
  `Codable` pour le JSON-RPC. Aucune dépendance ajoutée.
- **Le fil principal ne fait que les écritures SwiftData** (même `mainContext` que l'interface, sinon
  l'app ne voit pas les changements). Réseau, analyse et encodage JSON hors du fil principal.
- **La logique sort de la vue et est testée** : la répartition JSON-RPC et chaque outil vivent dans
  `Models/`, testés sur un conteneur en mémoire.
- **Ce qui s'installe se démonte** : le listener s'arrête quand on désactive l'intégration et à la
  fermeture de l'app.
- **Suppressions** : un objet supprimé par le MCP n'a peut-être jamais été rendu (une tâche
  emporte des sous-tâches jamais lues). Donc **`deleteCascadeAndSave` pour les QUATRE types**,
  tâche comprise, et pas `deleteTasksAndSave`, qui suppose une ligne déjà rendue (cf. l'en-tête des
  deux helpers). Identifiants Apple lus AVANT, `forgetAppleItems` APRÈS un enregistrement réussi,
  sinon `runAfterNextSave`.
  La suppression d'un projet vit aujourd'hui en privé dans `SidebarView` (rappels + couverture
  `covers.remove(for:)` + sélection). Elle sort dans une fonction partagée, appelée par la sidebar
  ET par le MCP : sinon un projet supprimé par Claude laisserait sa couverture sur le disque.
- **La sélection de la sidebar est un `@State` de vue**, hors de portée du MCP. Supprimer la liste
  ou le projet affiché ne doit pas laisser la fenêtre pointer sur un objet effacé : la vue racine
  retombe sur « Tâches » quand sa sélection désigne un objet supprimé (`isDeleted` ou
  `modelContext == nil`). Ce garde-fou vaut pour toute suppression hors de la sidebar.
- **`RemindersService` n'est pas un singleton** : c'est un `@State` de `ThingsCloneApp`. Le serveur
  est donc créé là, et reçoit le service, le stockage des couvertures et le conteneur.
- **`TodayDev` et `Today` tournent côte à côte** : ports et clés distincts par bundle.

## Décisions de l'utilisateur

- Le MCP est **hébergé par Today**, pas par un outil à côté.
- **Opt-in par l'utilisateur** : c'est lui qui demande à Claude de synchroniser, au cas par cas.
- **Suppression autorisée seulement sur demande explicite de l'utilisateur**, jamais par choix de
  Claude.

## Conception

### Transport

MCP en **Streamable HTTP**, réduit au strict nécessaire : `POST /mcp`, corps JSON-RPC 2.0, réponse
`application/json` (pas de flux SSE, aucun outil n'en a besoin). `GET /mcp` → 405. Méthodes
gérées : `initialize`, `notifications/initialized` (202, pas de corps), `ping`, `tools/list`,
`tools/call`. Toute autre méthode → erreur JSON-RPC `-32601`. Version de protocole : on renvoie
celle que le client propose (aucune fonction dépendante de la version n'est utilisée).

Branchement côté utilisateur, une fois :

```bash
claude mcp add --transport http --scope user today http://127.0.0.1:<port>/mcp \
  --header "Authorization: Bearer <clé>"
```

### Sécurité (frontière de confiance)

- Écoute sur **127.0.0.1 uniquement**.
- **Clé** de 32 octets aléatoires, générée à la première activation, comparée en temps constant.
  Requête sans clé valide → 401.
- **Toute requête portant un en-tête `Origin` est refusée** (403) : Claude Code n'en envoie pas, un
  navigateur toujours. Ça ferme la porte au DNS rebinding.
- Corps limité à 1 Mo ; une requête à la fois suffit.
- Clé dans les `UserDefaults` du bundle. // ponytail : le Trousseau n'ajouterait rien, un process
  qui tourne sous le même utilisateur lit de toute façon la base SQLite directement.

### Réglages

Section « Claude Code » dans les Réglages :
- bascule **« Autoriser Claude Code à modifier Today »**, **éteinte par défaut** (un port qui
  écoute est un choix, pas un cadeau) ;
- la commande `claude mcp add …` prête à copier (bouton « Copier ») ;
- « Régénérer la clé ».

Port fixe par bundle (une constante pour `Today`, une autre pour `TodayDev`). Port déjà pris → la
section le dit, rien ne plante.

### Outils exposés

Identifiants = `uuid` des modèles, en chaîne. Toute référence inconnue → résultat d'outil en erreur
(`isError: true`) avec un message lisible, jamais une exception.

| Outil | Entrée | Effet / sortie |
|---|---|---|
| `list_projects` | — | projets dans l'ordre de la sidebar : `id`, `title`, `done`/`total`, et leurs listes (`id`, `title`, `archived`, `done`/`total`). Inclut la boîte de réception. |
| `get_project` | `project_id` | l'arbre complet : listes → tâches (`id`, `title`, `completed`, `notes` en texte brut) → sous-tâches (`id`, `title`, `done`), dans l'ordre manuel. Les en-têtes de section apparaissent avec `is_header: true`. |
| `create_project` | `title`, `notes?` | crée en fin de sidebar. **Un projet de même titre existe déjà → le renvoie sans rien créer** (`created: false`). |
| `create_list` | `project_id`, `title` | via `Project.appendList`. Même règle d'idempotence par titre dans le projet. |
| `create_task` | `list_id`, `title`, `notes?`, `subtasks?: [String]`, `completed?` | tâche en fin de liste, sous-tâches dans l'ordre donné. Même titre déjà présent dans la liste → renvoyée telle quelle (`created: false`). |
| `add_subtask` | `task_id`, `title` | en fin. Idempotent par titre dans la tâche. |
| `update_item` | `id`, `title?`, `notes?`, `completed?` | trouve l'objet parmi les quatre types par son `uuid`. `completed` ne vaut que pour tâche et sous-tâche (tâche : même effet que `toggleCompletion`, `completedAt` compris). |
| `delete_item` | `id` | supprime (cascade pour projet et liste). Voir ci-dessous. |

Les descriptions des outils portent la convention d'usage, que Today n'impose pas : une phase de
roadmap = une liste, une ligne = une tâche, un sous-point = une sous-tâche ; appeler `get_project`
avant de synchroniser ; garder les `id` renvoyés.

**`delete_item`** est un outil séparé, avec l'annotation MCP `destructiveHint: true` et une
description qui dit : « uniquement quand l'utilisateur l'a demandé explicitement dans la
conversation ; jamais pour nettoyer, dédoublonner ou réorganiser de sa propre initiative ». La
garantie réelle vient de Claude Code : chaque appel d'outil MCP non autorisé à l'avance passe par
sa fenêtre de confirmation. La documentation des Réglages dit de **ne jamais** mettre `delete_item`
en « toujours autoriser ».

Les notes arrivent en texte brut et s'écrivent via `NotesCodec.encode(NSAttributedString(string:))` ;
elles se relisent via `NotesCodec.plainText`.

### Fils

`NWListener` sur une file à lui. Une requête complète est décodée hors du fil principal, l'appel
d'outil saute sur `MainActor` (écriture sur `ModelContainer.mainContext`, enregistrement immédiat
par `saveReportingSuccess`), le résultat revient en valeur `Sendable` et s'encode hors du fil
principal. Les objets `@Model` ne traversent jamais la frontière.

Les changements arrivent sans transaction animée : une liste créée par Claude apparaît, elle ne
glisse pas. C'est voulu (aucune page n'est à l'origine du geste).

### Fichiers

- `Services/MCPServer.swift` : listener, HTTP minimal (ligne de requête, en-têtes,
  `Content-Length`), clé, `Origin`, cycle de vie.
- `Models/MCPTools.swift` : répartition JSON-RPC, catalogue des outils, et chaque outil comme
  fonction `(arguments, ModelContext) -> résultat`. Sans réseau, sans SwiftUI.
- Section des Réglages.
- `Tests/TodayTests/MCPToolsTests.swift` : idempotence par titre, résolution d'`id`, cocher,
  suppression en cascade, erreurs sur `id` inconnu, `initialize` / `tools/list` bien formés.
- `Tests/TodayTests/MCPServerTests.swift` : analyse HTTP, refus sans clé, refus avec `Origin`.

### Vérification

Sur `TodayDev` : activer, brancher Claude Code sur le port de dev, lui faire créer un projet de
test avec deux listes et des sous-tâches, cocher une tâche dans l'app, demander à Claude de relire,
puis supprimer le projet sur demande (la confirmation de Claude Code doit apparaître). Regarder dans
les deux thèmes la section des Réglages.

## Laissé au builder

- Valeurs des deux ports, libellés exacts des Réglages.
- Forme exacte des schémas JSON des outils et des messages d'erreur.
- Comparaison des titres pour l'idempotence (je suggère : espaces de bord retirés, insensible à la
  casse).
