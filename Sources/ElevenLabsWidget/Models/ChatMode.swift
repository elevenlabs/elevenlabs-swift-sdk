#if canImport(UIKit)
/// Whether the active conversation is running in voice or text mode. Drives
/// transcript styling and which controls (mic vs. composer) are shown.
enum ChatMode {
    case voice
    case text
}

#endif
