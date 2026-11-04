import Foundation

extension Error {
    /// What to show the user: an action's own explanation, otherwise the
    /// error's full description (`localizedDescription` drops the detail
    /// most of the app's errors carry, like which path or repo).
    var actionMessage: String {
        (self as? ActionError)?.errorDescription ?? String(describing: self)
    }
}

/// Why a user action couldn't run. The UI shows `errorDescription` in its
/// alert; other callers get the case.
enum ActionError: Error, Equatable, LocalizedError {
    case unknownTab(Int64)
    case unknownRepo(Int64)
    case unknownAgent(Int64)
    case unknownHost(Int64)
    /// `owner/name`
    case repoNotCloned(String)
    case notInTrackedRepo
    /// `owner/name` of a repo the app doesn't track.
    case repoNotTracked(String)
    /// Muting needs the first status poll: before it there's nothing to mute.
    case noStatusYet
    /// The tab's worktree isn't ready yet, or its setup failed.
    case tabNotReady
    case cannotRemoveDefaultAgent
    /// Something other than a git repository is already at this path.
    case folderExists(String)
    case moveInProgress
    /// The named parameter has a value the action doesn't accept.
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case let .unknownTab(id):
            "There's no tab \(id)."
        case let .unknownRepo(id):
            "There's no tracked repository \(id)."
        case let .unknownAgent(id):
            "There's no coding agent \(id)."
        case let .unknownHost(id):
            "There's no host \(id)."
        case .cannotRemoveDefaultAgent:
            "The default agent can't be removed. Make another agent the default first."
        case let .folderExists(path):
            "\(path) already exists but isn't a git repository. Remove it or choose another folder."
        case let .repoNotCloned(repo):
            "\(repo) isn't cloned on this Mac. Run it on a host, or set its location in Settings → Repositories."
        case .notInTrackedRepo:
            "This tab isn't inside a tracked repository."
        case let .repoNotTracked(slug):
            "\(slug) isn't tracked. Add it in Settings → Repositories."
        case .noStatusYet:
            "This tab has no status yet. Try again in a moment."
        case .tabNotReady:
            "This tab's worktree isn't ready."
        case .moveInProgress:
            "This tab is already moving."
        case let .invalidArgument(name):
            "Invalid \(name)."
        }
    }
}
