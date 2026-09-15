import AppKit
import SwiftUI

/// Un Mac dessiné dont l'écran montre Today, animé en boucle : l'illustration des écrans de
/// l'accueil qui présentent une fonction.
///
/// ponytail: EXEMPLE à valider, isolé dans ce fichier pour se retirer d'un geste. Rien n'y est une
/// capture : tout est dessiné avec les briques de l'app (teintes de page, badge, voiles, symboles et
/// libellés des pages), il suit donc les deux thèmes et les couleurs sans qu'on y touche. Ce qu'il ne
/// suit PAS, c'est la mise en page de l'app — si elle change, ce dessin ment. C'est son plafond.
///
/// Animé par `PhaseLoop` : la boucle ne tourne que tant que la vue est à l'écran, rien n'est à
/// démonter en sortant. La « caméra » (un `scaleEffect` sur le Mac entier, rogné par le cadre)
/// s'approche de ce que la phase montre, puis recule.
struct MacShowcase: View {
  enum Scene {
    case quickEntry
    case reminders
    case ready
  }

  let scene: Scene
  let userName: String

  /// Toute la largeur de la fenêtre : quand la caméra s'approche, le Mac est rogné par le BORD de la
  /// fenêtre, pas par un rectangle posé au milieu d'elle — dont les coins durs se voyaient.
  static let size = CGSize(width: MainWindowSize.onboarding.width, height: 300)

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      switch scene {
      case .quickEntry:
        animated(still: QuickEntryPhase.typed) { QuickEntryShot(phase: $0) }
      case .reminders:
        animated(still: RemindersPhase.reminder) { RemindersShot(phase: $0, userName: userName) }
      case .ready:
        animated(still: ReadyPhase.three) { ReadyShot(phase: $0, userName: userName) }
      }
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .clipped()
    // Le bas se fond dans la page au lieu d'être coupé net quand la caméra s'approche.
    .mask {
      LinearGradient(
        stops: [.init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
        startPoint: .top, endPoint: .bottom)
    }
    .accessibilityHidden(true)
  }

  /// Mouvement réduit : une seule image, celle qui montre le mieux la fonction.
  @ViewBuilder
  private func animated<Phase: ShowcasePhase, Content: View>(
    still: Phase, @ViewBuilder content: @escaping (Phase) -> Content
  ) -> some View {
    if reduceMotion {
      content(still)
    } else {
      PhaseLoop(content: content)
    }
  }
}

/// Parcourt les phases en boucle : une pause, puis le passage animé à la suivante.
///
/// Pas `PhaseAnimator` : sa pause ne pouvait être qu'un `.delay()` dans l'animation, et une animation
/// retardée est une animation EN COURS — la vue entière se redessinait à chaque image pendant qu'il
/// ne se passait rien. La pause est ici un `Task.sleep`, pendant lequel rien n'est dessiné ; `.task`
/// l'annule quand la vue part. Mesuré sur les trois écrans du Mac : de 6-8 % de CPU à 3-5 %, les
/// pauses retombant à 0 — le reste est le passage animé lui-même.
private struct PhaseLoop<Phase: ShowcasePhase, Content: View>: View {
  let content: (Phase) -> Content
  @State private var index = 0

  var body: some View {
    let phases = Array(Phase.allCases)
    content(phases[index])
      .task {
        var current = 0
        while true {
          let next = (current + 1) % phases.count
          let timing = phases[next].timing
          do { try await Task.sleep(for: .seconds(timing.hold)) } catch { return }
          withAnimation(.smooth(duration: timing.duration)) { index = next }
          current = next
          do { try await Task.sleep(for: .seconds(timing.duration)) } catch { return }
        }
      }
  }
}

// Au niveau du fichier, et pas sur `MacShowcase` : une vue est isolée au fil principal, et les
// phases qui les lisent ne le sont pas.

/// Le Mac tient entier dans le cadre au repos (écran 16:10, lunette et socle compris).
private let macWidth: CGFloat = 420
/// Au-delà, la lunette sort du cadre et il ne reste qu'un rectangle d'écran : on ne lit plus un Mac.
private let closeUp: CGFloat = 1.3

