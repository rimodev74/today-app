import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// La courbe de l'accueil : un écran qui arrive, les points qui s'allongent, le voile qui part.
/// Nommée et propre à l'accueil — celles des pages de tâches sont partagées, on n'y touche pas.
let onboardingFlow = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45)

/// L'accueil du premier lancement : six écrans, à la place des deux colonnes, dans la fenêtre
/// principale devenue carrée (cf. `OnboardingWindowFrame`).
///
/// La fenêtre principale, et pas une feuille ni une fenêtre à part : une fenêtre enfant ordonnée
/// pendant le layout tue le process, et un champ focalisé veut une fenêtre conteneur affichée du
/// début à la fin — celle-ci l'est (→ `PIEGES.md` § Fenêtres).
///
/// Un seul geste y est RÉEL : la capsule. L'écran ne la simule pas — il invite à frapper le vrai
/// raccourci et avance quand une tâche arrive en base. C'est la seule façon d'apprendre un geste
/// plutôt que de le lire.
struct OnboardingView: View {
  @Binding var step: OnboardingStep
  let finish: () -> Void

  @Environment(\.modelContext) private var modelContext
  @Environment(RemindersService.self) private var remindersService
  @Environment(UserProfile.self) private var profile

  /// Le sens du dernier déplacement : l'écran entrant arrive du côté où l'on va.
  @State private var forward = true
  /// La tâche notée par la capsule pendant l'accueil. Portée ICI et pas par son écran : un
  /// aller-retour entre écrans reconstruit leur contenu, et l'écran de la capsule redemanderait un
  /// geste déjà fait.
  @State private var capturedTitle: String?
  /// Même raison : revenir sur « Rappels » ne doit pas proposer de reconnecter ce qui l'est.
  @State private var bridge = BridgeState.idle
  /// Seules les tâches créées APRÈS l'ouverture comptent : sur *Revoir l'accueil*, la base en porte
  /// déjà, et la première venue aurait passé l'écran pour « notée ».
  @State private var openedAt = Date()

