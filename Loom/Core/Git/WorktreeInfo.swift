import Foundation

/// One entry from `git worktree list --porcelain`.
///
/// The porcelain format: each worktree is a paragraph of `key value` lines, with
/// optional `locked`, `prunable`, `bare`, `detached` boolean flags. Paragraphs are
/// separated by a blank line.
struct WorktreeInfo: Equatable {
    let path: URL
    let head: String
    /// `nil` when the worktree is in detached-HEAD mode.
    let branch: String?
    let isBare: Bool
    let isLocked: Bool
    let isPrunable: Bool

    static func parsePorcelain(_ output: String) throws -> [WorktreeInfo] {
        var result: [WorktreeInfo] = []
        let paragraphs = output.components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let info = try parseParagraph(trimmed) {
                result.append(info)
            }
        }
        return result
    }

    private static func parseParagraph(_ text: String) throws -> WorktreeInfo? {
        var path: URL?
        var head: String?
        var branch: String?
        var bare = false
        var locked = false
        var prunable = false
        var detached = false

        for line in text.split(separator: "\n") {
            let str = String(line)
            if let value = str.dropPrefix("worktree ") {
                path = URL(fileURLWithPath: value)
            } else if let value = str.dropPrefix("HEAD ") {
                head = value
            } else if let value = str.dropPrefix("branch ") {
                // Format: "branch refs/heads/<name>"
                branch = value.replacingOccurrences(of: "refs/heads/", with: "")
            } else if str == "bare" {
                bare = true
            } else if str == "detached" {
                detached = true
            } else if str == "locked" || str.hasPrefix("locked ") {
                locked = true
            } else if str == "prunable" || str.hasPrefix("prunable ") {
                prunable = true
            }
            // Unknown lines are tolerated — future-proof against new keys.
        }

        guard let path else { return nil }
        guard let head else { throw WorktreeError.parseFailure(reason: "missing HEAD line") }

        return WorktreeInfo(
            path: path,
            head: head,
            branch: detached ? nil : branch,
            isBare: bare,
            isLocked: locked,
            isPrunable: prunable
        )
    }
}

private extension String {
    /// Returns the substring after `prefix` if `self` starts with it, else nil.
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
