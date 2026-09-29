import Foundation
import FoundationModels
import JarvisCore
import JarvisTools

// plan M02-M04 §3.8: a Python TOOLS `parameters` object as a FoundationModels
// `GenerationSchema`, so the on-device model is offered the same tools the Claude path serves.

/// Converts one catalog `ToolSchema` into the schema a `DynamicTool` hands FoundationModels.
///
/// The root is `DynamicGenerationSchema(name: "<tool>_args", description:, properties:)`.
/// A `string` property is `String`, or `anyOf` its values when it has an `enum`; `integer` is
/// `Int` and `boolean` is `Bool`. A property missing from `required` is optional. The
/// measured TOOLS use nothing else, so any other type, or an `enum` that is not a list of
/// strings, throws rather than being guessed at.
public enum SchemaBridge {
    public enum BridgeError: Error, Equatable, CustomStringConvertible {
        case notAnObject(tool: String)
        case unsupportedType(tool: String, property: String, type: String)
        case badEnum(tool: String, property: String)

        public var description: String {
            switch self {
            case .notAnObject(let tool):
                "\(tool): parameters are not a JSON object of type object"
            case let .unsupportedType(tool, property, type):
                "\(tool).\(property): unsupported type \(type)"
            case let .badEnum(tool, property):
                "\(tool).\(property): enum is not a non-empty list of strings"
            }
        }
    }

    public static func generationSchema(for tool: ToolSchema) throws -> GenerationSchema {
        try GenerationSchema(root: dynamicSchema(for: tool), dependencies: [])
    }

    static func dynamicSchema(for tool: ToolSchema) throws(BridgeError) -> DynamicGenerationSchema {
        guard let root = (try? PyJSON.loads(Data(tool.parametersJSON.utf8)))?.objectValue,
              root["type"]?.stringValue == "object" else {
            throw .notAnObject(tool: tool.name)
        }
        let required = Set((root["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        var properties: [DynamicGenerationSchema.Property] = []
        for member in root["properties"]?.objectValue?.members ?? [] {
            let spec = member.value.objectValue ?? JSONObject()
            properties.append(DynamicGenerationSchema.Property(
                name: member.key,
                description: spec["description"]?.stringValue,
                schema: try propertySchema(spec, tool: tool.name, property: member.key),
                isOptional: !required.contains(member.key)))
        }
        return DynamicGenerationSchema(name: "\(tool.name)_args", description: tool.description,
                                       properties: properties)
    }

    private static func propertySchema(_ spec: JSONObject, tool: String,
                                       property: String) throws(BridgeError) -> DynamicGenerationSchema {
        let type = spec["type"]?.stringValue ?? spec["type"].map { PyJSON.dumps($0) } ?? "(none)"
        if let choices = spec["enum"] {
            let values = (choices.arrayValue ?? []).compactMap(\.stringValue)
            guard type == "string", !values.isEmpty, values.count == choices.arrayValue?.count else {
                throw .badEnum(tool: tool, property: property)
            }
            return DynamicGenerationSchema(name: "\(tool)_\(property)", anyOf: values)
        }
        switch type {
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: throw .unsupportedType(tool: tool, property: property, type: type)
        }
    }
}
