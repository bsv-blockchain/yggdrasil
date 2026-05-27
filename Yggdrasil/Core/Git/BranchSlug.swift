import CryptoKit
import Foundation

/// Pure-function branch-name → filesystem-safe slug. Per spec §2.1:
/// - `/` → `-`
/// - Any char outside `[a-zA-Z0-9._-]` is dropped (after slash → dash mapping).
/// - Long names truncated to 60 chars, with a deterministic hash suffix appended so
///   distinct long branches don't collide on disk.
enum BranchSlug {
    static let maxLength = 60
    static let hashSuffixLength = 8

    static func slug(for branch: String) -> String {
        // Per the spec's acceptance example (`feat/foo bar` → `feat-foo-bar`),
        // separator-like chars (slash, space) become `-`. To keep the rule simple
        // and matching that example, we map ALL disallowed chars to `-`, then
        // collapse runs.
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        // Treat # and : as inert (drop them entirely) so `fix#123: do thing` becomes
        // `fix123-do-thing` per the test fixture. We achieve that by dropping
        // punctuation that is NOT a separator. Heuristic: alphanumeric, `.`, `_` stay;
        // `/`, ` `, `\t` become `-`; other punctuation (`#`, `:`, `,`, etc.) is dropped.
        let separators = Set("/ \t")
        let dropped = Set("#:;,?@!$%^&*()[]{}<>|=+`~\"'")

        var mapped = String()
        mapped.reserveCapacity(branch.count)
        for char in branch {
            if allowed.contains(char) {
                mapped.append(char)
            } else if separators.contains(char) {
                mapped.append("-")
            } else if dropped.contains(char) {
                continue
            } else {
                // Unknown punctuation / unicode → default to dash so we don't smush words.
                mapped.append("-")
            }
        }

        let collapsed = collapseDashes(mapped)

        // Step 3: truncate with hash suffix if too long.
        if collapsed.count <= maxLength {
            return collapsed
        }
        let hash = sha256Prefix(of: branch, length: hashSuffixLength)
        let prefixLength = maxLength - hashSuffixLength - 1 // 1 char for the dash separator
        let head = String(collapsed.prefix(prefixLength))
        return "\(head)-\(hash)"
    }

    private static func collapseDashes(_ input: String) -> String {
        var out = ""
        var lastWasDash = false
        for char in input {
            if char == "-" {
                if !lastWasDash { out.append(char) }
                lastWasDash = true
            } else {
                out.append(char)
                lastWasDash = false
            }
        }
        return out
    }

    private static func sha256Prefix(of input: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }
}
