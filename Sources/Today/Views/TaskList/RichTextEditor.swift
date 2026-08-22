import AppKit
import SwiftUI

/// `NSTextView` en mode texte riche pour les notes de tâche/liste/projet : gras/italique via
/// `Cmd+B`/`Cmd+I` (menu Format natif, cf. `TodayApp`), liens détectés automatiquement à la
/// frappe et ajoutés/retirés via `Cmd+K` (panneau natif AppKit) ou clic droit → Supprimer le lien.
/// Remplace `AutoGrowingTextEditor` (texte brut) — même stratégie de taille intrinsèque
/// (`sizeThatFits` piloté par le layoutManager) ; le contenu est sérialisé en RTF (`NotesCodec`)
/// au lieu d'un `String` brut.
struct RichTextEditor: NSViewRepresentable {
  @Binding var data: Data
  var font: NSFont = .app()
  var textColor: NSColor = .labelColor
  /// Appelé sur Entrée ; `true` = géré (le retour à la ligne par défaut est supprimé),
  /// `false`/`nil` = comportement natif (insère un retour à la ligne).
  var handleReturn: ((_ shiftHeld: Bool) -> Bool)?
  /// Pose le focus clavier sur ce champ dès sa création (une seule fois, cf. `makeNSView`). Sert à
  /// ouvrir directement le clavier sur les notes (icône de survol) plutôt que sur le titre.
  var autoFocus: Bool = false
  /// Retrait INTÉRIEUR au champ, pas autour de lui. Un encadré de notes qui pose sa marge en SwiftUI
  /// (`.padding`) laisse cette marge hors de la vue texte : elle ne reçoit pas le clic, et sur une
  /// note vide (une seule ligne de haut) c'est la moitié du cadre visible qui ne fait rien — d'où
  /// l'impression d'un encart qui ne prend le focus qu'une fois sur deux. Ici, le cadre TOUT ENTIER
  /// est la vue texte.
  var insets: NSSize = .zero

  func makeNSView(context: Context) -> NSTextView {
    let textView = RichNoteTextView()
    textView.delegate = context.coordinator
    textView.isRichText = true
    textView.isAutomaticLinkDetectionEnabled = true
    // Seule la détection de lien est voulue. Le reste (correcteur orthographique, grammaire,
    // guillemets/tirets « intelligents », remplacement de texte) est ce qu'`isRichText` active par
    // défaut, et réécrirait silencieusement le contenu d'une note de tâche sans qu'on l'ait demandé.
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.drawsBackground = false
    textView.textContainerInset = insets
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.font = font
    textView.textColor = textColor
    textView.typingAttributes = [.font: font, .foregroundColor: textColor]
    textView.defaultFont = font
    textView.defaultTextColor = textColor
    textView.textStorage?.setAttributedString(NotesCodec.decode(data))
    context.coordinator.lastPushed = data
    return textView
  }

