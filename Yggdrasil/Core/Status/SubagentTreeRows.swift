import Foundation

/// How a tab's running subagents are laid out under its sidebar row: plain
/// subagents first, then each running workflow with its agents beneath it.
enum SubagentTreeRows {
    enum Row: Equatable {
        case workflow(SubagentWorkflow, agents: Int)
        /// `indent` steps below the tab: a subagent's subagents go one
        /// deeper, and a workflow's agents one deeper than the workflow.
        case agent(SubagentInfo, indent: Int)

        var id: String {
            switch self {
            case let .workflow(workflow, _): "workflow:\(workflow.runID)"
            case let .agent(info, _): info.agentID
            }
        }
    }

    static func rows(_ subagents: [SubagentInfo]) -> [Row] {
        let plain = subagents.filter { $0.workflow == nil }
            .map { Row.agent($0, indent: max($0.spawnDepth - 1, 0)) }
        var order: [SubagentWorkflow] = []
        for workflow in subagents.compactMap(\.workflow) where !order.contains(workflow) {
            order.append(workflow)
        }
        let grouped = order.flatMap { workflow -> [Row] in
            let agents = subagents.filter { $0.workflow == workflow }
            return [.workflow(workflow, agents: agents.count)]
                + agents.map { .agent($0, indent: 1 + max($0.spawnDepth - 1, 0)) }
        }
        return plain + grouped
    }
}