/// Une étape de la boucle. `hold` est le temps passé sur la PRÉCÉDENTE — c'est ce qui laisse lire
/// chaque image avant la suivante — et `duration` celle du passage qui MÈNE à celle-ci.
private protocol ShowcasePhase: CaseIterable, Equatable, Sendable {
  var timing: (hold: Double, duration: Double) { get }
}

// MARK: - Le raccourci

private enum QuickEntryPhase: ShowcasePhase {
  case rest, open, searched, chosen, typed, saved

  var capsuleVisible: Bool { self != .rest && self != .saved }
  var choseToday: Bool { self == .chosen || self == .typed }

  var typed: String {
    switch self {
    case .searched: return "auj"
    case .typed: return "Acheter du pain"
    default: return ""
    }
  }

  /// Les textes de la vraie capsule (cf. `QuickEntryView.placeholder`).
  var placeholder: String {
    choseToday
      ? "Nouvelle tâche dans \(SmartList.today.label)"
      : "Rechercher une vue, un dossier, une liste, une tâche…"
  }

  var zoom: CGFloat { capsuleVisible ? closeUp : 1 }

  var timing: (hold: Double, duration: Double) {
    switch self {
    case .rest: return (hold: 1.4, duration: 0.6)
    case .open: return (hold: 1.0, duration: 0.55)
    case .searched: return (hold: 0.9, duration: 0.3)
    case .chosen: return (hold: 1.0, duration: 0.3)
    case .typed: return (hold: 0.7, duration: 0.3)
    case .saved: return (hold: 1.2, duration: 0.5)
    }
  }
}

/// La capsule s'ouvre par-dessus une AUTRE app : c'est tout son intérêt, et ce que l'écran dit.
private struct QuickEntryShot: View {
  let phase: QuickEntryPhase

  var body: some View {
    MacBook(width: macWidth) {
      Desktop {
        ZStack(alignment: .top) {
          OtherAppWindow()
            .frame(width: 620, height: 380)
            .padding(.top, 50)
          if phase.capsuleVisible {
            MiniCapsule(phase: phase)
              .padding(.top, 76)
              .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
          }
          if phase == .saved {
            // La pastille que l'app montre vraiment après un dépôt depuis ailleurs (cf. `HUDWindow`).
            Label("Tâche ajoutée", systemImage: "checkmark")
              .font(.app(13, weight: .semibold))
              .foregroundStyle(.green)
              .padding(.horizontal, 16)
              .padding(.vertical, 10)
              .background(miniSurface, in: Capsule())
              .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
              .padding(.top, 200)
              .transition(.opacity.combined(with: .scale(scale: 0.9)))
          }
        }
      }
    }
    .scaleEffect(phase.zoom, anchor: UnitPoint(x: 0.5, y: 0.05))
  }
}

private struct MiniCapsule: View {
  let phase: QuickEntryPhase

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    VStack(spacing: 6) {
      HStack(spacing: 10) {
        if phase.choseToday {
          Label(SmartList.today.label, systemImage: SmartList.today.systemImage)
            .font(.app(12))
            .labelStyle(TintedIconLabelStyle(tint: PageTint.today))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
              PageTint.today.opacity(0.16),
              in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        }
        Text(phase.typed.isEmpty ? phase.placeholder : phase.typed)
          .foregroundStyle(phase.typed.isEmpty ? .secondary : .primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .font(.app(15))
      .padding(.horizontal, 14)
      .frame(width: 440, height: 44)
      .background(miniSurface, in: shape)

      if phase == .searched {
        HStack(spacing: 9) {
          Image(systemName: SmartList.today.systemImage).foregroundStyle(PageTint.today)
          Text(SmartList.today.label)
          Spacer(minLength: 0)
          Text("Vue").foregroundStyle(.secondary)
          Text("Ajouter une tâche")
            .font(.app(10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(rowSelectionFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .font(.app(12.5))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(rowSelectionFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(6)
        .frame(width: 440)
        .background(miniSurface, in: shape)
        .transition(.opacity)
      }
    }
    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
  }
}

private struct TintedIconLabelStyle: LabelStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 5) {
      configuration.icon.foregroundStyle(tint)
      configuration.title
    }
  }
}

/// « N'importe quelle app » : une fenêtre de document sans marque, dont le texte n'est que suggéré.
private struct OtherAppWindow: View {
  private static let lines: [CGFloat] = [380, 440, 300, 410, 350, 260, 420, 330]

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    VStack(alignment: .leading, spacing: 12) {
      TrafficLights().padding(.bottom, 10)
      ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, width in
        Capsule().fill(Color.primary.opacity(0.09)).frame(width: width, height: 8)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .textBackgroundColor), in: shape)
    .overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
    .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
  }
}

// MARK: - Rappels et Calendrier

private enum RemindersPhase: ShowcasePhase {
  case rest, reminder, event

