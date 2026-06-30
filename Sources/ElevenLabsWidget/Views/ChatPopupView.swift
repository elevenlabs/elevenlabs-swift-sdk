#if canImport(UIKit)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

@available(iOS 16, macCatalyst 16, *)
struct ChatPopupView: View {
    @ObservedObject var vm: ChatWidgetViewModel
    let widgetConfig: ChatWidgetConfig
    @Binding var detent: ChatDrawerDetent
    var onClose: () -> Void
    @State private var isFileImporterPresented: Bool = false
    @State private var isPhotosPickerPresented: Bool = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var dragOffset: CGFloat = 0
    @State private var isFeedbackSheetPresented: Bool = false
    @State private var isTermsSheetPresented: Bool = false
    @State private var pendingStart: (() -> Void)?
    @State private var suppressComposerAutocorrect: Bool = false
    @FocusState private var isInputFocused: Bool
    private let drawerCornerRadius: CGFloat = 36
    
    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            errorBanner
            modeLayout
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.errorBannerMessage)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: drawerCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: drawerCornerRadius,
                style: .continuous
            )
            .fill(Color.white)
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .shadow(color: .black.opacity(0.18), radius: 24, y: -4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isInputFocused = false
        }
        .offset(y: dragOffset)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image, .pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                vm.uploadFile(url: url)
            case .failure:
                break
            }
        }
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $photoPickerItem,
            matching: .images
        )
        .onChange(of: photoPickerItem) { _ in
            guard let item = photoPickerItem else { return }
            handlePickedPhoto(item)
        }
        .onChange(of: vm.endedConversation) { _ in
            presentFeedbackIfNeeded()
        }
        .onChange(of: vm.messages.isEmpty) { _ in
            syncVoiceOnlyDetent()
        }
        .onAppear {
            presentFeedbackIfNeeded()
            syncVoiceOnlyDetent()
        }
        .task {
            // Text-only opens straight into typing: focus the field once the
            // drawer has finished animating in so the keyboard reliably appears.
            guard isTextOnly, vm.canShowTextInput else { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            isInputFocused = true
        }
        .sheet(isPresented: $isFeedbackSheetPresented) {
            ChatFeedbackSheetView(strings: widgetConfig.strings) { rating, comment in
                vm.submitFeedback(rating: rating, comment: comment)
                isFeedbackSheetPresented = false
            }
            .chatSheetPresentation(cornerRadius: drawerCornerRadius)
        }
    }
    
    /// In voice modes the drawer starts at half height and only expands to full
    /// height once messages are available and shown.
    private func syncVoiceOnlyDetent() {
        guard widgetConfig.conversationMode.supportsVoice else { return }
        let shouldExpand = vm.shouldShowMessages && !vm.messages.isEmpty
        let target: ChatDrawerDetent = shouldExpand ? .expanded : .compact
        guard detent != target else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            detent = target
        }
    }
    
    /// Presents the post-conversation feedback sheet once per ended conversation
    /// (and only when feedback collection is enabled). Dismissing the sheet –
    /// whether by submitting or collapsing it – will not re-trigger it.
    private func presentFeedbackIfNeeded() {
        guard widgetConfig.collectFeedbackAfterCall,
              let id = vm.endedConversation?.id,
              vm.shouldPromptFeedback(for: id) else { return }
        vm.markFeedbackHandled(for: id)
        isFeedbackSheetPresented = true
    }
    
    private func handlePickedPhoto(_ item: PhotosPickerItem) {
        Task {
            defer { photoPickerItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            guard let url = writePickedPhotoToTemporaryFile(data: data, item: item) else { return }
            await MainActor.run {
                vm.uploadFile(url: url)
            }
        }
    }
    
    private func writePickedPhotoToTemporaryFile(data: Data, item: PhotosPickerItem) -> URL? {
        let supported: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
        let pickedExtension = item.supportedContentTypes
            .compactMap { $0.preferredFilenameExtension?.lowercased() }
            .first { supported.contains($0) }
        
        let fileData: Data
        let fileExtension: String
        if let pickedExtension {
            fileData = data
            fileExtension = pickedExtension
        } else {
            // HEIC and other non-supported encodings: transcode to JPEG.
            guard let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
            fileData = jpeg
            fileExtension = "jpg"
        }
        
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try fileData.write(to: url)
            return url
        } catch {
            return nil
        }
    }
    
    private var dragHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 48, height: 5)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(handleDragGesture)
            .accessibilityElement()
            .accessibilityLabel(detent == .compact ? widgetConfig.strings.expandChatLabel : widgetConfig.strings.collapseChatLabel)
            .accessibilityAddTraits(.isButton)
            .onTapGesture {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                    detent = (detent == .compact) ? .expanded : .compact
                }
            }
            .sheet(isPresented: $isTermsSheetPresented) {
                ChatTermsSheetView(
                    terms: widgetConfig.terms,
                    onAgree: {
                        isTermsSheetPresented = false
                        let action = pendingStart
                        pendingStart = nil
                        action?()
                    },
                    onCancel: {
                        isTermsSheetPresented = false
                        pendingStart = nil
                    }
                )
                .chatSheetPresentation(cornerRadius: drawerCornerRadius)
            }
    }
    
    /// Gates a conversation-start action behind the Terms & conditions sheet.
    /// The provided action runs only after the user taps "I agree".
    private func requestStartConversation(_ action: @escaping () -> Void) {
        guard widgetConfig.enableTermsAndConditions else {
            action()
            return
        }
        isInputFocused = false
        pendingStart = action
        isTermsSheetPresented = true
    }
    
    /// Rubber-band resistance for drags in a direction that has no further detent
    /// (pulling up while expanded, or pulling up while compact). The sheet still
    /// follows the finger a little so the gesture feels alive, but with sharply
    /// diminishing travel instead of moving 1:1.
    private func rubberBand(_ translation: CGFloat) -> CGFloat {
        let limit: CGFloat = 56
        let magnitude = limit * (1 - 1 / (abs(translation) / limit + 1))
        return translation < 0 ? -magnitude : magnitude
    }
    
    private var handleDragGesture: some Gesture {
        let collapseSpring = Animation.spring(response: 0.42, dampingFraction: 0.85)
        let dismissThreshold: CGFloat = 100
        let expandThreshold: CGFloat = -60
        let flingToCloseThreshold: CGFloat = 220
        
        // Measure in the global space: the gesture is attached to views inside the
        // sheet, which is itself moved by `.offset(y: dragOffset)`. A local
        // coordinate space would shift with that offset and feed back into
        // `translation`, making the sheet jitter when held. Global stays fixed.
        return DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let t = value.translation.height
                // Downward always follows the finger (collapse / dismiss preview).
                // Upward has no taller detent to reveal, so it tugs with resistance
                // as a hint that releasing will expand (from compact) or do nothing
                // (from expanded).
                dragOffset = t >= 0 ? t : rubberBand(t)
            }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.height
                
                switch detent {
                case .expanded:
                    // A strong downward drag closes the sheet in a single motion;
                    // a softer one drops to the compact detent. On close we keep the
                    // current drag offset so the exit transition continues from where
                    // the finger let go rather than snapping back to center first.
                    if predicted > flingToCloseThreshold {
                        onClose()
                    } else if predicted > dismissThreshold {
                        withAnimation(collapseSpring) {
                            detent = .compact
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(collapseSpring) { dragOffset = 0 }
                    }
                case .compact:
                    if predicted > dismissThreshold {
                        onClose()
                    } else if predicted < expandThreshold {
                        withAnimation(collapseSpring) {
                            detent = .expanded
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(collapseSpring) { dragOffset = 0 }
                    }
                }
            }
    }
    
    private var isTextOnly: Bool { widgetConfig.conversationMode == .textOnly }
    private var isVoiceOnly: Bool { widgetConfig.conversationMode == .voiceOnly }
    private var textOnlyStarted: Bool { !vm.messages.isEmpty || vm.endedConversation != nil }
    
    private func chatOrb(size: CGFloat) -> some View {
        ChatOrbView(state: vm.orbState, agentLevels: vm.outputLevels, userLevels: vm.inputLevels, size: size, theme: widgetConfig.theme)
    }

    /// Invisible placeholder that reserves layout space for the orb and records
    /// its frame so the real (single) orb can be positioned/scaled to match.
    private func orbSlot(_ id: String, size: CGFloat) -> some View {
        Color.clear
            .frame(width: size, height: size)
            .anchorPreference(key: OrbAnchorPreferenceKey.self, value: .bounds) { [id: $0] }
    }
    
    @ViewBuilder
    private var modeLayout: some View {
        if isVoiceOnly {
            voiceOnlyHeader
            if voiceShowsTranscript {
                ChatTranscriptView(vm: vm, widgetConfig: widgetConfig, isInputFocused: $isInputFocused)
                voiceOnlyControls
                    .padding(.top, -Self.transcriptOverlap)
                    .zIndex(1)
            } else {
                Spacer(minLength: 0)
                voiceOnlyControls
                Spacer(minLength: 0)
            }
        } else if isTextOnly {
            textOnlyHeaderAndBody
            overlappingFooter(centered: !textOnlyStarted)
        } else {
            mixedHeaderAndBody
            overlappingFooter(centered: mixedShowsCenteredOrb)
        }
    }

    /// The input bar. In the transcript layout it's pulled up to overlap the
    /// scroll view (so content fades behind it); while the orb is centered it
    /// sits below as a normal sibling so the orb stays centered above it.
    @ViewBuilder
    private func overlappingFooter(centered: Bool) -> some View {
        ChatInputBar(
            vm: vm,
            widgetConfig: widgetConfig,
            isInputFocused: $isInputFocused,
            suppressComposerAutocorrect: $suppressComposerAutocorrect,
            isFileImporterPresented: $isFileImporterPresented,
            isPhotosPickerPresented: $isPhotosPickerPresented,
            requestStartConversation: requestStartConversation,
            endConversation: endConversation
        )
        .padding(.top, centered ? 0 : -Self.transcriptOverlap)
        .zIndex(1)
    }
    
    // MARK: - Text-only layout
    
    private static let headerOrbSize: CGFloat = 36
    private static let heroOrbSize: CGFloat = 128
    /// Floor for the centered hero orb when vertical space is tight (e.g.
    /// landscape) so the header + input bar always stay on screen.
    private static let heroOrbMinSize: CGFloat = 72

    /// How far the bottom view (input bar / orb) overlaps the transcript so
    /// content slides behind it.
    private static let transcriptOverlap: CGFloat = 20

    /// Single persistent orb drawn in an overlay above the body content. It
    /// glides/scales between the centered hero slot ("center") and the header
    /// corner slot ("header"). Living in the overlay keeps it visually
    /// decoupled from message-list reflow, so the morph stays smooth even as
    /// bubbles insert. `showStartButton` overlays the start-call affordance on
    /// the centered orb (used by the mixed voice+text layout).
    @ViewBuilder
    private func persistentOrbOverlay(
        anchors: [String: Anchor<CGRect>],
        centered: Bool,
        showStartButton: Bool
    ) -> some View {
        GeometryReader { proxy in
            let key = centered ? "center" : "header"
            // Fall back to the header corner when the centered hero slot is
            // absent (too little room for it, e.g. keyboard up in landscape) so
            // the orb tucks into the corner instead of disappearing.
            if let anchor = anchors[key] ?? anchors["header"] {
                let rect = proxy[anchor]
                let base = Self.heroOrbSize
                chatOrb(size: base)
                    .scaleEffect(rect.width / base)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            if showStartButton, centered, let center = anchors["center"] {
                let rect = proxy[center]
                startCallButton(size: 54, font: .title3.weight(.semibold), shadow: true)
                    .position(x: rect.midX, y: rect.maxY - 3)
                    .transition(.opacity)
            }
        }
    }

    /// Drawer header with the centered title. When `showsOrbSlot` is true it
    /// also reserves the leading corner slot the persistent orb lands on (kept
    /// reserved at all times so the header height never shifts).
    private func drawerHeader(showsOrbSlot: Bool = true) -> some View {
        ZStack {
            Text(widgetConfig.strings.title)
                .font(.headline)
            if showsOrbSlot {
                HStack {
                    orbSlot("header", size: Self.headerOrbSize)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .gesture(handleDragGesture)
    }

    /// Shared scaffold for the text-only and mixed layouts: a header, a body
    /// that's either the centered hero (with `centeredBody`) or the scrollable
    /// transcript, plus the single persistent orb gliding between the two.
    private func headerAndBody<CenteredBody: View>(
        centered: Bool,
        showStartButton: Bool,
        @ViewBuilder centeredBody: () -> CenteredBody
    ) -> some View {
        VStack(spacing: 0) {
            drawerHeader()
            if centered {
                centeredBody()
            } else {
                ChatTranscriptView(vm: vm, widgetConfig: widgetConfig, isInputFocused: $isInputFocused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayPreferenceValue(OrbAnchorPreferenceKey.self) { anchors in
            persistentOrbOverlay(anchors: anchors, centered: centered, showStartButton: showStartButton)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: centered)
    }

    private var textOnlyHeaderAndBody: some View {
        headerAndBody(centered: !textOnlyStarted, showStartButton: false) {
            centeredHeroOrb(reservesStartButton: false) { EmptyView() }
        }
    }
    
    /// Centers the hero orb in the space left between the header and the input
    /// bar. Those are laid out first; the orb fits into the remaining height,
    /// shrinking from `heroOrbSize` toward `heroOrbMinSize` when space is tight
    /// (landscape / short sheets) so it never pushes the input bar off screen.
    /// It stays centered via the equal spacers. `reservesStartButton` keeps room
    /// for the start-call affordance that hangs just below the orb so the
    /// orb+button group is centered as a unit.
    private func centeredHeroOrb<Below: View>(
        reservesStartButton: Bool,
        @ViewBuilder below: () -> Below
    ) -> some View {
        let belowView = below()
        return GeometryReader { geo in
            let reserved: CGFloat = reservesStartButton ? 24 : 0
            let margin: CGFloat = 12
            let fit = geo.size.height - reserved - margin * 2
            let orbSize = max(Self.heroOrbMinSize, min(Self.heroOrbSize, fit))
            // When even the minimum orb can't fit (keyboard up in landscape),
            // omit the centered slot. With no "center" anchor the overlay falls
            // back to the header corner, so the orb tucks up there instead of
            // overlapping the header / input bar.
            let showsOrb = fit >= Self.heroOrbMinSize
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if showsOrb {
                    orbSlot("center", size: orbSize)
                    belowView
                    if reservesStartButton {
                        Color.clear.frame(height: reserved)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
    
    // MARK: - Voice-only layout
    
    private var voiceOnlyHeader: some View {
        drawerHeader(showsOrbSlot: false)
    }
    
    /// Voice-only shows the transcript container (with the orb beneath it) once
    /// messages exist and are enabled; before that the orb stays centered.
    private var voiceShowsTranscript: Bool {
        vm.shouldShowMessages && (!vm.messages.isEmpty || vm.endedConversation != nil)
    }
    
    private var voiceOnlyControls: some View {
        Group {
            if vm.canStartVoiceConversation {
                ZStack(alignment: .bottom) {
                    chatOrb(size: 128)
                    startCallButton(size: 56, font: .title3.weight(.semibold), shadow: true)
                        .offset(y: 26)
                }
                .padding(.bottom, 26)
            } else {
                HStack(spacing: 28) {
                    if widgetConfig.enableMicMuteControl {
                        ChatMicButton(vm: vm, inputLevels: vm.inputLevels, diameter: 56, theme: widgetConfig.theme)
                            .disabled(!vm.canToggleMicMute)
                            .opacity(vm.canToggleMicMute ? 1 : 0.4)
                    } else {
                        Color.clear.frame(width: 56, height: 56)
                    }
                    chatOrb(size: 128)
                    voiceStopButton
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: vm.canStartVoiceConversation)
    }
    
    private var voiceStopButton: some View {
        Button(action: endConversation) {
            ZStack {
                Circle()
                    .fill(widgetConfig.theme.destructive)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(widgetConfig.strings.endConversationLabel)
    }
    
    // MARK: - Mixed voice+text layout

    /// True while the orb should sit centered as a hero (before the first
    /// message / while voice messages are hidden) rather than in the header.
    private var mixedShowsCenteredOrb: Bool {
        if !vm.shouldShowMessages { return true }
        return shouldShowCenteredHeroOnly
    }

    private var mixedHeaderAndBody: some View {
        headerAndBody(
            centered: mixedShowsCenteredOrb,
            showStartButton: vm.canStartVoiceConversation
        ) {
            centeredHeroOrb(reservesStartButton: vm.canStartVoiceConversation) {
                if !vm.shouldShowMessages && vm.hasActiveConversation {
                    Text(widgetConfig.strings.messagesHiddenNotice)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                        .padding(.horizontal)
                }
            }
        }
    }

    /// Transient failure banner. Mirrors the input bar's shape/treatment and
    /// self-dismisses (see the view model), with a manual dismiss too.
    @ViewBuilder
    private var errorBanner: some View {
        if let message = vm.errorBannerMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if vm.errorBannerShowsOpenSettings {
                    Button {
                        vm.openAppSettings()
                    } label: {
                        Text(widgetConfig.strings.settings)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 4)
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(widgetConfig.strings.openSettingsLabel)
                }
                Button {
                    vm.dismissErrorBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(widgetConfig.strings.dismissLabel)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    
    private var shouldShowCenteredHeroOnly: Bool {
        vm.shouldShowCenterOrb &&
        vm.messages.isEmpty &&
        vm.endedConversation == nil &&
        vm.draftAttachment == nil &&
        !vm.isUploadingAttachment
    }
    
    private func startCallButton(
        size: CGFloat = 38,
        font: Font = .headline.weight(.semibold),
        shadow: Bool = false
    ) -> some View {
        Button {
            requestStartConversation(vm.startVoiceConversation)
        } label: {
            Image(systemName: "phone.fill")
                .font(font)
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Color.black, in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                )
                .shadow(color: shadow ? .black.opacity(0.18) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(widgetConfig.strings.startVoiceConversationLabel)
    }
    
    private func endConversation() {
        withAnimation(.easeInOut(duration: 0.25)) {
            vm.endConversation()
        }
    }
}



/// Captures the frames of the orb "slots" (centered hero vs header corner) so a
/// single persistent orb can be positioned/scaled between them in an overlay.
private struct OrbAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The pull handle shown at the top of the presented sheets.
struct SheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 48, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}

@available(iOS 16, macCatalyst 16, *)
private extension View {
    /// Common presentation styling so the feedback / terms sheets match the
    /// rounded, opaque-white look of the chat drawer.
    ///
    /// `presentationCornerRadius` and `presentationBackground` are iOS 16.4+;
    /// on iOS 16.0–16.3 the sheet falls back to system-default styling.
    @ViewBuilder
    func chatSheetPresentation(cornerRadius: CGFloat) -> some View {
        if #available(iOS 16.4, macCatalyst 16.4, *) {
            self.presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(cornerRadius)
                .presentationBackground(Color.white)
        } else {
            self.presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }
}

#endif
