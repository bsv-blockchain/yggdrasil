import Foundation

/// What a new tab's Claude starts with when the tab is for a PR to review
/// or an issue: a template the user sets globally (Settings ▸ Agents) and
/// per repository, filled in for that PR or issue.
enum StartingPrompt {
    enum Kind: String, CaseIterable {
        case review
        case issue
    }

    /// What an open asks for.
    enum Choice: Equatable {
        /// The template for the tab's PR or issue, if any.
        case template
        case none
        case custom(String)

        /// A `prompt` as the API and the New Session sheet take it: left out
        /// means the template, empty means none.
        init(_ value: String?) {
            if let value {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                self = trimmed.isEmpty ? .none : .custom(value)
            } else {
                self = .template
            }
        }
    }

    /// The PR or issue a tab is opened for.
    struct Subject: Equatable {
        let kind: Kind
        let number: Int
        /// Its page on GitHub. `{repo}` comes from here, not from the tab's
        /// repository: a fork's tab can be for its upstream's issue.
        let url: String
    }

    static let defaults: [Kind: String] = [
        .review: "/cr {number}",
        .issue: "/fix-issue {number}"
    ]

    static let placeholders = ["{number}", "{repo}", "{url}"]

    static func settingKey(_ kind: Kind) -> String {
        "startingPrompt.\(kind.rawValue)"
    }

    /// The repository's own template, else the global one, else the
    /// default. An empty template, at either level, is off.
    static func template(_ kind: Kind, repoOverride: String?, global: String?) -> String {
        repoOverride ?? global ?? defaults[kind] ?? ""
    }

    /// The template filled in, or nil when there's nothing to send.
    /// Unknown placeholders are left as they are.
    static func render(_ template: String, subject: Subject) -> String? {
        let filled = template
            .replacingOccurrences(of: "{number}", with: String(subject.number))
            .replacingOccurrences(of: "{repo}", with: repo(in: subject.url) ?? "")
            .replacingOccurrences(of: "{url}", with: subject.url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filled.isEmpty ? nil : filled
    }

    /// `owner/name` from a github.com PR or issue URL.
    private static func repo(in url: String) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
