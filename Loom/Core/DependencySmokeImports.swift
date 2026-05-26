import Clibgit2
import Foundation
import GRDB
import KeychainAccess
import SwiftTerm

enum DependencySmokeImports {
    static let resolved: [String] = [
        "SwiftTerm",
        "GRDB",
        "Clibgit2",
        "KeychainAccess"
    ]

    /// Touch a symbol from each linked library so the linker keeps the references
    /// (proves dynamic linkage, not just import resolution).
    static func liveLinkageProbe() -> [String] {
        var versionMajor: Int32 = 0
        var versionMinor: Int32 = 0
        var versionRev: Int32 = 0
        git_libgit2_version(&versionMajor, &versionMinor, &versionRev)
        return [
            "libgit2 v\(versionMajor).\(versionMinor).\(versionRev)"
        ]
    }
}