  var zoom: CGFloat { self == .rest ? 1 : closeUp }

  var timing: (hold: Double, duration: Double) {
    switch self {
    case .rest: return (hold: 1.8, duration: 0.7)
    case .reminder: return (hold: 1.2, duration: 0.6)
    case .event: return (hold: 1.8, duration: 0.5)
    }
  }
}

private struct RemindersShot: View {
  let phase: RemindersPhase
  let userName: String

  var body: some View {
    MacBook(width: macWidth) {
      Desktop {
        ZStack(alignment: .topTrailing) {
          MiniTodayWindow(userName: userName, rows: MiniTask.samples)
            .frame(width: 600, height: 380)
            .padding(.top, 56)
            .frame(maxWidth: .infinity, alignment: .center)
          Group {
            if phase == .reminder {
              ReminderBanner().transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if phase == .event {
              EventCard().transition(
                .opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)))
            }
          }
          .padding(.top, 30)
          .padding(.trailing, 14)
          // Au-dessus de la fenêtre, y compris PENDANT sa transition d'entrée : une vue en cours
          // d'insertion ne garde pas d'office son rang dans la pile, et la notification passait dessous.
          .zIndex(1)
        }
      }
    }
    .scaleEffect(phase.zoom, anchor: UnitPoint(x: 0.8, y: 0.05))
  }
}