  /// La fenêtre entière : pendant l'accueil, elle a la taille de son carré (cf.
  /// `OnboardingWindowFrame`). Le verre est celui de la fenêtre, posé par `ContentView` ; le voile
  /// est celui de la page qu'on lit.
  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        screen
          .id(step)
          // L'entrant glisse du côté où l'on va ; le sortant ne fait que s'effacer. Un sortant qui
          // glisserait aussi prendrait le sens du déplacement PRÉCÉDENT : SwiftUI garde la
          // transition de son dernier rendu, d'avant que `forward` ne change.
          .transition(
            .asymmetric(
              insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)),
              removal: .opacity))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      footer
    }
    .background { Scrim.page.ignoresSafeArea() }
    .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
      noticeCapturedTask()
    }
  }

  @ViewBuilder private var screen: some View {
    switch step {
    case .welcome: WelcomeScreen(profile: profile)
    case .profile: ProfileScreen(profile: profile)
    case .appearance: AppearanceScreen()
    case .quickEntry: QuickEntryScreen(capturedTitle: capturedTitle, userName: userName)
    case .reminders: RemindersScreen(bridge: bridge, userName: userName)
    case .ready: ReadyScreen(userName: userName)
    }
  }

  /// Le nom qu'affiche la barre latérale du Mac dessiné : celui qu'on vient de taper, pour que l'app
  /// montrée soit la sienne.
  private var userName: String {
    let name = profile.firstName.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "Vous" : name
  }

  // MARK: Pied

  private var footer: some View {
    HStack(spacing: 6) {
      if let previous = step.previous {
        Button("Retour") { go(to: previous) }
          .buttonStyle(OnboardingButtonStyle(kind: .bare))
      }
      Spacer()
      if step == .reminders, bridge == .idle {
        Button("Passer") { go(to: .ready) }
          .buttonStyle(OnboardingButtonStyle(kind: .bare))
      }
      primaryButton
    }
    .overlay { dots }
    .padding(.horizontal, 24)
    .frame(height: 72)
  }

  @ViewBuilder private var primaryButton: some View {
    switch step {
    case .welcome: action("Commencer", kind: .prominent, run: advance)
    case .profile, .appearance: action("Continuer", kind: .prominent, run: advance)
    case .quickEntry:
      // « Plus tard » tant que rien n'est noté : le geste reste facultatif, mais le bouton ne doit
      // pas avoir l'air de valider un essai qui n'a pas eu lieu.
      if capturedTitle == nil {
        action("Plus tard", kind: .quiet, run: advance)
      } else {
        action("Continuer", kind: .prominent, run: advance)
      }
    case .reminders:
      switch bridge {
      case .idle: action("Connecter", kind: .prominent, run: connect)
      case .asking: action("Connecter", kind: .prominent) {}.disabled(true)
      case .answered: action("Continuer", kind: .prominent, run: advance)
      }
    case .ready: action("Ouvrir l'app", kind: .prominent, run: finish)
    }
  }

  private func action(
    _ title: String, kind: OnboardingButtonStyle.Kind, run: @escaping () -> Void
  ) -> some View {
    Button(title, action: run)
      .buttonStyle(OnboardingButtonStyle(kind: kind))
      .keyboardShortcut(.defaultAction)
  }

  private var dots: some View {
    HStack(spacing: 7) {
      ForEach(OnboardingStep.allCases, id: \.self) { item in
        Capsule()
          .fill(item == step ? Color.primary : Color.primary.opacity(0.22))
          .frame(width: item == step ? 18 : 6, height: 6)
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Étape \(step.rawValue + 1) sur \(OnboardingStep.allCases.count)")
  }

  // MARK: Gestes

  private func go(to target: OnboardingStep) {
    forward = target.rawValue > step.rawValue
    withAnimation(onboardingFlow) { step = target }
  }

  private func advance() {
    if let next = step.next { go(to: next) }
  }

  /// Une sauvegarde vient d'avoir lieu : est-ce la tâche de la capsule ? Pas de `@Query` pour le
  /// savoir — son corps se rejouerait à chaque invalidation de SwiftData (cf. CLAUDE.md § Ce qui se
  /// rend à chaque image), là où une sauvegarde est rare et un comptage borné à UNE ligne.
  private func noticeCapturedTask() {
    guard capturedTitle == nil else { return }
    let since = openedAt
    var descriptor = FetchDescriptor<TaskItem>(
      predicate: #Predicate { $0.createdAt > since && !$0.isHeader })
    descriptor.fetchLimit = 1
    guard let task = try? modelContext.fetch(descriptor).first else { return }
    let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    withAnimation(onboardingFlow) { capturedTitle = title }
  }

  /// Demande les deux accès, l'un après l'autre — deux dialogues système distincts.
  ///
  /// Accepter de connecter, c'est vouloir que ça marche : la liste et le calendrier d'office sont
  /// désignés s'il n'y en a pas déjà un. Les menus de l'écran permettent d'en choisir un autre, ou
  /// « Aucun ». Écrit dans les défauts directement : c'est `RemindersScreen` qui les observe.
  private func connect() {
    withAnimation(onboardingFlow) { bridge = .asking }
    Task {
      let defaults = UserDefaults.standard
      let reminders = (try? await remindersService.requestAccess()) != nil
      if reminders, defaults.string(forKey: RemindersSync.listStorageKey)?.isEmpty ?? true,
        let list = remindersService.defaultList
      {
        defaults.set(list.calendarIdentifier, forKey: RemindersSync.listStorageKey)
        defaults.set(true, forKey: RemindersSync.pushStorageKey)
      }
      let events = await remindersService.requestEventAccess()
      if events, defaults.string(forKey: RemindersSync.eventCalendarStorageKey)?.isEmpty ?? true,
        let calendar = remindersService.defaultEventCalendar
      {
        defaults.set(calendar.calendarIdentifier, forKey: RemindersSync.eventCalendarStorageKey)
        remindersService.rememberEventCalendarName(for: calendar.calendarIdentifier)
      }
      withAnimation(onboardingFlow) { bridge = .answered(reminders: reminders, events: events) }
    }
  }
}

enum BridgeState: Equatable {
  case idle
  case asking
  case answered(reminders: Bool, events: Bool)
}

// MARK: - Écran 1 : bienvenue

private struct WelcomeScreen: View {
  let profile: UserProfile

  var body: some View {
    VStack(spacing: 22) {
      GatheringSun()
      Headline(
        title: greeting,
        lede: "Avant de commencer, quelques réglages. Ça prend une minute."
      )
    }
    .onboardingColumn()
  }

  private var greeting: String {
    let name = profile.firstName.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "Bonjour" : "Bonjour, \(name)"
  }
}

/// Les quatre pages de la barre latérale, posées en rang le temps qu'on les reconnaisse, qui se
/// rassemblent dans celle qui ouvre la journée.
private struct GatheringSun: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var gathered = false

  private static let pages: [SmartList] = [.all, .today, .upcoming, .archive]

  var body: some View {
    ZStack {
      ForEach(Array(Self.pages.enumerated()), id: \.element) { index, page in
        let isSun = page == .today
        PageGlyph(page: page, side: gathered && isSun ? 96 : 56)
          .scaleEffect(gathered && !isSun ? 0.5 : 1)
          .opacity(gathered && !isSun ? 0 : 1)
          .offset(x: gathered ? 0 : CGFloat(index) * 68 - 102)
          .zIndex(isSun ? 1 : 0)
      }
    }
    .frame(width: 260, height: 110)
    .onAppear {
      withAnimation(reduceMotion ? nil : .timingCurve(0.6, 0, 0.2, 1, duration: 1.1).delay(0.6)) {
        gathered = true
      }
    }
  }
}

/// Le cartouche d'une page, à taille VARIABLE. Pas `PageBadge` : son glyphe est une taille de
/// police, qui ne s'interpole pas — le soleil sauterait d'une taille à l'autre au lieu de grandir.
/// Une image redimensionnable suit son cadre, image par image.
private struct PageGlyph: View {
  let page: SmartList
  let side: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
      .fill(page.color.opacity(0.16))
      .frame(width: side, height: side)
      .overlay {
        Image(systemName: page.systemImage)
          .resizable()
          .scaledToFit()
          .fontWeight(.semibold)
          .foregroundStyle(page.color)
          .frame(width: side * 0.5, height: side * 0.5)
      }
  }
}