  func updateNSView(_ nsView: NSTextView, context: Context) {
    context.coordinator.parent = self
    // Posé ici plutôt que dans `makeNSView` : à la création, la vue n'a pas encore de fenêtre
    // (`nsView.window` est nil), un `DispatchQueue.main.async` était donc nécessaire — et ce délai
    // d'un tour de runloop est ce qui provoquait un flash visible à l'entrée en édition (le champ
    // devenait actif après, pas pendant, la pose du premier répondeur). `updateNSView` s'exécute
    // après l'insertion réelle dans la hiérarchie de fenêtre : la fenêtre est déjà là, la demande
    // peut être synchrone. Ne se déclenche qu'une fois (`didAutoFocus`), sinon un `data` externe
    // reposerait le focus à chaque frappe extérieure.
    if autoFocus, !context.coordinator.didAutoFocus {
      context.coordinator.didAutoFocus = true
      nsView.window?.makeFirstResponder(nsView)
    }
    // Contrairement à l'ancien `AutoGrowingTextEditor`, `font`/`textColor` ne sont réappliqués
    // qu'à la création (`makeNSView`) : ce garde sort avant toute réassignation. Sans risque tant
    // que les trois sites d'appel passent des constantes ; un futur appelant avec une valeur
    // variable dans le temps ne la verrait jamais reprise.
    // N'écrase le contenu que si `data` a changé depuis l'EXTÉRIEUR (chargement initial, autre
    // vue) — pas en écho de notre propre `textDidChange`, sinon le curseur saute à chaque frappe.
    guard data != context.coordinator.lastPushed else { return }
    nsView.textStorage?.setAttributedString(NotesCodec.decode(data))
    context.coordinator.lastPushed = data
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0,
      let textContainer = nsView.textContainer, let layoutManager = nsView.layoutManager
    else { return nil }
    // Le retrait intérieur est pris sur la largeur ET rendu à la hauteur : c'est de la place que
    // la vue texte occupe, pas de la place qu'on lui donne en plus.
    textContainer.containerSize = NSSize(
      width: max(width - 2 * insets.width, 1), height: .greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: textContainer)
    let contentHeight = layoutManager.usedRect(for: textContainer).height
    let lineHeight = layoutManager.defaultLineHeight(for: nsView.font ?? font)
    return CGSize(width: width, height: ceil(max(contentHeight, lineHeight)) + 2 * insets.height)
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  /// Isolé au fil principal comme tout AppKit : ses méthodes ne sont appelées que par NSTextView,
  /// qui n'existe que là. L'annotation n'ajoute aucune contrainte à l'exécution — elle ÉCRIT celle
  /// que le code tenait déjà de fait, pour que le compilateur puisse la vérifier.
  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: RichTextEditor
    /// Dernière valeur poussée dans `parent.data`, par nous-même ou vue de l'extérieur — distingue
    /// un écho de notre propre frappe (à ignorer dans `updateNSView`) d'un changement externe réel.
    var lastPushed = Data()
    /// `autoFocus` ne doit poser le focus qu'une fois, à la toute première insertion — pas à
    /// chaque `updateNSView` tant que `parent.autoFocus` reste `true`.
    var didAutoFocus = false

    init(_ parent: RichTextEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let encoded = NotesCodec.encode(textView.attributedString())
      lastPushed = encoded
      parent.data = encoded
    }

    // Conversion « - » en début de ligne → item de liste à tirets, avant l'insertion de l'espace.
    // Le garde `== " "` est aussi ce qui empêche la récursion : nos éditions programmatiques
    // ci-dessous repassent par `shouldChangeText(in:replacementString:)` mais avec un autre texte
    // que l'espace, donc retombent immédiatement sur `return true`.
    func textView(
      _ textView: NSTextView, shouldChangeTextIn affectedRange: NSRange,
      replacementString: String?
    ) -> Bool {
      guard replacementString == " " else { return true }
      let ns = textView.string as NSString
      let paraStart = ns.paragraphRange(for: NSRange(location: affectedRange.location, length: 0))
        .location
      let leadRange = NSRange(location: paraStart, length: affectedRange.location - paraStart)
      guard leadRange.length >= 0,
        NoteList.shouldConvert(typedLineStart: ns.substring(with: leadRange))
      else { return true }
      // Remplace le « - » tapé par « –\t » et pose le retrait suspendu ; l'espace qui a déclenché
      // la conversion est avalé (`return false`).
      guard textView.shouldChangeText(in: leadRange, replacementString: NoteList.prefix) else {
        return false
      }
      textView.textStorage?.replaceCharacters(
        in: leadRange, with: NSAttributedString(string: NoteList.prefix, attributes: listAttrs))
      textView.didChangeText()
      textView.setSelectedRange(
        NSRange(location: paraStart + (NoteList.prefix as NSString).length, length: 0))
      textView.typingAttributes = listAttrs
      return false
    }

    // Intercepte Entrée avant l'insertion native. Maj+Entrée dans une liste continue/quitte la
    // liste (cf. `handleListNewline`) ; sinon `handleReturn` décide (Entrée valide la tâche,
    // Maj+Entrée insère un retour à la ligne).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
      let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
      if shiftHeld, handleListNewline(textView) { return true }
      guard let handleReturn = parent.handleReturn else { return false }
      return handleReturn(shiftHeld)
    }

    /// Attributs d'un item de liste : police/couleur de la note + le style à retrait suspendu.
    private var listAttrs: [NSAttributedString.Key: Any] {
      [
        .font: parent.font, .foregroundColor: parent.textColor,
        .paragraphStyle: NoteList.paragraphStyle(),
      ]
    }

