import SwiftUI

/// Le bloc de résultats de la capsule : un pan de plus dans sa pile de verre, du même gabarit que
/// la fournée (cf. `QuickEntryPanel`).
///
/// Elle n'affiche que ce qu'on lui donne — aucune lecture de `@Model` ici, tout a été lu en une
/// passe dans `QuickPalette.Row`. Et elle ne décide de rien : c'est la ligne qui porte son action.
struct QuickEntryResultsBox: View {
  let rows: [QuickPalette.Row]
  /// L'index visé au clavier. Toujours posé sur une ligne en phase de recherche — c'est ce qui rend
  /// ↩ prévisible : il fait ce que la ligne surlignée annonce, jamais autre chose.
  let selection: Int?
  var onActivate: (QuickPalette.Row) -> Void

  /// Même gabarit que la liste des destinations (`destinationList`) : des rangées inscrites dans un
  /// fond arrondi, sans séparateurs. Un `Divider` pleine largeur ne s'alignerait pas sur des
  /// rangées en retrait, et deux traitements de liste dans la même capsule se verraient.
  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        QuickEntryResultRow(row: row, selected: index == selection, onActivate: onActivate)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 6)
    .padding(.horizontal, 6)
  }
}

private struct QuickEntryResultRow: View {
  let row: QuickPalette.Row
  let selected: Bool
  var onActivate: (QuickPalette.Row) -> Void

  @State private var hovered = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: row.systemImage)
        .font(.app(12))
        .foregroundStyle(.secondary)
        // Largeur fixe : les glyphes SF n'ont pas la même chasse, et sans elle les libellés
        // partaient en dents de scie d'une ligne à l'autre.
        .frame(width: 16)
      Text(row.title)
        .font(.app(14))
        .lineLimit(1)
        .strikethrough(row.isCompleted, color: .secondary)
        .foregroundStyle(row.isCompleted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      kindBadge
      Spacer(minLength: 10)
      if let detail = row.detail {
        Text(detail).font(.app(11)).foregroundStyle(.tertiary).lineLimit(1)
      }
      // La promesse de ↩, écrite noir sur blanc — mais seulement sur la ligne visée. Sur toutes,
      // c'était une colonne de texte à lire ; sur une seule, ça enseigne le principe en une frappe.
      if selected {
        Text(row.action.label)
          .font(.app(11, weight: .medium))
          .foregroundStyle(Color.accentColor)
        Text("↩").font(.app(11)).foregroundStyle(.tertiary)
        // Le second geste, annoncé au même endroit : ↩ fait ici, ⌘↩ va voir. Une commande n'a nulle
        // part où aller, la mention ne s'affiche donc pas pour elle.
        if row.destination != nil {
          Text("⌘↩ ouvrir").font(.app(11)).foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    // La surbrillance se pose en `.background` de la rangée, jamais en frère dans un `ZStack` :
    // une forme est flexible dans les deux dimensions, et posée en frère elle ferait gonfler la
    // ligne jusqu'à avaler le bloc.
    .background(highlight, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .onHover { hovered = $0 }
    .onTapGesture { onActivate(row) }
  }

  /// La nature de la ligne, en pastille. C'est elle qui rend l'action PRÉVISIBLE avant de la
  /// déclencher : « Dossier » annonce qu'on va y créer une liste, « Liste » qu'on va y poser une
  /// tâche. Sans elle, deux lignes de même titre se ressemblent et ↩ devient une surprise.
  private var kindBadge: some View {
    Text(row.kind)
      .font(.app(10, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(
        Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
  }

  /// La sélection au CLAVIER et le survol à la souris ne disent pas la même chose : la première est
  /// ce que ↩ va actionner, d'où la teinte d'accent ; le second n'est qu'un repère de position, et
  /// reste le gris neutre des autres listes de la capsule. Les deux suivent le thème — pas de
  /// valeur figée ici.
  private var highlight: Color {
    if selected { return Color.accentColor.opacity(0.22) }
    return hovered ? Color.primary.opacity(0.08) : .clear
  }
}