// MARK: - Écran 2 : vous

private struct ProfileScreen: View {
  @Bindable var profile: UserProfile
  @FocusState private var nameFocused: Bool

  /// UN seul champ : l'accueil ne demande que le nom à afficher. Le profil en porte deux et
  /// `fullName` les colle — le nom de famille tiré du compte macOS s'accrocherait donc au pseudo tapé
  /// ici (« Rimo Monnier »). Écrire ce champ vide le second.
  private var displayName: Binding<String> {
    Binding(
      get: { profile.firstName },
      set: {
        profile.firstName = $0
        if !profile.lastName.isEmpty { profile.lastName = "" }
      })
  }

  var body: some View {
    VStack(spacing: 26) {
      Headline(
        title: "Comment vous appeler ?",
        lede: "Votre prénom ou un pseudo. Il s'affichera en haut de la barre latérale."
      )

      VStack(spacing: 14) {
        Button(action: choosePhoto) {
          AvatarView(profile: profile, size: 76)
            .overlay(alignment: .bottom) {
              Text("Photo")
                .font(.app(10.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 3)
                .padding(.bottom, 7)
                .background(.black.opacity(0.38))
            }
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Choisir une photo")

        nameField
      }
    }
    .onboardingColumn()
  }

  /// Largeur EXPLICITE : un `TextField` focalisé dans une pile sans largeur proposée se réduit à sa
  /// taille idéale, nulle (cf. CLAUDE.md § Layout).
  ///
  /// Style `.plain` sous un fond à nous : le cadre `.roundedBorder` natif, à cette taille et sur le
  /// verre, se lisait comme un formulaire administratif. Le focus reste visible, par le liseré.
  private var nameField: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    return TextField("Prénom ou pseudo", text: displayName, prompt: Text("Prénom ou pseudo"))
      .labelsHidden()
      .textFieldStyle(.plain)
      .font(.app(17, weight: .medium))
      // Centré sous la photo : un nom aligné à gauche sous un visage centré avait l'air décalé.
      .multilineTextAlignment(.center)
      .focused($nameFocused)
      .padding(.horizontal, 14)
      .frame(width: 280, height: 44)
      .background(rowSelectionFill, in: shape)
      .overlay {
        shape.strokeBorder(
          nameFocused ? PageTint.today : Color.primary.opacity(0.1),
          lineWidth: nameFocused ? 1.5 : 1)
      }
  }

  /// `NSOpenPanel` lancé depuis l'ACTION du bouton, et pas `.fileImporter` comme dans les Réglages :
  /// SwiftUI présente celui-ci depuis le layout, par le même pont que les popovers — et ordonner une
  /// fenêtre pendant le layout de CETTE fenêtre-ci, où les cadres des lignes circulent en continu,
  /// tue le process (→ `PIEGES.md` § Fenêtres).
  private func choosePhoto() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.begin { response in
      guard response == .OK, let url = panel.url,
        let data = try? Data(contentsOf: url), NSImage(data: data) != nil
      else { return }
      profile.avatarData = data
    }
  }
}

