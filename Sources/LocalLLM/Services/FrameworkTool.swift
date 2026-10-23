import Foundation
import FoundationModels

/// Phase 5: the Foundation Models side of the tool layer.
///
/// One @Generable arguments struct serves every tool — its fields are
/// exactly `ToolArgumentField`'s cases — so a single `FrameworkTool`
/// wrapper type can present any app tool to a framework session: the
/// per-tool identity (name + the description the model reads) rides
/// on the instance, and the call lands in the shared `ToolRuntime`,
/// which is where logging, gating, and clamping live.
///
/// The trade-off, honestly: the model sees one shared argument schema
/// rather than a bespoke struct per tool. With constrained generation
/// guaranteeing shape, the per-tool description ("Set query to the
/// keywords…") carries the rest — and in exchange there is exactly
/// one argument shape across the framework, MLX, and tests.
@Generable
struct ToolCallArguments {
    @Guide(description: "A search phrase or name, when the tool takes one.")
    var query: String?
    @Guide(description: "A full file or folder path, when the tool takes one.")
    var path: String?
    @Guide(description: "A math expression, for the calculator tool.")
    var expression: String?
    @Guide(description: "Text to write, for the clipboard tool.")
    var text: String?
    @Guide(description: "How many days ahead to look, when the tool takes one.")
    var days: Int?
    @Guide(description: "How many results to return at most, when the tool takes one.")
    var limit: Int?
    @Guide(description: "Which item, counting from the most recent (0 = most recent), when the tool takes one.")
    var index: Int?
}

extension ToolCallArguments {
    var coreArguments: ToolArguments {
        ToolArguments(query: query, path: path, expression: expression,
                      text: text, days: days, limit: limit, index: index)
    }
}

struct FrameworkTool: Tool {
    typealias Arguments = ToolCallArguments
    typealias Output = ToolOutput

    let name: String
    let description: String
    let runtime: ToolRuntime

    func call(arguments: ToolCallArguments) async throws -> ToolOutput {
        ToolOutput(await runtime.execute(
            toolName: name, arguments: arguments.coreArguments))
    }
}

/// The tool set for one session, as the backends consume it: the
/// runtime (execution) plus the descriptors it may offer. On-device
/// sessions wrap the descriptors as `FrameworkTool`s; the MLX backend
/// turns them into the library's tool specs with the runtime as the
/// dispatch target.
struct SessionTools: Sendable {
    let runtime: ToolRuntime
    let descriptors: [ToolDescriptor]
}
