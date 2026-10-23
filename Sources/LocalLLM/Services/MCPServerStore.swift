import Foundation

/// Phase 9: the user's local MCP servers, persisted as JSON in
/// UserDefaults — the same pattern as `EndpointStore`.
///
/// A server here is just a launch recipe (name, command, arguments,
/// enabled). Nothing runs because it's listed: the MCP manager
/// launches a server lazily, the first time a chat session needs
/// its tools, and only while it's enabled here AND the Power tools
/// master switch is on. Editing or removing a server here is also
/// what stops it (the manager watches the list and terminates
/// anything that's gone or switched off).
@MainActor
@Observable
final class MCPServerStore {

    private(set) var configs: [MCPServerConfig]

    private let defaultsKey = "LocalLLM.mcpServers.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.data(forKey: defaultsKey) {
            configs = MCPServerConfigCodec.decode(raw)
        } else {
            // No presets: an MCP server is the user's own program,
            // so there's nothing sensible to seed.
            configs = []
        }
    }

    func add(_ config: MCPServerConfig) {
        configs.append(config)
        persist()
    }

    func update(_ config: MCPServerConfig) {
        guard let index = configs.firstIndex(where: { $0.id == config.id })
        else { return }
        configs[index] = config
        persist()
    }

    func remove(id: UUID) {
        configs.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = configs.firstIndex(where: { $0.id == id })
        else { return }
        configs[index].isEnabled = enabled
        persist()
    }

    func config(for id: UUID) -> MCPServerConfig? {
        configs.first { $0.id == id }
    }

    var enabledConfigs: [MCPServerConfig] {
        configs.filter { $0.isEnabled }
    }

    private func persist() {
        if let data = MCPServerConfigCodec.encode(configs) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

/// Splitting the "arguments" text field in Settings into the
/// argument list a server launches with. Deliberately simple —
/// arguments are separated by spaces, so an argument that itself
/// contains a space can't be typed in this phase (the Settings copy
/// says so; the server list in the README repeats it).
enum MCPArgumentsField {

    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
    }

    static func text(for arguments: [String]) -> String {
        arguments.joined(separator: " ")
    }
}
