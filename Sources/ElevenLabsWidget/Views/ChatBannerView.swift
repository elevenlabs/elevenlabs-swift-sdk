#if os(iOS)
import SwiftUI

/// Failures and permission problems, shown across the top of the drawer.
@available(iOS 16, macCatalyst 16, *)
struct ChatBannerView: View {
    let banner: ChatWidgetBanner
    let strings: ChatWidgetStrings
    let theme: ChatWidgetTheme
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(theme.destructive)

            Text(banner.message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)

            if banner.offersSettings {
                Button(strings.openSettingsLabel, action: onOpenSettings)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(strings.dismissLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.destructiveTint)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
#endif
