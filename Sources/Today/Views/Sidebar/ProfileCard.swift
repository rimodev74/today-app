import SwiftUI

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
