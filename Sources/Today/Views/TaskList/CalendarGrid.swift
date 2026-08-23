import SwiftUI

/// La grille de jours des panneaux de date : « Quand » (`WhenPicker`) et la date d'une liste.
///
/// ## Pourquoi elle n'est PAS le `DatePicker(.graphical)` natif
///
/// « Natif d'abord » est la règle du projet, et c'est bien un `DatePicker` qui était là. Il ne
/// convient pas, et pas pour une question de goût : `.graphical` est un `NSDatePicker` en style
/// `clockAndCalendar`, une vue AppKit que SwiftUI ne fait que porter. Elle dessine SON cadre, SON
/// fond, son anneau de focus bleu, ses flèches de mois de 8 pt et son bouton « aujourd'hui » en
/// pastille — et rien de tout ça ne se restyle : ni `.tint`, ni `.background`, ni `.controlSize`
/// n'ont prise dessus. Posée dans un panneau aux marges douces, elle se lit comme un bout de Réglages
/// Système collé dans l'app. C'est la clause « si l'API native ne convient pas, dire pourquoi en
/// commentaire avant d'écrire du custom » de `CLAUDE.md` — la voici dite.
///
/// Écrite UNE fois pour ses deux porteurs. Un second calendrier « juste pour celui-ci » aurait
/// divergé au premier réglage ajouté : c'est déjà l'argument qui a sorti `WhenPicker` de `TaskRow`.
///
/// L'arithmétique — jours affichés, débordements sur les mois voisins, premier jour de la semaine —
/// vit dans `MonthGrid`, avec ses tests. Une vue orchestre et anime ; elle ne calcule pas.
struct CalendarGrid: View {
  /// Le jour retenu, s'il y en a un. Comparé au JOUR près : l'heure d'une tâche vit ailleurs
  /// (`TaskItem.whenMinutes`).
  let selection: Date?
  /// Reçoit un début de journée. Ce qu'on en écrit appartient à l'appelant — lui seul sait si
  /// c'est `when` ou la date d'une liste.
  var onPick: (Date) -> Void

  @State private var grid: MonthGrid
  @State private var hovered: Date?

  private let calendar = Calendar.current

  /// Largeur ET hauteur d'une case. 32 pt : sept colonnes tiennent en 224 pt, ce qui laisse le
  /// panneau plus étroit que la carte d'édition d'une tâche — un panneau de date n'a pas à être
  /// l'objet le plus large de l'écran.
  private static let cell: CGFloat = 32
  /// Le disque de sélection, plus petit que sa case : il doit respirer entre deux jours voisins.
  private static let dot: CGFloat = 27

  init(selection: Date?, onPick: @escaping (Date) -> Void) {
    self.selection = selection
    self.onPick = onPick
    _grid = State(initialValue: MonthGrid(containing: selection ?? Date()))
  }

  var body: some View {
    // Les trois lectures de `MonthGrid` se font ICI, une fois, et se distribuent aux 42 cases :
    // une case qui interrogerait la grille elle-même referait le calcul 42 fois par rendu.
    let symbols = MonthGrid.weekdaySymbols(calendar)
    let today = calendar.startOfDay(for: Date())
    let selectedDay = selection.map { calendar.startOfDay(for: $0) }

    return VStack(spacing: 6) {
      header
      HStack(spacing: 0) {
        ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
          Text(symbol)
            .font(.app(.caption))
            .foregroundStyle(.tertiary)
            // Sur UNE ligne, quitte à rétrécir : les abréviations de jours sont plus longues dans
            // certaines langues que les 32 pt d'une colonne, et un en-tête qui se replie sur deux
            // lignes décalerait toute la grille.
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: Self.cell)
        }
      }
      ForEach(0..<MonthGrid.rows, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<MonthGrid.columns, id: \.self) { column in
            let day = grid.days[row * MonthGrid.columns + column]
            dayCell(day, today: today, selected: selectedDay)
          }
        }
      }
    }
  }

  /// Le mois à gauche, sa navigation à droite. Pas de bouton « aujourd'hui » : les deux raccourcis
  /// du haut du panneau (`WhenPicker.quickRow`) le font déjà, et mieux — ils ÉCRIVENT le jour au
  /// lieu de seulement y ramener la vue.
  private var header: some View {
    HStack(spacing: 0) {
      Text(Self.monthFormatter.string(from: grid.month))
        .font(.app(.subheadline).weight(.semibold))
        .foregroundStyle(.primary)
      Spacer(minLength: 8)
      step(-1, symbol: "chevron.left", help: "Mois précédent")
      step(1, symbol: "chevron.right", help: "Mois suivant")
    }
    .padding(.horizontal, 4)
    .padding(.bottom, 2)
  }

  private func step(_ delta: Int, symbol: String, help: String) -> some View {
    Button {
      grid = grid.advanced(byMonths: delta, calendar: calendar)
    } label: {
      Image(systemName: symbol)
        .font(.app(.caption).weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }

  /// Une case. Le disque de sélection et le voile de survol sont posés en `.background` du texte, et
  /// pas en frères dans un `ZStack` : dans une pile verticale, une forme frère se voit distribuer la
  /// hauteur restante et fait gonfler sa rangée (cf. `CLAUDE.md` § Layout).
  private func dayCell(_ day: Date, today: Date, selected: Date?) -> some View {
    let isSelected = selected == day
    let isToday = day == today
    let inMonth = grid.isInMonth(day, calendar: calendar)

    return Button {
      onPick(day)
    } label: {
      Text(String(calendar.component(.day, from: day)))
        .font(.app(.callout).weight(isSelected || isToday ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(color(selected: isSelected, today: isToday, inMonth: inMonth))
        .frame(width: Self.cell, height: Self.cell)
        .background {
          Circle()
            .fill(
              isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(thingsSelectionFill)
            )
            .opacity(isSelected ? 1 : (hovered == day ? 1 : 0))
            .frame(width: Self.dot, height: Self.dot)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 ? day : (hovered == day ? nil : hovered) }
  }

  private func color(selected: Bool, today: Bool, inMonth: Bool) -> Color {
    if selected { return .white }
    if today { return .accentColor }
    return inMonth ? .primary : Color.primary.opacity(0.28)
  }

  /// Statique et non recréé à chaque rendu : un `DateFormatter` coûte plus cher à construire qu'à
  /// employer, et l'en-tête se redessine à chaque survol de case.
  private static let monthFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
    return formatter
  }()
}