// MARK: - Écran 3 : l'apparence

private struct AppearanceScreen: View {
  @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

  var body: some View {
    VStack(spacing: 28) {
      Headline(
        title: "Clair ou sombre ?",
        lede:
          "La fenêtre change dès que vous choisissez. Vous pourrez revenir dessus dans les Réglages."
      )
      HStack(spacing: 14) {
        ForEach([AppTheme.system, .light, .dark]) { theme in
          ThemeThumbnail(theme: theme, isSelected: themeRaw == theme.rawValue) {
            themeRaw = theme.rawValue
          }
        }
      }
    }
    .onboardingColumn()
  }
}

private struct ThemeThumbnail: View {
  let theme: AppTheme
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    Button(action: select) {
      VStack(spacing: 8) {
        preview
          .frame(height: 96)
          .clipShape(shape)
          .overlay {
            shape.strokeBorder(
              isSelected ? PageTint.today : Color.primary.opacity(0.13),
              lineWidth: isSelected ? 2.5 : 1)
          }
        Text(theme.label)
          .font(.app(13.5, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? .primary : .secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Une fenêtre de Today en miniature. « Système » la montre coupée net au milieu, claire à gauche,
  /// sombre à droite : la vignette « Automatique » des Réglages Système, qu'on reconnaît déjà.
  @ViewBuilder private var preview: some View {
    switch theme {
    case .light: MiniWindow(palette: .light)
    case .dark: MiniWindow(palette: .dark)
    case .system:
      MiniWindow(palette: .light)
        .overlay {
          MiniWindow(palette: .dark).mask {
            HStack(spacing: 0) {
              Color.clear
              Color.black
            }
          }
        }
    }
  }
}

/// Les couleurs d'une vignette d'apparence. Figées À DESSEIN, et sans `dualColor` : une vignette
/// MONTRE un thème, elle ne suit pas celui de la fenêtre — « Clair » reste clair sur une fenêtre
/// sombre. L'orange est celui de `PageTint.today`, dans la version de chaque thème.
private struct MiniPalette {
  let window: Color
  let sidebar: Color
  let line: Color
  let strong: Color
  let selection: Color
  let accent: Color

  static let light = MiniPalette(
    window: Color(white: 0.985), sidebar: Color(white: 0.93), line: Color(white: 0.82),
    strong: Color(white: 0.45), selection: Color(white: 0.86),
    accent: Color(red: 0.851, green: 0.541, blue: 0.122))
  static let dark = MiniPalette(
    window: Color(white: 0.17), sidebar: Color(white: 0.11), line: Color(white: 0.32),
    strong: Color(white: 0.72), selection: Color(white: 0.25),
    accent: Color(red: 0.949, green: 0.663, blue: 0.235))
}

/// La fenêtre de Today réduite à ses repères : la barre latérale et sa ligne choisie, le badge
/// orange d'« Aujourd'hui », trois tâches. Des traits et pas du texte : à cette taille, des lettres ne
/// seraient que du bruit.
private struct MiniWindow: View {
  let palette: MiniPalette

  private static let rows: [CGFloat] = [40, 30, 36]

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 3) {
          ForEach([NSColor.systemRed, .systemYellow, .systemGreen], id: \.self) { color in
            Circle().fill(Color(nsColor: color)).frame(width: 4.5, height: 4.5)
          }
        }
        .padding(.bottom, 5)
        sidebarRow(selected: false, width: 24)
        sidebarRow(selected: true, width: 28)
        sidebarRow(selected: false, width: 20)
        Spacer(minLength: 0)
      }
      .padding(7)
      .frame(width: 52, alignment: .leading)
      .frame(maxHeight: .infinity, alignment: .top)
      .background(palette.sidebar)

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 4) {
          RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(palette.accent.opacity(0.25))
            .frame(width: 9, height: 9)
            .overlay { Circle().fill(palette.accent).frame(width: 4, height: 4) }
          Capsule().fill(palette.strong).frame(width: 30, height: 5)
        }
        .padding(.bottom, 2)
        ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, width in
          HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
              .strokeBorder(palette.accent, lineWidth: 1)
              .frame(width: 6, height: 6)
            Capsule().fill(palette.line).frame(width: width, height: 4)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 9)
      .padding(.top, 20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(palette.window)
    }
  }

  private func sidebarRow(selected: Bool, width: CGFloat) -> some View {
    HStack(spacing: 3) {
      Circle().fill(selected ? palette.accent : palette.line).frame(width: 4, height: 4)
      Capsule().fill(palette.line).frame(width: width, height: 3.5)
    }
    .padding(.horizontal, 3)
    .frame(height: 9)
    .background(
      selected ? palette.selection : .clear,
      in: RoundedRectangle(cornerRadius: 2.5, style: .continuous))
  }
}

