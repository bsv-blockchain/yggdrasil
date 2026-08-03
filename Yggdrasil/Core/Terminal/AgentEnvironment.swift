import Foundation

/// Per-agent environment variables (issue #47).
///
/// A coding-agent profile can carry extra environment variables — the motivating
/// case is one Claude profile per account, selected by an env var rather than by
/// re-authenticating. The values are handed to `startProcess(environment:)`
/// rather than exported inside the `-c` payload: shell argv is world-readable
/// via `ps`, and these values are frequently tokens.
///
/// Precedence: the variables reach the login+interactive shell we spawn, which
/// then sources the user's rc files. An rc file that exports the same name wins
/// — the agent is exec'd after those run.
enum AgentEnvironment {
    /// Parses the preferences editor's text into pairs. One `KEY=VALUE` per
    /// line; blank lines and `#` comments are ignored, and lines that can't be
    /// a variable (no `=`, empty key, whitespace in the key) are dropped rather
    /// than passed through as junk.
    ///
    /// Splits on `isNewline` rather than the literal `"\n"`: Swift treats CRLF
    /// as one grapheme, so a `"\n"` separator doesn't match it at all and text
    /// pasted from a CRLF source (a `.env` from a Windows checkout, a copied
    /// mail/wiki block) would collapse into a single bogus pair. Trims with
    /// `.whitespacesAndNewlines` for the same reason — `.whitespaces` is Zs +
    /// tab and excludes CR. A matched pair of surrounding quotes is stripped
    /// too, since the text people paste is usually a `.env` file.
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex ..< separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { continue }
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = unquoted(value)
        }
        return result
    }

    /// Drops one matched pair of surrounding `"` or `'`. An unmatched or
    /// interior quote is part of the value and stays.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'"
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// Inverse of `parse`, sorted by key so the editor doesn't reshuffle itself
    /// between reloads of an unordered dictionary.
    static func render(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0]!)" }.joined(separator: "\n")
    }

    /// Builds the `envp` array for `LocalProcess.startProcess(environment:)`, or
    /// nil when there's nothing to add — nil tells SwiftTerm to use its own
    /// defaults, which is what every profile without overrides should keep
    /// getting.
    ///
    /// A default of the same name is removed rather than merely preceded:
    /// duplicate keys in an envp array resolve to whichever the libc lookup
    /// finds first, which is not something to leave to chance.
    static func merged(defaults: [String], overrides: [String: String]) -> [String]? {
        guard !overrides.isEmpty else { return nil }
        let overridden = Set(overrides.keys)
        var result = defaults.filter { entry in
            guard let separator = entry.firstIndex(of: "=") else { return true }
            return !overridden.contains(String(entry[entry.startIndex ..< separator]))
        }
        result.append(contentsOf: overrides.keys.sorted().map { "\($0)=\(overrides[$0]!)" })
        return result
    }
}