/// La notification que Rappels affiche à l'heure d'une tâche datée.
private struct ReminderBanner: View {
  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "checklist")
        .font(.app(13, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(
          Color.orange.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      VStack(alignment: .leading, spacing: 1) {
        HStack {
          Text("Rappels").font(.app(11, weight: .semibold))
          Spacer(minLength: 0)
          Text("maintenant").font(.app(10)).foregroundStyle(.secondary)
        }
        Text("Acheter du pain").font(.app(11.5))
        Text("Aujourd'hui, 18:00").font(.app(10.5)).foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .frame(width: 250)
    .background(miniSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
  }
}

/// La même tâche une fois dotée d'une durée : un créneau dans Calendrier.
private struct EventCard: View {
  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.red).frame(width: 3)
      VStack(alignment: .leading, spacing: 1) {
        Text("Préparer la réunion").font(.app(11.5, weight: .semibold))
        Text("14:00 – 15:00 · Calendrier").font(.app(10.5)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(9)
    .frame(width: 250, height: 50)
    .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .background(miniSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
  }
}

// MARK: - Prêt

private enum ReadyPhase: ShowcasePhase {
  case empty, one, two, three

  var rowCount: Int {
    switch self {
    case .empty: return 0
    case .one: return 1
    case .two: return 2
    case .three: return 3
    }
  }

  /// La caméra recule pendant que la journée se remplit.
  var zoom: CGFloat { self == .empty ? 1.12 : 1 }

  var timing: (hold: Double, duration: Double) {
    switch self {
    case .empty: return (hold: 2.2, duration: 0.6)
    case .one: return (hold: 0.4, duration: 0.9)
    case .two, .three: return (hold: 0.5, duration: 0.4)
    }
  }
}

private struct ReadyShot: View {
  let phase: ReadyPhase
  let userName: String

  var body: some View {
    MacBook(width: macWidth) {
      Desktop {
        MiniTodayWindow(userName: userName, rows: Array(MiniTask.samples.prefix(phase.rowCount)))
          .frame(width: 640, height: 400)
          .padding(.top, 48)
      }
    }
    .scaleEffect(phase.zoom, anchor: UnitPoint(x: 0.5, y: 0.05))
  }
}

// MARK: - Today en miniature

private struct MiniTask: Identifiable {
  let title: String
  let time: String?
  var id: String { title }

  /// Des EXEMPLES, dessinés — jamais écrits en base.
  static let samples = [
    MiniTask(title: "Répondre à Camille", time: nil),
    MiniTask(title: "Préparer la réunion", time: "14:00"),
    MiniTask(title: "Acheter du pain", time: "18:00"),
  ]
}

private struct MiniTodayWindow: View {
  let userName: String
  let rows: [MiniTask]

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    HStack(spacing: 0) {
      MiniSidebar(userName: userName)
        .frame(width: 168)
        .background(Scrim.sidebar)
      MiniTodayPage(rows: rows)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Scrim.page.overlay(PageTintWash(tint: PageTint.today)))
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(shape)
    .overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
    .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
  }
}

private struct MiniSidebar: View {
  let userName: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      TrafficLights().padding(.bottom, 14)
      HStack(spacing: 7) {
        Circle()
          .fill(PageTint.today.opacity(0.22))
          .frame(width: 20, height: 20)
          .overlay {
            Text(String(userName.prefix(1)).uppercased())
              .font(.app(9, weight: .semibold))
              .foregroundStyle(PageTint.today)
          }
        Text(userName).font(.app(11.5, weight: .semibold)).lineLimit(1)
      }
      .padding(.horizontal, 6)
      .padding(.bottom, 10)
      ForEach(SmartList.allCases, id: \.self) { list in
        HStack(spacing: 7) {
          Image(systemName: list.systemImage).foregroundStyle(list.color).frame(width: 14)
          Text(list.label)
        }
        .font(.app(11))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .background(
          list == .today ? rowSelectionFill : .clear,
          in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      Spacer(minLength: 0)
    }
    .padding(10)
  }
}

private struct MiniTodayPage: View {
  let rows: [MiniTask]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        PageBadge(systemImage: SmartList.today.systemImage, tint: PageTint.today)
        Text(SmartList.today.label).font(.app(21, weight: .bold))
      }
      .padding(.bottom, 14)
      ForEach(rows) { row in
        HStack(spacing: 9) {
          RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .strokeBorder(PageTint.today, lineWidth: 1.4)
            .frame(width: 13, height: 13)
          Text(row.title).font(.app(12))
          Spacer(minLength: 8)
          if let time = row.time {
            Text(time)
              .font(.app(10, weight: .semibold))
              .foregroundStyle(PageTint.today)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(PageTint.today.opacity(0.14), in: Capsule())
          }
        }
        .frame(height: 27)
        .transition(.opacity.combined(with: .offset(y: -6)))
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 22)
    .padding(.top, 20)
  }
}

// MARK: - Le Mac

/// Le plan de travail de l'écran, en points « réels » : tout y est dessiné à taille normale, puis
/// l'écran entier est réduit d'un bloc. Dessiner directement en police de 5 pt donnait des
/// proportions fausses dès qu'on touchait une valeur.
private let desktopCanvas = CGSize(width: 800, height: 500)

// Le matériel est FIGÉ à dessein : un MacBook est noir et argent dans les deux thèmes — même raison
// que les vignettes d'apparence. `Color(white:)` et pas `dualColor`, qui dirait le contraire.
private let macLid = Color(white: 0.06)
private let macLidEdge = Color(white: 0.4)
private let macBaseTop = Color(white: 0.84)
private let macBaseBottom = Color(white: 0.58)
private let macBaseLip = Color(white: 0.45)

/// Le fond des surfaces flottantes de l'écran (capsule, notification) : celui des fenêtres système,
/// qui suit déjà le thème.
private let miniSurface = Color(nsColor: .windowBackgroundColor)

private struct MacBook<Screen: View>: View {
  let width: CGFloat
  @ViewBuilder var screen: Screen

  var body: some View {
    let bezel = width * 0.022
    let screenWidth = width - bezel * 2
    let scale = screenWidth / desktopCanvas.width
    let lid = RoundedRectangle(cornerRadius: width * 0.03, style: .continuous)
    VStack(spacing: 0) {
      screen
        .frame(width: desktopCanvas.width, height: desktopCanvas.height)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: screenWidth, height: desktopCanvas.height * scale, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.012, style: .continuous))
        .overlay(alignment: .top) {
          UnevenRoundedRectangle(
            bottomLeadingRadius: bezel * 0.6, bottomTrailingRadius: bezel * 0.6, style: .continuous
          )
          .fill(macLid)
          .frame(width: width * 0.12, height: bezel * 1.1)
        }
        .padding(bezel)
        .background(macLid, in: lid)
        .overlay { lid.strokeBorder(macLidEdge, lineWidth: 1) }
      MacBase(width: width)
    }
  }
}

