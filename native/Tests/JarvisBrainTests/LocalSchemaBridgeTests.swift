import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import JarvisTools
import Testing

/// T3.6 (plan M02-M04 §3.8): every catalog schema becomes a `GenerationSchema` that says what
/// the catalog JSON says. `GenerationSchema` encodes as JSON Schema, so each converted schema
/// is compared with the Python TOOLS entry it came from, property by property. No model runs.
@Suite("M3 local model: SchemaBridge over all 46 catalog tools")
struct LocalSchemaBridgeTests {
    static func encoded(_ schema: GenerationSchema) throws -> JSONObject {
        let data = try JSONEncoder().encode(schema)
        return try #require(try PyJSON.loads(data).objectValue)
    }

    static func object(_ json: String) throws -> JSONObject {
        try #require(try PyJSON.loads(Data(json.utf8)).objectValue)
    }

    @Test("the catalog is the 46 TOOLS, in TOOLS order")
    func catalogIsComplete() {
        #expect(ToolCatalog.tools.count == 46)
        #expect(ToolCatalog.tools.map(\.name) == DataSourceMap.toolNames)
    }

    @Test("each of the 46 converts, and matches its catalog JSON", arguments: ToolCatalog.tools.map(\.name))
    func convertsAndMatches(_ name: String) throws {
        let tool = try #require(ToolCatalog.tools.first { $0.name == name })
        let schema = try SchemaBridge.generationSchema(for: tool)
        let got = try Self.encoded(schema)
        let want = try Self.object(tool.parametersJSON)

        #expect(got["type"] == .string("object"))
        #expect(got["title"] == .string("\(tool.name)_args"))
        #expect(got["description"] == .string(tool.description))

        let wantProps = try #require(want["properties"]?.objectValue)
        let gotProps = try #require(got["properties"]?.objectValue)
        #expect(got["x-order"] == .array(wantProps.keys.map(JSONValue.string)), "property order")
        #expect(Set(gotProps.keys) == Set(wantProps.keys))
        for member in wantProps.members {
            let spec = try #require(member.value.objectValue)
            let prop = try #require(gotProps[member.key]?.objectValue, "\(member.key)")
            #expect(prop["type"] == spec["type"], "\(tool.name).\(member.key) type")
            #expect(prop["enum"] == spec["enum"], "\(tool.name).\(member.key) enum")
            #expect(prop["description"] == spec["description"], "\(tool.name).\(member.key) description")
        }

        let wantRequired = Set((want["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        let gotRequired = Set((got["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        #expect(gotRequired == wantRequired, "required")
    }

    @Test("the enums the plan names come through as anyOf strings")
    func enums() throws {
        let enums = try ToolCatalog.tools.flatMap { tool in
            try Self.object(tool.parametersJSON)["properties"]?.objectValue?.members
                .filter { $0.value.objectValue?["enum"] != nil }
                .map { "\(tool.name).\($0.key)" } ?? []
        }
        #expect(enums == ["music_search.by", "music_control.action"])
        let control = try Self.encoded(SchemaBridge.generationSchema(
            for: try #require(ToolCatalog.tools.first { $0.name == "music_control" })))
        #expect(control["properties"]?.objectValue?["action"]?.objectValue?["enum"]
            == .array(["play", "pause", "next", "previous"].map(JSONValue.string)))
    }

    @Test("a type the TOOLS do not use throws", arguments: ["number", "array", "object", "null"])
    func otherTypesThrow(_ type: String) {
        let tool = ToolSchema(name: "probe", description: "d",
                              parametersJSON: #"{"type": "object", "properties": {"x": {"type": "\#(type)"}}, "required": []}"#)
        #expect(throws: SchemaBridge.BridgeError.unsupportedType(tool: "probe", property: "x", type: type)) {
            try SchemaBridge.generationSchema(for: tool)
        }
    }

    @Test("a malformed schema throws")
    func malformedThrows() {
        let cases: [(String, SchemaBridge.BridgeError)] = [
            (#"{"type": "array"}"#, .notAnObject(tool: "probe")),
            (#"not json"#, .notAnObject(tool: "probe")),
            (#"{"type": "object", "properties": {"x": {}}}"#,
             .unsupportedType(tool: "probe", property: "x", type: "(none)")),
            (#"{"type": "object", "properties": {"x": {"type": "integer", "enum": [1, 2]}}}"#,
             .badEnum(tool: "probe", property: "x")),
            (#"{"type": "object", "properties": {"x": {"type": "string", "enum": []}}}"#,
             .badEnum(tool: "probe", property: "x")),
            (#"{"type": "object", "properties": {"x": {"type": "string", "enum": ["a", 1]}}}"#,
             .badEnum(tool: "probe", property: "x")),
        ]
        for (json, error) in cases {
            #expect(throws: error, "\(json)") {
                try SchemaBridge.generationSchema(for: ToolSchema(name: "probe", parametersJSON: json))
            }
        }
    }
}
