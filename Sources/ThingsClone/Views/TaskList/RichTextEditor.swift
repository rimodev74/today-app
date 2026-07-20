import AppKit
import SwiftUI

/// `NSTextView` en mode texte riche pour les notes de tâche/liste/projet : gras/italique via
/// `Cmd+B`/`Cmd+I` (menu Format natif, cf. `ThingsCloneApp`), liens détectés automatiquement à la
/// frappe et ajoutés/retirés via `Cmd+K` (panneau natif AppKit) ou clic droit → Supprimer le lien.
/// Remplace `AutoGrowingTextEditor` (texte brut) — même stratégie de taille intrinsèque
/// (`sizeThatFits` piloté par le layoutManager) ; le contenu est sérialisé en RTF (`NotesCodec`)
/// au lieu d'un `String` brut.
struct RichTextEditor: NSViewRepresentable {
  @Binding var data: Data
  var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
  var textColor: NSColor = .labelColor
  /// Appelé sur Entrée ; `true` = géré (le retour à la ligne par défaut est supprimé),
  /// `false`/`nil` = comportement natif (insère un retour à la ligne).
  var handleReturn: ((_ shiftHeld: Bool) -> Bool)?

  func makeNSView(context: Context) -> NSTextView {
    let textView = NSTextView()
    textView.delegate = context.coordinator
    textView.isRichText = true
    textView.isAutomaticLinkDetectionEnabled = true
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.font = font
    textView.textColor = textColor
    textView.typingAttributes = [.font: font, .foregroundColor: textColor]
    textView.textStorage?.setAttributedString(NotesCodec.decode(data))
    context.coordinator.lastPushed = data
    return textView
  }

  func updateNSView(_ nsView: NSTextView, context: Context) {
    context.coordinator.parent = self
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
    textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: textContainer)
    let contentHeight = layoutManager.usedRect(for: textContainer).height
    let lineHeight = layoutManager.defaultLineHeight(for: nsView.font ?? font)
    return CGSize(width: width, height: ceil(max(contentHeight, lineHeight)))
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: RichTextEditor
    /// Dernière valeur poussée dans `parent.data`, par nous-même ou vue de l'extérieur — distingue
    /// un écho de notre propre frappe (à ignorer dans `updateNSView`) d'un changement externe réel.
    var lastPushed = Data()

    init(_ parent: RichTextEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let encoded = NotesCodec.encode(textView.attributedString())
      lastPushed = encoded
      parent.data = encoded
    }

    // Intercepte Entrée avant l'insertion native : `handleReturn` décide si elle doit être
    // avalée (retour `true`) ou laissée insérer un retour à la ligne comme d'habitude.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard selector == #selector(NSResponder.insertNewline(_:)),
        let handleReturn = parent.handleReturn
      else { return false }
      let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
      return handleReturn(shiftHeld)
    }
  }
}
