import Foundation
import JarvisCore

/// `get_weather(location)` (plan: M05-M06 T6.8, G11), Python's `_weather`: wttr.in's j1 JSON
/// (`https://wttr.in/<quote(location.strip())>?format=j1`, User-Agent `curl/8`, 8 s), read as
/// `current_condition[0]`: `weatherDesc[0].value` lowered, `temp_C` and `FeelsLikeC`, and the
/// place from `nearest_area[0].areaName[0].value`, else the location as given. Anything that
/// fails, the location not being a str included (`loc.strip()` is inside Python's `try`), gives
/// "I couldn't reach the weather service, sir."
struct GetWeather: ToolImpl {
    static let name = "get_weather"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let userAgent = "curl/8"
    static let timeout: Double = 8
    static let offline = "I'm offline, sir, so I can't check the weather."
    static let failed = "I couldn't reach the weather service, sir."

    let web: any WebFetching
    let online: @Sendable () async -> Bool

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard await online() else { return .text(Self.offline) }
        do {
            let location = try PyArgs.string(args, "location", default: "", method: "strip")
            let url = "https://wttr.in/" + PyURL.quote(Py.strip(location)) + "?format=j1"
            let body = try await web.get(url, headers: [("User-Agent", Self.userAgent)], timeout: Self.timeout)
            return .text(try Self.reply(try PyJSON.loads(body), location: location))
        } catch {
            return .text(Self.failed)
        }
    }

    /// The sentence from a j1 document; throws where Python's indexing raises.
    static func reply(_ data: JSONValue, location: String) throws -> String {
        let cur = try data.at("current_condition").at(0)
        guard let value = try cur.at("weatherDesc").at(0).at("value").stringValue else {
            throw PyError(description: "the description is not a str")
        }
        let desc = Py.lower(value)
        let temp = PyArgs.str(try cur.at("temp_C")), feels = PyArgs.str(try cur.at("FeelsLikeC"))
        let city: JSONValue = (try? data.at("nearest_area").at(0).at("areaName").at(0).at("value"))
            ?? .string(Py.strip(location))
        let place = city.pyTruthy ? " in \(PyArgs.str(city))" : ""
        return "It's \(desc) and \(temp) degrees\(place), feeling like \(feels), sir."
    }
}

/// `get_location()` (plan: M05-M06 T6.8, G11), Python's `_location`: ipwho.is's JSON (IP
/// geolocation, never CoreLocation), the non-empty of city, region and country joined.
struct GetLocation: ToolImpl {
    static let name = "get_location"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let url = "https://ipwho.is/"
    static let offline = "I can't determine your location offline, sir."
    static let failed = "I couldn't determine your location, sir."
    static let vague = "I couldn't pinpoint your location, sir."

    let web: any WebFetching
    let online: @Sendable () async -> Bool

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard await online() else { return .text(Self.offline) }
        do {
            let body = try await web.get(Self.url, headers: [("User-Agent", WebSearch.userAgent)],
                                         timeout: WebSearch.timeout)
            return .text(try Self.reply(try PyJSON.loads(body)))
        } catch {
            return .text(Self.failed)
        }
    }

    /// `if data.get("success")`: the joined place; a truthy non-str part raises, as `join` does.
    static func reply(_ data: JSONValue) throws -> String {
        guard case .object(let o) = data else { throw PyError(description: "not a dict") }
        guard let success = o["success"], success.pyTruthy else { return failed }
        var bits: [String] = []
        for key in ["city", "region", "country"] {
            guard let part = o[key], part.pyTruthy else { continue }
            guard let s = part.stringValue else { throw PyError(description: "join needs str") }
            bits.append(s)
        }
        return bits.isEmpty ? vague : "You appear to be in \(bits.joined(separator: ", ")), sir."
    }
}

extension JSONValue {
    /// Python's `value[key]` on a dict, raising (here throwing) for a missing key or a non-dict.
    func at(_ key: String) throws -> JSONValue {
        guard case .object(let o) = self, let v = o[key] else { throw PyError(description: "KeyError: '\(key)'") }
        return v
    }

    /// Python's `value[i]` on a list, raising for a short list or a non-list. A str is a non-list
    /// here: indexing one gives a one-letter str that the next step can never index by key.
    func at(_ index: Int) throws -> JSONValue {
        guard case .array(let a) = self, index < a.count else { throw PyError(description: "IndexError") }
        return a[index]
    }
}