private struct MacBase: View {
  let width: CGFloat

  var body: some View {
    let height = width * 0.022
    ZStack(alignment: .top) {
      UnevenRoundedRectangle(
        topLeadingRadius: height * 0.2, bottomLeadingRadius: height * 0.9,
        bottomTrailingRadius: height * 0.9, topTrailingRadius: height * 0.2, style: .continuous
      )
      .fill(
        LinearGradient(colors: [macBaseTop, macBaseBottom], startPoint: .top, endPoint: .bottom)
      )
      .frame(width: width * 1.14, height: height)
      UnevenRoundedRectangle(
        bottomLeadingRadius: height * 0.35, bottomTrailingRadius: height * 0.35, style: .continuous
      )
      .fill(macBaseLip)
      .frame(width: width * 0.15, height: height * 0.38)
    }
  }
}

/// Le bureau : un fond d'écran aux couleurs des pages, la barre des menus de Today, et ce que la
/// scène pose dessus.
private struct Desktop<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    ZStack(alignment: .top) {
      Wallpaper()
      content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      MenuBar()
    }
    .frame(width: desktopCanvas.width, height: desktopCanvas.height)
  }
}

private struct Wallpaper: View {
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [PageTint.upcoming, PageTint.inbox], startPoint: .topLeading,
        endPoint: .bottomTrailing)
      RadialGradient(
        colors: [PageTint.today.opacity(0.75), .clear], center: UnitPoint(x: 0.12, y: 1),
        startRadius: 0, endRadius: 460)
      RadialGradient(
        colors: [PageTint.archive.opacity(0.3), .clear], center: UnitPoint(x: 0.95, y: 0.05),
        startRadius: 0, endRadius: 380)
    }
  }
}

private struct MenuBar: View {
  /// Les premiers menus seulement : sur un Mac à encoche, la suite passerait dessous.
  private static let menus = ["Fichier", "Édition", "Présentation", "Aller"]

  var body: some View {
    HStack(spacing: 13) {
      Image(systemName: "apple.logo").font(.app(11, weight: .semibold))
      Text("Today").font(.app(11, weight: .bold))
      ForEach(Self.menus, id: \.self) { Text($0) }
      Spacer(minLength: 0)
      Text(
        Date.now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
    .font(.app(11))
    .foregroundStyle(.white)
    .padding(.horizontal, 14)
    .frame(height: 22)
    .background(.black.opacity(0.16))
  }
}

private struct TrafficLights: View {
  var body: some View {
    HStack(spacing: 6) {
      ForEach([NSColor.systemRed, .systemYellow, .systemGreen], id: \.self) { color in
        Circle().fill(Color(nsColor: color)).frame(width: 9, height: 9)
      }
    }
  }
}