// MARK: - Écran 4 : la capsule

private struct QuickEntryScreen: View {
  let capturedTitle: String?
  let userName: String

  /// La combinaison vit dans des clés de défauts, pas dans un état de vue : sans ces observations,
  /// les touches dessinées garderaient l'ancienne après un passage par l'enregistreur. Le LIBELLÉ
  /// et pas le seul code : passer de ⌃Espace à ⌥Espace ne change pas le code de la touche.
  @AppStorage(GlobalHotKey.keyCodeStorageKey) private var keyCode = GlobalHotKey.quickEntryDefault
    .keyCode
  @AppStorage(GlobalHotKey.labelStorageKey) private var label = GlobalHotKey.quickEntryDefault.label

  private var combo: Binding<KeyCombo?> {
    Binding(
      get: { keyCode >= 0 ? GlobalHotKey.current : nil },
      set: { GlobalHotKey.store($0) })
  }

  var body: some View {
    Group {
      if let capturedTitle {
        captured(capturedTitle).onboardingColumn().transition(.opacity)
      } else {
        waiting.transition(.opacity)
      }
    }
  }

  private var waiting: some View {
    let caps = keyCode >= 0 ? Onboarding.keycaps(for: label) : []
    let usable = !caps.isEmpty && GlobalHotKey.shared.isQuickEntryRegistered
    return VStack(spacing: 16) {
      MacShowcase(scene: .quickEntry, userName: userName)

      VStack(spacing: 16) {
        Headline(
          title: "Le raccourci à retenir",
          lede:
            "Il ouvre une barre de saisie par-dessus n'importe quelle app. Essayez-le maintenant."
        )

        if !caps.isEmpty {
          HStack(spacing: 8) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in Keycap(cap, size: 46) }
          }
          .opacity(usable ? 1 : 0.45)
        }

        waitingControls(usable: usable, noCombo: caps.isEmpty)
      }
      .onboardingColumn()
    }
  }

  /// Sous les touches : ce qui se passe une fois la capsule ouverte, ou pourquoi elle ne s'ouvrira pas.
  @ViewBuilder private func waitingControls(usable: Bool, noCombo: Bool) -> some View {
    if usable {
      Label {
        Text("Appuyez sur ces touches en même temps")
      } icon: {
        Image(systemName: "circle.fill")
          .font(.system(size: 7))
          .foregroundStyle(PageTint.today)
          .symbolEffect(.pulse)
      }
      .font(.app(13))
      .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 6) {
        instruction(
          1,
          Text(
            "Tapez \(Text("auj").font(.app(13, design: .monospaced))) puis ↩ pour choisir Aujourd'hui"
          ))
        instruction(2, Text("Écrivez votre tâche puis ↩"))
      }
    } else {
      Text(
        noCombo
          ? "Aucun raccourci n'est défini. Choisissez-en un :"
          : "Ce raccourci est déjà utilisé par une autre app. Choisissez-en un autre :"
      )
      .font(.app(13.5))
      .foregroundStyle(.secondary)
    }

    HStack(spacing: 10) {
      Text(usable ? "Changer le raccourci" : "Raccourci")
        .font(.app(13))
        .foregroundStyle(.secondary)
      HotKeyRecorder(combo: combo, width: 150)
    }
  }

  private func instruction(_ number: Int, _ text: Text) -> some View {
    HStack(spacing: 10) {
      Text("\(number)")
        .font(.app(11.5, weight: .bold))
        .frame(width: 22, height: 22)
        .background(rowSelectionFill, in: Circle())
      text.font(.app(14))
    }
  }

  private func captured(_ title: String) -> some View {
    VStack(spacing: 20) {
      DrawnCheck().frame(width: 74, height: 74)
      Headline(
        title: "C'est noté",
        lede:
          "« \(title) » vous attend dans Today. Le raccourci marche aussi quand l'app est en arrière-plan."
      )
    }
  }
}

