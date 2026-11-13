import SwiftUI

/// A subagent's work as it happens: its task, what it said, the tools it
/// called and what came back. Read-only: a subagent has no terminal of its
/// own; it runs inside the tab's `claude`.
struct SubagentTranscriptView: View {
    let services: AppServices
    let tab: YggdrasilTab
    let selection: SubagentsModel.Selection

    @State private var loader = SubagentTranscriptLoader()
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private var isRunning: Bool {
        TabActions.runningSubagents(selection.tabID, services: services)
            .contains { $0.agentID == selection.info.agentID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(YggdrasilTheme.border(scheme))
                .frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if loader.entries.isEmpty {
                            Text(loader.missing ? "No transcript yet." : "Loading…")
                                .foregroundStyle(YggdrasilTheme.textMute(scheme))
                        }
                        ForEach(Array(loader.entries.enumerated()), id: \.offset) { _, entry in
                            row(entry)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(14)
                    .textSelection(.enabled)
                }
                .onChange(of: loader.entries.count) { _, _ in
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
        }
        .background(YggdrasilTheme.bgPane(scheme))
        // Keys come here, not to the hidden terminal under it, where Esc
        // would interrupt the agent and typing would send a prompt nobody
        // sees. Esc closes the view instead.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) {
            services.subagents.clearSelection()
            return .handled
        }
        .onAppear {
            loader.start(feed)
            takeFocus()
        }
        .onDisappear { loader.stop() }
        .onChange(of: selection.info.agentID) { _, _ in
            loader.start(feed)
            takeFocus()
        }
    }

    private static let bottom = "bottom"

    /// On a host the transcript is only reachable through its helper, for
    /// the conversation the subagent was listed in.
    private var feed: SubagentTranscriptLoader.Feed? {
        guard tab.hostID != nil else { return .local(path: selection.info.transcriptPath) }
        guard let host = services.host(for: tab), let conversation = selection.info.conversationID else { return nil }
        let source = TabActions.remoteSubagentSource(host)
        let directory = AgentSessionLocator.encode(cwd: tab.worktreePath)
        let agentID = selection.info.agentID
        return .remote { knownSize in
            try await source.tail(
                projectDirectory: directory, conversationID: conversation, agentID: agentID,
                maxBytes: AgentSessionProbe.maxTailBytes, knownSize: knownSize
            )
        }
    }

    /// After this runloop turn: selecting a tab focuses its terminal, which
    /// would otherwise win.
    private func takeFocus() {
        DispatchQueue.main.async { focused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                services.subagents.clearSelection()
            } label: {
                Label("Agent", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Back to the tab's agent")
            Text(selection.info.agentType)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(YggdrasilTheme.chipBg(scheme), in: Capsule())
            Text(selection.info.description)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if isRunning {
                ProgressView().controlSize(.small)
                Text("Running").foregroundStyle(YggdrasilTheme.textDim(scheme))
            } else {
                Text("Finished").foregroundStyle(YggdrasilTheme.textMute(scheme))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func row(_ entry: SubagentEntry) -> some View {
        switch entry {
        case let .prompt(text):
            VStack(alignment: .leading, spacing: 4) {
                Text("Task").font(.system(size: 10, weight: .semibold)).foregroundStyle(YggdrasilTheme.textMute(scheme))
                Text(text).font(.system(size: 12))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YggdrasilTheme.bgPaneSoft(scheme), in: RoundedRectangle(cornerRadius: 6))
        case let .text(text):
            Text(text).font(.system(size: 12))
        case let .toolCall(_, name, summary):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(YggdrasilTheme.accent)
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(YggdrasilTheme.textDim(scheme))
                    .lineLimit(2)
            }
        case let .toolResult(_, preview, isError):
            Text(preview.isEmpty ? "(no output)" : preview)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(isError ? YggdrasilTheme.statusErr(scheme) : YggdrasilTheme.textMute(scheme))
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Reads the transcript's tail, and again as it grows, only while the view
/// is on screen: on this Mac whenever the subagents folder changes, on a
/// host every few seconds through its helper. Parsing happens off the main
/// actor: the tail can be a megabyte.
@MainActor
@Observable
final class SubagentTranscriptLoader {
    enum Feed {
        case local(path: String)
        /// Fetches the tail, given the size already read so an unchanged
        /// file isn't sent again.
        case remote(fetch: @Sendable (UInt64?) async throws -> SubagentTail)
    }

    /// How long a host's transcript waits before it's fetched again.
    static let remoteInterval: Duration = .seconds(3)

    private(set) var entries: [SubagentEntry] = []
    private(set) var missing = false
    @ObservationIgnored private var watcher: WorktreeWatcher?
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// Bumped per start and per local read, so a slow read can't overwrite
    /// a newer one or another subagent's.
    @ObservationIgnored private var generation = 0

    /// nil: there's nothing to read, such as a host tab whose host is gone.
    func start(_ feed: Feed?) {
        stop()
        generation += 1
        entries = []
        missing = feed == nil
        switch feed {
        case let .local(path)?:
            readLocal(path)
            let directory = (path as NSString).deletingLastPathComponent
            let watcher = WorktreeWatcher(path: directory) { [weak self] in self?.readLocal(path) }
            watcher.start()
            self.watcher = watcher
        case let .remote(fetch)?:
            let current = generation
            poll = Task { [weak self] in
                var knownSize: UInt64?
                // One fetch at a time: the next waits for this one, which
                // has a deadline, so a slow link can't pile up ssh sessions.
                while !Task.isCancelled {
                    let reply = try? await withDeadline(TabActions.remoteDeadline) { try await fetch(knownSize) }
                    if case let .lines(data, size)? = reply {
                        knownSize = size
                        let parsed = await Task.detached {
                            SubagentTranscriptParser.entries(inTail: data, startsAtFileStart: true)
                        }.value
                        self?.show(parsed, generation: current)
                    } else if reply == SubagentTail.none {
                        self?.show(nil, generation: current)
                    }
                    // Unchanged, or the host couldn't be asked: keep what's shown.
                    try? await Task.sleep(for: Self.remoteInterval)
                }
            }
        case nil:
            break
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        poll?.cancel()
        poll = nil
    }

    private func readLocal(_ path: String) {
        generation += 1
        let current = generation
        Task {
            let parsed: [SubagentEntry]? = await Task.detached {
                guard let (data, fromStart) = try? LiveTranscriptFileSystem()
                    .readTail(path: path, maxBytes: AgentSessionProbe.maxTailBytes)
                else { return nil }
                return SubagentTranscriptParser.entries(inTail: data, startsAtFileStart: fromStart)
            }.value
            show(parsed, generation: current)
        }
    }

    private func show(_ parsed: [SubagentEntry]?, generation current: Int) {
        // A newer read, or another subagent, came in meanwhile.
        guard current == generation else { return }
        missing = parsed == nil
        if let parsed, parsed != entries { entries = parsed }
    }
}
