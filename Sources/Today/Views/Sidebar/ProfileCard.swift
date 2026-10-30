import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Encart avatar + nom en haut de la sidebar. Purement indicatif : le nom et la photo
/// se modifient dans les Réglages (onglet « Général »), pas ici.
struct ProfileCard: View {
  @Environment(UserProfile.self) private var profile

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(profile: profile, size: 42)
      Text(profile.fullName)
        .font(.system(size: 18, weight: .semibold))
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 8)
  }
}

struct AvatarView: View {
  let profile: UserProfile
  let size: CGFloat

  var body: some View {
    Group {
      if let image = profile.avatarImage {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        // Repli : initiales sur un fond teinté, jamais un avatar générique gris.
        Circle()
          .fill(.tint.tertiary)
          .overlay {
            Text(profile.initials)
              .font(.system(size: size * 0.4, weight: .semibold))
              .foregroundStyle(.tint)
          }
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }
}

/// Le choix d'une photo de profil, partagé par les Réglages et l'accueil.
///
/// `NSOpenPanel` lancé depuis l'ACTION d'un bouton, jamais `.fileImporter` : SwiftUI présente celui-ci
/// depuis le layout, par le même pont que les popovers, et ordonner une fenêtre pendant le layout
/// tue le process (→ `PIEGES.md` § Fenêtres). La lecture et la réduction (`AvatarImage`) se font hors
/// du fil principal : décoder une photo d'appareil prend de quoi sentir l'à-coup.
enum AvatarPicker {
  /// `onPicked` reçoit les octets DÉJÀ réduits, prêts à stocker ; `onInvalid` sonne quand le fichier
  /// n'est pas une image lisible. Annuler le panneau n'appelle ni l'un ni l'autre.
  @MainActor
  static func choose(
    onPicked: @escaping @MainActor (Data) -> Void,
    onInvalid: @escaping @MainActor () -> Void = {}
  ) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        let data = await Task.detached(priority: .userInitiated) {
          (try? Data(contentsOf: url)).flatMap(AvatarImage.normalized)
        }.value
        if let data { onPicked(data) } else { onInvalid() }
      }
    }
  }
}