private struct DrawnCheck: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drawn = false

  var body: some View {
    ZStack {
      Circle()
        .trim(from: 0, to: drawn ? 1 : 0)
        .stroke(PageTint.today, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        .rotationEffect(.degrees(-90))
      CheckShape()
        .trim(from: 0, to: drawn ? 1 : 0)
        .stroke(
          PageTint.today, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
    }
    .padding(2)
    .onAppear {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7)) { drawn = true }
    }
  }
}

private struct CheckShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.width * 0.31, y: rect.height * 0.52))
    path.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.65))
    path.addLine(to: CGPoint(x: rect.width * 0.69, y: rect.height * 0.38))
    return path
  }
}

// MARK: - Écran 5 : Rappels et Calendrier

private struct RemindersScreen: View {
  let bridge: BridgeState
  let userName: String

  @Environment(RemindersService.self) private var remindersService
  @AppStorage(RemindersSync.pushStorageKey) private var push = false
  @AppStorage(RemindersSync.listStorageKey) private var listID = ""
  @AppStorage(RemindersSync.eventCalendarStorageKey) private var eventCalendarID = ""

  var body: some View {
    VStack(spacing: 16) {
      MacShowcase(scene: .reminders, userName: userName)

      VStack(spacing: 16) {
        Headline(
          title: "Rappels et Calendrier",
          lede:
            "Facultatif. Une tâche avec une date part dans Rappels, avec une durée dans Calendrier. Et ce que vous y changez revient ici."
        )

        VStack(spacing: 8) {
          BridgeRow(symbol: "checklist", color: .orange, name: "Rappels") { remindersControl }
          BridgeRow(symbol: "calendar", color: .red, name: "Calendrier") { calendarControl }
        }

        if case .answered(let reminders, let events) = bridge, !(reminders && events) {
          Text(
            "Vous pourrez l'autoriser plus tard dans Réglages Système ▸ Confidentialité et sécurité."
          )
          .font(.app(12.5))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        }
      }
      .onboardingColumn()
    }
  }

