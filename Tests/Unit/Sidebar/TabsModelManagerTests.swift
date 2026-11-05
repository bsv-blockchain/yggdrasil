import XCTest
@testable import Yggdrasil

/// The pinned Yggdrasil session's row in `TabsModel`.
final class TabsModelManagerTests: XCTestCase {
    private var db: YggdrasilDatabase!
    private var store: TabStore!
    private var model: TabsModel!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
        store = TabStore(database: db)
        model = TabsModel(store: store, database: db)
    }

    func testTheManagerIsNotATab() throws {
        let tab = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let manager = try store.ensureManager(worktreePath: "/data/manager", agentID: nil)
        model.reload()
        XCTAssertEqual(model.tabs.map(\.id), [tab.id])
        XCTAssertEqual(model.managerTab?.id, manager.id)
        try model.select(XCTUnwrap(manager.id))
        model.reload()
        XCTAssertEqual(model.selectedID, manager.id, "selecting it survives a reload")
        XCTAssertNil(model.selectedTabID, "but it isn't a selected tab")
    }
}