    /// Maj+Entrée dans un item de liste : nouvel item (marqueur repris) si l'item a du contenu ;
    /// sort de la liste (marqueur retiré, ligne vide normale) si l'item est vide. `false` hors
    /// liste — l'appelant retombe alors sur le comportement normal (retour à la ligne).
    /// ponytail: pas de gestion du Retour arrière sur le marqueur ; à ajouter si l'édition coince.
    private func handleListNewline(_ textView: NSTextView) -> Bool {
      let ns = textView.string as NSString
      let sel = textView.selectedRange()
      let paraRange = ns.paragraphRange(for: NSRange(location: sel.location, length: 0))
      let paragraph = ns.substring(with: paraRange)
      guard NoteList.isListItem(paragraph) else { return false }
      let plainAttrs: [NSAttributedString.Key: Any] = [
        .font: parent.font, .foregroundColor: parent.textColor,
      ]

      if NoteList.isEmptyItem(paragraph) {
        let stripRange = NSRange(
          location: paraRange.location, length: (NoteList.prefix as NSString).length)
        guard textView.shouldChangeText(in: stripRange, replacementString: "") else { return true }
        textView.textStorage?.replaceCharacters(
          in: stripRange, with: NSAttributedString(string: "", attributes: plainAttrs))
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: paraRange.location, length: 0))
        textView.typingAttributes = plainAttrs
        return true
      }

      let insertion = "\n" + NoteList.prefix
      guard textView.shouldChangeText(in: sel, replacementString: insertion) else { return true }
      textView.textStorage?.replaceCharacters(
        in: sel, with: NSAttributedString(string: insertion, attributes: listAttrs))
      textView.didChangeText()
      textView.setSelectedRange(
        NSRange(location: sel.location + (insertion as NSString).length, length: 0))
      textView.typingAttributes = listAttrs
      return true
    }
  }
}

/// Sous-classe qui reset les attributs de style quand du texte est collé — le texte garde son
/// contenu mais prend la police/couleur par défaut de la note, pas celles de sa source. Les images
/// collées sont ignorées (on ne colle que le texte brut).
final class RichNoteTextView: NSTextView {
  var defaultFont: NSFont?
  var defaultTextColor: NSColor?

  override func paste(_ sender: Any?) {
    let pasteboard = NSPasteboard.general
    let attrs: [NSAttributedString.Key: Any] = [
      .font: defaultFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: defaultTextColor ?? NSColor.labelColor,
    ]
    let sel = selectedRange()

    // Préférer le texte brut (string) plutôt que RTF pour éviter les images et styles complexes
    if let string = pasteboard.string(forType: .string) {
      guard shouldChangeText(in: sel, replacementString: string) else { return }
      textStorage?.replaceCharacters(
        in: sel, with: NSAttributedString(string: string, attributes: attrs))
      didChangeText()
      // Longueur UTF-16, pas `String.count` : un emoji compte pour deux et décalerait le curseur.
      setSelectedRange(NSRange(location: sel.location + (string as NSString).length, length: 0))
      return
    }

    // Sinon, essayer RTF mais filtrer les images et réappliquer les attributs
    if let rtfData = pasteboard.data(forType: .rtf),
      let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil)
    {
      // `setAttributes` REMPLACE le dictionnaire entier : la mise en forme de la source disparaît,
      // et les attachements (images) avec elle — vérifié, pas besoin de les retirer à part.
      let plain = NSMutableAttributedString(attributedString: attributed)
      plain.setAttributes(attrs, range: NSRange(location: 0, length: plain.length))
      guard shouldChangeText(in: sel, replacementString: plain.string) else { return }
      textStorage?.replaceCharacters(in: sel, with: plain)
      didChangeText()
      setSelectedRange(NSRange(location: sel.location + plain.length, length: 0))
      return
    }

    // Fallback : comportement natif
    super.paste(sender)
  }
}

/// « Fausses » listes à tirets pour les notes : un marqueur littéral « –\t » + un retrait suspendu,
/// plutôt qu'un `NSTextList`. Raison : `NSTextView` NE DESSINE PAS le marqueur d'un `NSTextList`
/// posé en simple métadonnée (vérifié : glyphes == caractères, comme du texte nu), et son
/// round-trip RTF passe par une listtable fragile. Un marqueur en vrai texte + `headIndent` se rend
/// toujours et traverse `NotesCodec` (texte + style de paragraphe) sans perte.
enum NoteList {
  /// Marqueur + tabulation : le texte de l'item démarre au taquet, aligné avec les lignes qui
  /// débordent (retrait suspendu).
  static let prefix = "–\t"

  static let indent: CGFloat = 18

  static func paragraphStyle() -> NSParagraphStyle {
    let s = NSMutableParagraphStyle()
    s.firstLineHeadIndent = 0
    s.headIndent = indent
    s.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
    return s
  }

  /// `-` seul en TOUT début de ligne (unique caractère avant le curseur) → convertir en item.
  static func shouldConvert(typedLineStart s: String) -> Bool { s == "-" }

  /// Le paragraphe est-il un item de liste (marqueur en tête) ?
  static func isListItem(_ paragraph: String) -> Bool { paragraph.hasPrefix(prefix) }

  /// Item de liste sans contenu (juste le marqueur, éventuel `\n` de fin ignoré).
  static func isEmptyItem(_ paragraph: String) -> Bool {
    guard isListItem(paragraph) else { return false }
    let content = paragraph.hasSuffix("\n") ? String(paragraph.dropLast()) : paragraph
    return content == prefix
  }
}
