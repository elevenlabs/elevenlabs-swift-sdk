#if canImport(UIKit)
import SwiftUI

/// Terms & conditions presented before a conversation starts. "I agree" runs
/// the pending start action; "Cancel" (or swiping the sheet away) aborts it.
@available(iOS 16, macCatalyst 16, *)
struct ChatTermsSheetView: View {
    var terms: ChatWidgetTerms
    var onAgree: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()

            Text(terms.title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            ScrollView {
                MarkdownView(content: terms.body)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)
            }
            .padding(.bottom, 24)

            VStack(spacing: 12) {
                Button(action: onAgree) {
                    Text(terms.agreeButton)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onCancel) {
                    Text(terms.cancelButton)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#endif
