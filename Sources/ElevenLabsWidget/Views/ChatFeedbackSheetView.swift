#if canImport(UIKit)
import SwiftUI

/// Post-conversation feedback collected in a sheet presented above the chat
/// drawer. Star selection is held locally and only sent when the user taps
/// "Submit" – collapsing/swiping the sheet away discards it without submitting.
@available(iOS 16, macCatalyst 16, *)
struct ChatFeedbackSheetView: View {
    var strings: ChatWidgetStrings = .default
    var onSubmit: (Int?, String) -> Void

    @State private var rating: Int = 0
    @State private var comment: String = ""
    @FocusState private var isCommentFocused: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let starOutline = WidgetColor.starOutline

    var body: some View {
        VStack(spacing: 24) {
            SheetGrabber()

            VStack(spacing: 8) {
                Text(strings.initiateFeedback)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
                Text(strings.feedbackQuestion)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        rating = star
                    } label: {
                        RoundedStar()
                            .fill(star <= rating ? Color.black : Color.clear)
                            .overlay {
                                RoundedStar()
                                    .stroke(
                                        starOutline,
                                        style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                                    )
                                    .opacity(star <= rating ? 0 : 1)
                            }
                            .frame(width: 38, height: 38)
                            .animation(nil, value: rating)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(star) \(star == 1 ? strings.ratingStarUnitSingular : strings.ratingStarUnitPlural)")
                }
            }

            TextField(strings.followUpFeedbackPlaceholder, text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .focused($isCommentFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(starOutline.opacity(0.5), lineWidth: 1)
                )

            Button {
                isCommentFocused = false
                onSubmit(rating == 0 ? nil : rating, comment)
            } label: {
                Text(strings.submit)
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        (rating == 0 ? Color.black.opacity(0.35) : Color.black),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(rating == 0)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping anywhere outside the field resigns focus so the keyboard
            // drops and the Submit button is reachable (critical in landscape).
            isCommentFocused = false
        }
        .task {
            // Auto-raising the keyboard buries the form in landscape, where the
            // keyboard eats most of the height; only do it when there's room.
            guard verticalSizeClass == .regular else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            isCommentFocused = true
        }
    }
}

#endif
