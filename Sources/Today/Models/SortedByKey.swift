import Foundation

/// Trie en ne lisant les clés qu'UNE FOIS par élément, au lieu d'une fois par comparaison.
///
/// ## Pourquoi ça existe
///
/// Sur un `@Model` SwiftData, lire une propriété n'est PAS un accès mémoire : ça traverse la
/// machinerie du store (`_$backingData`). Un comparateur ordinaire relit donc ses clés à chaque
/// comparaison — n·log n fois, soit ~4 400 accès pour trier 86 tâches sur cinq clés. C'est ce qui
/// rendait le tri des vues intelligentes dix fois plus cher que leur filtrage, alors qu'il fait
/// moins de travail « utile ».
///
/// Mesuré en release, tri d'« Aujourd'hui » :
///
/// | tâches | comparateur direct | par clés | |
/// |---|---|---|---|
/// | 86   | 2,31 ms  | 0,31 ms | ×7,4 |
/// | 500  | 20,9 ms  | 2,16 ms | ×9,7 |
/// | 2000 | 93,8 ms  | 9,18 ms | ×10,2 |
///
/// Le gain vaut aussi pour les tris à deux clés (`orderedTasks` : 0,73 → 0,10 ms à 86), il est
/// simplement moins spectaculaire — il suit le NOMBRE de propriétés lues par comparaison.
///
/// ## Ce que ça ne change pas
///
/// L'ordre obtenu est identique : c'est le même comparateur, appliqué aux mêmes valeurs. Le tri de
/// Swift n'est pas stable, mais tous les appelants d'ici départagent leurs ex æquo par une clé
/// finale unique (`createdAt`), donc l'ordre est totalement déterminé — cf. les tests de chaque
/// appelant, qui n'ont pas eu à changer.
///
/// ## Quand NE PAS s'en servir
///
/// Sur une collection de types de valeur (dates, chaînes, `EKEvent`), la décoration coûte une
/// allocation de tableau pour rien : lire un champ y est déjà gratuit. Ce n'est pas un tri « plus
/// rapide » dans l'absolu, c'est un contournement du coût d'accès de SwiftData.
/// Le comparateur se passe TOUJOURS, même quand c'est `<` : une clé composite est un tuple, et un
/// tuple Swift accepte `<` sans pour autant conformer à `Comparable` (l'opérateur est surchargé
/// jusqu'à 6 éléments, il n'y a pas de conformance). Une surcharge « clé `Comparable` » aurait donc
/// refusé exactement le cas le plus courant.
func sortedByKey<Element, Key>(
  _ elements: [Element],
  key: (Element) -> Key,
  areInIncreasingOrder: (Key, Key) -> Bool
) -> [Element] {
  elements
    .map { (key($0), $0) }
    .sorted { areInIncreasingOrder($0.0, $1.0) }
    .map(\.1)
}
