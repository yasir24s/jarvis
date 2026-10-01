import Foundation
import JarvisCore

/// A Python exception's `str()`, which `execute_tool` turns into `Tool error: <text>` (the
/// gateway formats `String(describing:)` the same way).
struct PyError: Error, CustomStringConvertible, Equatable {
    let description: String

    /// `AttributeError: '<type>' object has no attribute '<name>'`.
    static func noAttribute(_ value: JSONValue?, _ name: String) -> PyError {
        PyError(description: "'\(PyArgs.typeName(value))' object has no attribute '\(name)'")
    }
}

/// `args.get(key, default)` with the coercions the tool bodies apply (plan: M05-M06 §3.2).
enum PyArgs {
    /// `type(v).__name__` for a JSON value; nil (a missing key with a None default) is NoneType.
    static func typeName(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: "NoneType"
        case .bool?: "bool"
        case .int?, .bigInt?: "int"
        case .double?: "float"
        case .string?: "str"
        case .array?: "list"
        case .object?: "dict"
        }
    }

    /// `(args.get(key, "") or "")` followed by a str method: a falsy value becomes "", a str is
    /// itself, anything else raises AttributeError for `method`.
    static func stringOrEmpty(_ args: JSONObject, _ key: String, method: String) throws -> String {
        guard let value = args[key], value.pyTruthy else { return "" }
        guard let s = value.stringValue else { throw PyError.noAttribute(value, method) }
        return s
    }

    /// `args.get(key, default)` used as a str with no `or ""`: missing gives `defaultValue`, a
    /// str is itself, anything else (None included) raises AttributeError for `method`.
    static func string(_ args: JSONObject, _ key: String, default defaultValue: String, method: String) throws -> String {
        guard let value = args[key] else { return defaultValue }
        guard let s = value.stringValue else { throw PyError.noAttribute(value, method) }
        return s
    }

    /// `str(v)` / `f"{v}"` for the JSON values a reply can echo.
    static func str(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: "None"
        case .bool(let b)?: b ? "True" : "False"
        case .int(let i)?: String(i)
        case .bigInt(let digits)?: digits
        case .double(let d)?: PyFloat.repr(d)
        case .string(let s)?: s
        case .array(let a)?: a.isEmpty ? "[]" : "[" + a.map(repr).joined(separator: ", ") + "]"
        case .object(let o)?: o.count == 0 ? "{}"
            : "{" + o.members.map { PyRepr.string($0.key) + ": " + repr($0.value) }.joined(separator: ", ") + "}"
        }
    }

    static func repr(_ value: JSONValue) -> String {
        if case .string(let s) = value { return PyRepr.string(s) }
        return str(value)
    }
}
