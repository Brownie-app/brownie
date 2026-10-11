import Foundation
import Domain
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Brownie's tools, in the shape Apple's framework wants.
///
/// The two describe the same idea and share no types. Brownie's `Domain.Tool` carries a JSON Schema as a
/// string and a closure taking `Data`, because that is what every HTTP brain wants. Apple's `Tool` is a
/// protocol with an associated argument type and a `GenerationSchema` built in Swift, because the framework
/// uses it to constrain decoding — the model is not allowed to emit a call that does not fit.
///
/// That constraint is the whole reason this file exists. A cloud brain can return a malformed tool call and
/// be asked again; a 3B model asked for a whole vault as JSON cannot be asked again usefully, which is how
/// `badResponse("no file map")` happened. Bridged this way, the arguments cannot come back malformed.
///
/// The schema translation covers what Brownie's tools actually declare — objects of strings, one array of
/// strings, and a `required` list — and refuses anything else loudly rather than silently dropping it, so a
/// tool that grows a shape this does not understand fails at construction instead of at three in the morning.
enum AppleToolBridge {}

#if canImport(FoundationModels)
@available(macOS 26, *)
extension AppleToolBridge {

    /// A `GenerationSchema` from the JSON Schema string a `Domain.Tool` carries.
    static func schema(forToolNamed name: String, json: String) throws -> GenerationSchema {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.unreadable(tool: name, "the parameters are not JSON")
        }
        return try GenerationSchema(root: dynamic(obj, named: name, tool: name), dependencies: [])
    }

    /// One node. Recursive, because a tool's parameters are a tree, however shallow Brownie's happen to be.
    static func dynamic(_ node: [String: Any], named name: String, tool: String) throws -> DynamicGenerationSchema {
        switch node["type"] as? String {
        case "object":
            let props = node["properties"] as? [String: Any] ?? [:]
            let required = Set(node["required"] as? [String] ?? [])
            // Sorted, so the schema a tool produces is the same every time: an argument order that moves
            // between runs is a prompt that moves between runs, and nothing downstream would explain why.
            let fields = try props.keys.sorted().map { key -> DynamicGenerationSchema.Property in
                guard let child = props[key] as? [String: Any] else {
                    throw BridgeError.unreadable(tool: tool, "the property \(key) is not an object")
                }
                return DynamicGenerationSchema.Property(name: key, description: child["description"] as? String,
                                                        schema: try dynamic(child, named: key, tool: tool),
                                                        isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, description: node["description"] as? String, properties: fields)
        case "array":
            guard let items = node["items"] as? [String: Any] else {
                throw BridgeError.unreadable(tool: tool, "the array \(name) does not say what it holds")
            }
            return DynamicGenerationSchema(arrayOf: try dynamic(items, named: name + "Item", tool: tool))
        case "string":
            // `anyOf` in Brownie's schemas means a closed set of words, which is exactly what guided
            // generation is best at: the model cannot invent a sixth option.
            if let choices = node["enum"] as? [String], !choices.isEmpty {
                return DynamicGenerationSchema(name: name, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case let other:
            throw BridgeError.unreadable(tool: tool, "the type \(other ?? "(missing)") on \(name) is not one this bridge knows")
        }
    }

    enum BridgeError: Error, CustomStringConvertible {
        case unreadable(tool: String, String)
        var description: String {
            if case .unreadable(let tool, let why) = self { return "the tool \(tool) cannot be given to Apple's model: \(why)" }
            return "tool bridge"
        }
    }
}

/// One of Brownie's tools, wearing Apple's protocol.
///
/// `Arguments` is `GeneratedContent` rather than a concrete Swift type because the tools are built at runtime
/// from JSON Schema — there is no type to name at compile time. The framework still constrains the model to
/// the schema; `jsonString` then hands the same bytes to the closure that every other brain's tool call does,
/// so a tool behaves identically whichever brain is driving it.
@available(macOS 26, *)
struct BridgedTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    private let body: @Sendable (Data) async throws -> ToolOutput
    /// Set when the tool said this is the end of the run, so the loop knows to stop asking.
    let finished: @Sendable () -> Void

    init(_ tool: Domain.Tool, finished: @escaping @Sendable () -> Void) throws {
        name = tool.name
        description = tool.description
        parameters = try AppleToolBridge.schema(forToolNamed: tool.name, json: tool.parametersSchema)
        body = tool.run
        self.finished = finished
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let out = try await body(Data(arguments.jsonString.utf8))
        if out.endsRun { finished() }
        return out.text
    }
}
#endif
