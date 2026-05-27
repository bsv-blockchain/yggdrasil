import AppKit
import GRDB
import SwiftUI

/// Namespace for the NSAlert-based prompts shared by the AppKit Coding menu
/// (`CodingMenuController`) and any other call site that needs a quick repo
/// or agent picker. The prompts themselves live in `DebugMenuPrompts.swift`
/// as an extension; this enum's only job is to give them a home.
///
/// History: was a SwiftUI `Commands` struct providing the "Debug" (later
/// "Coding") top-level menu. SwiftUI's command routing stopped dispatching
/// once we added a `MenuBarExtra` Scene, so the menu was rebuilt in AppKit
/// (`CodingMenuController`). The struct stayed around to host the prompt
/// extension — converting to an enum namespace makes the residual role
/// obvious.
enum DebugMenu {}