  @ViewBuilder private var remindersControl: some View {
    if case .answered(let granted, _) = bridge {
      if granted {
        // Choisir une liste, c'est ALLUMER l'envoi, et « Aucune » l'éteint : un menu posé sans que
        // rien ne parte serait un réglage à moitié branché.
        Picker(
          "Liste",
          selection: Binding(
            get: { listID },
            set: {
              listID = $0
              push = !$0.isEmpty
            })
        ) {
          Text("Aucune").tag("")
          ForEach(remindersService.writableLists, id: \.calendarIdentifier) { list in
            Text(list.title).tag(list.calendarIdentifier)
          }
        }
        // Sans libellé et à largeur fixe : le nom de la rangée dit déjà ce qu'on choisit, et les deux
        // menus s'alignent l'un sous l'autre.
        .labelsHidden()
        .frame(width: 210)
      } else {
        denied
      }
    }
  }

  @ViewBuilder private var calendarControl: some View {
    if case .answered(_, let granted) = bridge {
      if granted {
        Picker(
          "Calendrier",
          selection: Binding(
            get: { eventCalendarID },
            set: {
              eventCalendarID = $0
              remindersService.rememberEventCalendarName(for: $0)
            })
        ) {
          Text("Aucun").tag("")
          ForEach(remindersService.writableEventCalendars, id: \.calendarIdentifier) { calendar in
            Text(calendar.title).tag(calendar.calendarIdentifier)
          }
        }
        .labelsHidden()
        .frame(width: 210)
      } else {
        denied
      }
    }
  }

  private var denied: some View {
    Text("Accès refusé").font(.app(13)).foregroundStyle(.secondary)
  }
}

