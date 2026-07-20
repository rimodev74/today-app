import SwiftUI
import UniformTypeIdentifiers

/// Encart avatar + nom en haut de la sidebar. Clic = éditer dans une popover.
struct ProfileCard: View {
  @Environment(UserProfile.self) private var profile
  @State private var isEditing = false

  var body: some View {
    Button {
      isEditing = true
    } label: {
      HStack(spacing: 10) {
        AvatarView(profile: profile, size: 34)
        Text(profile.fullName)
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .popover(isPresented: $isEditing, arrowEdge: .bottom) {
      ProfileEditor(profile: profile)
    }
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

private struct ProfileEditor: View {
  @Bindable var profile: UserProfile
  @State private var isImporting = false
  @State private var importError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        AvatarView(profile: profile, size: 52)
        VStack(alignment: .leading, spacing: 4) {
          Button("Choisir une photo…") { isImporting = true }
          if profile.avatarData != nil {
            Button("Retirer") { profile.avatarData = nil }
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.link)
      }

      TextField("Prénom", text: $profile.firstName)
      TextField("Nom", text: $profile.lastName)

      if let importError {
        Text(importError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .textFieldStyle(.roundedBorder)
    .padding(16)
    .frame(width: 280)
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
      importError = nil
      guard case .success(let url) = result else { return }
      // Sandbox : l'URL retournée par le fileImporter n'est lisible que dans cette portée.
      guard url.startAccessingSecurityScopedResource() else {
        importError = "Photo illisible."
        return
      }
      defer { url.stopAccessingSecurityScopedResource() }
      guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else {
        importError = "Ce fichier n'est pas une image valide."
        return
      }
      profile.avatarData = data
    }
  }
}
