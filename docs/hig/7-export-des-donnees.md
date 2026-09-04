# 7 — L'export des données

**Critère HIG** : 2.2 (gestion de fichiers).
**État** : à arbitrer. Ce n'est pas forcément un manque.

## Constat

Today est une app sans document : rien à ouvrir, rien à enregistrer, un seul store SwiftData. La
partie « fichiers » du HIG est donc largement sans objet, et ce qui existe est solide :

- chemin de store explicite (`StoreLocation`), pas la racine partagée d'`Application Support` ;
- sauvegarde automatique avant toute migration (`StoreBackup`) ;
- quarantaine d'une base illisible + alerte qui montre les fichiers dans le Finder
  (`StoreQuarantine`) ;
- `fileImporter` correct pour la photo de profil (accès borné à la portée).

Ce qui manque : **aucune sortie utilisateur**. Les données ne quittent l'app que par le fichier
`.store`, que personne n'ira chercher — et qui n'est lisible que par cette app.

## La question à trancher

Est-ce un vrai besoin ? Deux lectures :

- **Non** : l'app synchronise déjà vers Rappels Apple (pont bidirectionnel optionnel), qui est
  lui-même exportable et sauvegardé par iCloud. Une base récupérable par Time Machine + un pont vers
  une app système, c'est une porte de sortie.
- **Oui** : le pont ne porte que les tâches DATÉES d'une liste désignée. Les projets, les en-têtes,
  les notes riches, les sous-tâches, l'archive ne sortent nulle part.

## Si on le fait

Le plus petit geste utile d'abord :

1. **Export Markdown** de la sélection courante (une liste, un projet) — `NSSavePanel`, un fichier
   texte, en-têtes et sous-tâches comprises. C'est ce qui sert à archiver, partager, coller ailleurs.
2. Un export JSON complet seulement si quelqu'un le demande vraiment (une sauvegarde qu'on ne sait
   pas réimporter n'est pas une sauvegarde).

Où : menu *Fichier ▸ Exporter…*, à côté des créations (cf.
[1-barre-de-menus.md](1-barre-de-menus.md)) ; l'action passe par une valeur focalisée, comme le
reste.

**À ne pas faire** : un « import » sans avoir décidé ce qu'il fait des doublons. Un import naïf sur
un store réel est la meilleure façon de perdre des données proprement.