/// Une app d'Apple et son état : rien tant qu'on n'a pas connecté, son menu une fois l'accès donné.
/// Hauteur FIXE : sans elle, la rangée grandissait à l'arrivée du menu et tout l'écran sautait.
private struct BridgeRow<Control: View>: View {
  let symbol: String
  let color: Color
  let name: String
  @ViewBuilder var control: Control

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.app(15, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      Text(name).font(.app(14.5, weight: .semibold))
      Spacer(minLength: 0)
      control
    }
    .padding(.horizontal, 12)
    .frame(height: 52)
    .background(rowSelectionFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

// MARK: - Écran 6 : prêt

private struct ReadyScreen: View {
  let userName: String

  @AppStorage(GlobalHotKey.keyCodeStorageKey) private var keyCode = GlobalHotKey.quickEntryDefault
    .keyCode
  @AppStorage(GlobalHotKey.labelStorageKey) private var label = GlobalHotKey.quickEntryDefault.label

  var body: some View {
    VStack(spacing: 16) {
      MacShowcase(scene: .ready, userName: userName)

      VStack(spacing: 16) {
        Headline(
          title: "Tout est prêt", lede: "Les trois raccourcis qui servent tous les jours.")
        shortcuts
      }
      .onboardingColumn()
    }
  }

  private var shortcuts: some View {
    VStack(spacing: 8) {
      GestureRow(caption: "Nouvelle tâche") {
        Keycap("⌘", size: 30)
        Keycap("N", size: 30)
      }
      if keyCode >= 0 {
        GestureRow(caption: "Noter depuis n'importe quelle app") {
          ForEach(Array(Onboarding.keycaps(for: label).enumerated()), id: \.offset) { _, cap in
            Keycap(cap, size: 30)
          }
        }
      }
      GestureRow(caption: "@ pour dater, # pour ranger") {
        TokenChip(text: "@demain", tint: PageTint.upcoming)
        TokenChip(text: "#Courses", tint: PageTint.inbox)
      }
    }
  }
}

/// Une rangée et pas une tuile : trois tuiles côte à côte prenaient la largeur de leur contenu, et la
/// légende de la plus étroite se cassait sur quatre lignes. En rangées, les touches tiennent une
/// colonne FIXE et les légendes démarrent toutes au même bord.
private struct GestureRow<Keys: View>: View {
  let caption: String
  @ViewBuilder var keys: Keys

  var body: some View {
    HStack(spacing: 14) {
      // 170 : la largeur des deux jetons de l'exemple, les plus larges des trois rangées.
      HStack(spacing: 4) { keys }
        .frame(width: 170, height: 34, alignment: .leading)
      Text(caption)
        .font(.app(14))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(width: onboardingColumnWidth)
    .background(rowSelectionFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

private struct TokenChip: View {
  let text: String
  let tint: Color

  var body: some View {
    // `fixedSize` : dans une tuile qui partage sa largeur, un jeton se tronquait (« @dem… ») — un
    // exemple de syntaxe coupé n'enseigne plus rien.
    Text(text)
      .font(.app(13, design: .monospaced))
      .fixedSize()
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

// MARK: - Briques communes

private struct Headline: View {
  let title: String
  let lede: String

  var body: some View {
    VStack(spacing: 10) {
      Text(title)
        .font(.app(30, weight: .bold))
        .tracking(-0.6)
      Text(lede)
        .font(.app(15))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .multilineTextAlignment(.center)
  }
}

/// Une touche de clavier dessinée. Une touche est un OBJET : plus claire que la page en clair, plus
/// sombre en sombre, avec son épaisseur dessous — d'où les deux teintes doublées.
private struct Keycap: View {
  let label: String
  let size: CGFloat

  init(_ label: String, size: CGFloat) {
    self.label = label
    self.size = size
  }

  private static let face = dualColor(light: 0xFD_FDFD, dark: 0x3B_3B41)
  private static let edge = dualColor(
    light: 0x00_0000, dark: 0x00_0000, lightAlpha: 0.2, darkAlpha: 0.55)

  /// « Espace », « F5 » : une touche nommée est large, comme sur le clavier.
  private var isWide: Bool { label.count > 1 }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.19, style: .continuous)
    Text(label)
      .font(.app(isWide ? size * 0.25 : size * 0.42, weight: .medium, design: .rounded))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, isWide ? size * 0.4 : 0)
      .frame(minWidth: isWide ? size * 2.2 : size, minHeight: size, maxHeight: size)
      .background(Self.face, in: shape)
      .background { shape.fill(Self.edge).offset(y: size * 0.05) }
      .overlay { shape.strokeBorder(Self.edge, lineWidth: 0.5) }
  }
}

/// Neutre, comme la sélection des lignes (cf. `rowSelectionFill`) : le style proéminent natif prend
/// l'accent système, que la refonte a retiré de partout. La couleur reste au soleil et à la coche,
/// là où elle dit quelque chose.
private struct OnboardingButtonStyle: ButtonStyle {
  enum Kind { case prominent, quiet, bare }
  let kind: Kind

  func makeBody(configuration: Configuration) -> some View {
    OnboardingButtonLabel(kind: kind, isPressed: configuration.isPressed) { configuration.label }
  }
}

private struct OnboardingButtonLabel<Content: View>: View {
  let kind: OnboardingButtonStyle.Kind
  let isPressed: Bool
  @ViewBuilder var content: Content
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    content
      .font(.app(14, weight: .semibold))
      .foregroundStyle(foreground)
      .padding(.horizontal, kind == .bare ? 10 : 18)
      .frame(height: 34)
      .background {
        if kind != .bare { Capsule().fill(fill) }
      }
      .contentShape(Capsule())
      .scaleEffect(isPressed ? 0.97 : 1)
      .opacity(isEnabled ? 1 : 0.45)
  }

  private var foreground: Color {
    switch kind {
    case .prominent: return Color(nsColor: .windowBackgroundColor)
    case .quiet: return .primary
    case .bare: return .secondary
    }
  }

  private var fill: Color {
    kind == .prominent ? .primary : rowSelectionFill
  }
}

/// La largeur de la colonne de chaque écran. Nommée parce que les rangées de l'écran final la
/// prennent.
private let onboardingColumnWidth: CGFloat = 460

extension View {
  fileprivate func onboardingColumn() -> some View {
    frame(maxWidth: onboardingColumnWidth).padding(.horizontal, 24)
  }
}
