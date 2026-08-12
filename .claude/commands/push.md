---
description: Contrôle complet du travail en cours (conventions CLAUDE.md, robustesse, perf, stabilité) puis publication d'une nouvelle version
argument-hint: [message de mise à jour] [version]
allowed-tools: Bash, Read, Edit, Grep, Glob
---

Contrôler le travail en cours, puis le publier. **Un seul point rouge et on ne publie pas** — on
corrige, ou on dit pourquoi c'est hors sujet. Une release est visible par les utilisateurs de l'app
et ne se rattrape pas.

Arguments : `$1` = message de mise à jour (optionnel), `$2` = version forcée (optionnel).

## 1. Ce qui va partir

`git status --short` puis `git diff HEAD`. **Lire le diff en entier** — c'est lui qu'on contrôle,
pas une idée de ce qu'on a fait. Rien à publier → le dire et s'arrêter là.

Noter la liste des fichiers touchés : elle décide des sections applicables ci-dessous.

## 2. Les cliquets automatiques — bloquants, dans cet ordre

0. `pgrep -fl "Today.app/Contents/MacOS"`. **`make-app.sh` refuse de reconstruire sous les pieds
   d'une instance vivante** (→ `PIEGES.md` § Fenêtres), et il le découvre APRÈS le bump de version —
   tout est restauré, mais on a payé le build pour rien. Une instance tourne ⇒ le dire tout de
   suite et demander à l'utilisateur de la fermer. **Ne jamais la tuer soi-même** : c'est l'app
   qu'il utilise pour de vrai, distincte de `TodayDev`.
1. `xcrun swift-format -i -r Sources Tests`, puis `git status --short`. Si un fichier **hors** de la
   liste de l'étape 1 a bougé, le rendre (`git checkout -- <fichier>`) : le formateur dérive sur du
   code qu'on n'a pas touché, et ça pollue le diff de la release.
2. `find Sources Tests -name '*.swift' -exec touch {} +` puis `swift build -c release 2>&1 | grep "warning:"`.
   **Un build incrémental n'a rien vérifié** (mesuré : 0 avertissement contre 40). Le cliquet porte
   sur la NATURE, pas le nombre : tout avertissement qui n'est pas un chemin de clé `Sendable` est
   une régression d'isolation à corriger sur-le-champ.
3. `swift test` — vert, `SchemaFingerprintTests` et `StoreFixtureTests` compris. **Ne jamais recopier
   une empreinte de schéma pour faire taire un test.**

## 3. La revue — confronter le diff à `CLAUDE.md`

Chercher chaque point DANS le diff. Ne pas déclarer « OK » ce qu'on n'a pas cherché.

**Rouge — on ne publie pas :**
- forme d'un `@Model` changée (ajout compris) sans montée de version ET étape de migration, ou
  migration jamais rejouée à blanc sur une copie de la vraie base ;
- `LazyVStack` sur une page qui se réordonne au doigt ;
- un popover, ou une palette/sélecteur présenté depuis le layout ;
- un premier répondeur dans une fenêtre qu'on n'affichera pas ;
- un appel synchrone à un service système (EventKit…) depuis une vue ;
- une suppression hors du chemin d'affichage sans `deleteCascadeAndSave` ;
- une `Color(red:…)` nue — une couleur figée se double (`NSColor(name:)`).

**À corriger avant de publier :**
- propriété calculée d'un `@Model` (`progress`, `remainingCount`, `orderedTasks`…) lue depuis une
  rangée au lieu d'être calculée une fois en tête du `body` ;
- un tri sur un `@Model` qui ne passe pas par `sortedByKey` ;
- un `.animation(value:)` sur une rangée dont la page pilote déjà l'état ;
- un moniteur `NSEvent`, un observateur `NotificationCenter` ou un `Timer` sans son démontage ;
- de la logique non triviale laissée dans une vue, sans test dans `Models/` ;
- une API `@available(macOS 15+)` : le minimum est `.v14` et **le build ne le voit pas** ;
- un banc de mesure committé ;
- **un commentaire, une doc ou une ligne de `CLAUDE.md`/`PIEGES.md` devenue fausse** — ça se corrige
  dans le même commit, jamais après.

## 4. Robustesse, performance, stabilité

- `try!`, force unwrap, index nu ou `first!` ajoutés sur un chemin qui peut échouer ;
- une écriture SwiftData sans `save()`, ou un `save()` posé dans une boucle ;
- du travail en O(n) refait par rangée, ou une passe qui interroge N éléments en N requêtes ;
- une `@Query` de plus : chacune relit la table entière (plafond connu, cf. dette n°2) ;
- un `@State` de plus pour une notion qui a déjà son type (sélection, édition, brouillon,
  glissement) — c'est comme ça que deux pages divergent sans que personne ne le voie.

## 5. Le contrôle visuel — si le diff touche `Sources/Today/Views/`

L'UI doit avoir été **regardée**, dans les **deux thèmes**, via `./run-dev.sh` (jamais `./run.sh` :
il tue l'instance du quotidien). Si ça n'a pas été fait dans cette session, le faire maintenant —
les régressions de mode sombre sont la rechute la plus fréquente du projet. Ne pas publier une
interface que personne n'a vue.

## 6. Rédiger le message de mise à jour

`$1` s'il est fourni, sinon le rédiger depuis le diff. **Ce texte est lu par les utilisateurs dans
la fenêtre de mise à jour**, pas par un développeur : dire ce qui change pour eux, en français, du
côté de l'usage. Première ligne = le résumé ; les lignes suivantes deviennent des points. Pas de
trailer `Co-Authored-By`, aucune mention d'outil.

## 7. VALIDATION MANUELLE — arrêt obligatoire

**Ne jamais enchaîner sur l'étape 8 dans le même tour.** Cette étape existe parce qu'une release
part chez de vrais utilisateurs et ne se reprend pas : le message est la seule chose qu'ils liront
du travail, et c'est un humain qui décide s'il est juste.

Afficher, puis **rendre la main et attendre une réponse** :

1. le message **tel qu'il apparaîtra** dans la fenêtre de mise à jour — résumé en tête, points
   ensuite, mis en forme, jamais résumé ni paraphrasé ;
2. la version cible — lire `SHORT_VERSION`/`BUILD` dans `Scripts/make-app.sh`, le dernier composant
   du court est incrémenté, le build +1 ;
3. la branche courante, et la liste exacte de ce que `git add -A` va emporter (fichiers non suivis
   compris) ;
4. tout angle mort resté du contrôle — un chemin modifié mais jamais exercé à la main, par exemple.

L'arrêt vaut **même quand le message a été passé en argument** : `$1` évite de le rédiger, pas de le
relire. Reprendre à l'étape 8 seulement sur un accord explicite ; sur une correction du texte, le
réafficher et attendre de nouveau.

## 8. Publier

```bash
./Scripts/quick.sh "<message>" [version]
```

**Ne rien commiter avant** : le script fait `git add -A`, le commit, le bump, le DMG signé, la
release GitHub, l'appcast et le push. Un commit préalable en produirait deux.

S'il échoue, il restaure `make-app.sh` tout seul et dit quoi faire (le plus fréquent : mauvais
compte `gh` actif → `gh auth switch -u rimodev74 -h github.com`). Rapporter ce qu'il a affiché —
version publiée, branche poussée — sans le reformuler en mieux qu'il ne l'a dit.
