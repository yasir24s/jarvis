import COnnxRuntime
import Darwin
import Foundation
import Synchronization

// ONNX Runtime through its C API (plan: M08-M13 §3.1), adapted from jarvis-swift's
// WakeWord.swift (Ort, OrtInferenceSession). Two changes from the salvaged file:
// - The dylib is dlopened by path and the API table comes from dlsym("OrtGetApiBase"), so
//   nothing links against it. A checkout without the vendored binaries still builds and runs
//   every other test, and the speaker tests fail saying to run scripts/vendor-voice-assets.sh.
// - Errors are thrown, never fatalError, and the input tensor is created and run inside the
//   closure that pins its buffer (the salvaged run() let the pointer escape).

/// Loading or running ONNX Runtime failed.
public enum OrtError: Error, Equatable, CustomStringConvertible {
    /// A vendored file (the dylib or a model) is not on disk.
    case missing(String)
    /// dlopen or dlsym failed, or the dylib does not offer the header's API version.
    case load(String)
    /// An ORT call returned an error status.
    case failure(String)

    public var description: String {
        switch self {
        case .missing(let path): return "ONNX Runtime: missing \(path)"
        case .load(let why): return "ONNX Runtime did not load: \(why)"
        case .failure(let why): return "ONNX Runtime error: \(why)"
        }
    }
}

/// The ORT C API table and one shared environment, from a dlopened dylib. The table is
/// immutable and an OrtEnv may be shared across threads (ORT's documented contract), so one
/// runtime per dylib path is cached for the life of the process.
public final class OrtRuntime: @unchecked Sendable {
    let api: UnsafePointer<OrtApi>
    let env: OpaquePointer
    public let path: String
    /// The version string the dylib reports, e.g. "1.26.0".
    public let version: String

    private static let loaded = Mutex<[String: OrtRuntime]>([:])

    private init(api: UnsafePointer<OrtApi>, env: OpaquePointer, path: String, version: String) {
        self.api = api
        self.env = env
        self.path = path
        self.version = version
    }

    /// The runtime in `dylib`, loaded once per path.
    public static func load(dylib: URL) throws -> OrtRuntime {
        let path = dylib.path
        return try loaded.withLock { cache in
            if let runtime = cache[path] { return runtime }
            guard FileManager.default.fileExists(atPath: path) else { throw OrtError.missing(path) }
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                throw OrtError.load(dlerror().map { String(cString: $0) } ?? "dlopen failed")
            }
            guard let symbol = dlsym(handle, "OrtGetApiBase") else {
                throw OrtError.load("no OrtGetApiBase in \(dylib.lastPathComponent)")
            }
            typealias GetApiBase = @convention(c) () -> UnsafePointer<OrtApiBase>?
            let getApiBase = unsafeBitCast(symbol, to: GetApiBase.self)
            guard let base = getApiBase(), let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
                throw OrtError.load("the dylib has no C API v\(ORT_API_VERSION) (header mismatch?)")
            }
            var env: OpaquePointer?
            try check(api, api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "jarvis", &env))
            guard let env else { throw OrtError.failure("CreateEnv returned nil") }
            let version = base.pointee.GetVersionString().map { String(cString: $0) } ?? ""
            let runtime = OrtRuntime(api: api, env: env, path: path, version: version)
            cache[path] = runtime
            return runtime
        }
    }

    func check(_ status: OrtStatusPtr?) throws { try Self.check(api, status) }

    static func check(_ api: UnsafePointer<OrtApi>, _ status: OrtStatusPtr?) throws {
        guard let status else { return }
        let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown"
        api.pointee.ReleaseStatus(status)
        throw OrtError.failure(message)
    }
}

/// One ORT session with a single float32 input and a single float32 output, on the CPU with
/// one intra-op and one inter-op thread and ORT_ENABLE_ALL (the wake models' settings, §3.1).
/// Not Sendable: an actor owns it.
final class OrtSession {
    let runtime: OrtRuntime
    private let session: OpaquePointer
    private let memoryInfo: OpaquePointer
    private let inputName: UnsafeMutablePointer<CChar>
    private let outputName: UnsafeMutablePointer<CChar>

    init(runtime: OrtRuntime, model: URL, inputName: String, outputName: String) throws {
        guard FileManager.default.fileExists(atPath: model.path) else { throw OrtError.missing(model.path) }
        self.runtime = runtime
        let api = runtime.api.pointee

        var options: OpaquePointer?
        try runtime.check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        try runtime.check(api.SetIntraOpNumThreads(options, 1))
        try runtime.check(api.SetInterOpNumThreads(options, 1))
        try runtime.check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))

        var session: OpaquePointer?
        try runtime.check(model.path.withCString { api.CreateSession(runtime.env, $0, options, &session) })
        guard let session else { throw OrtError.failure("CreateSession returned nil for \(model.lastPathComponent)") }

        var memoryInfo: OpaquePointer?
        if let status = api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo) {
            api.ReleaseSession(session)
            try runtime.check(status)
        }
        guard let memoryInfo else {
            api.ReleaseSession(session)
            throw OrtError.failure("CreateCpuMemoryInfo returned nil")
        }
        self.session = session
        self.memoryInfo = memoryInfo
        self.inputName = strdup(inputName)
        self.outputName = strdup(outputName)
    }

    deinit {
        let api = runtime.api.pointee
        api.ReleaseMemoryInfo(memoryInfo)
        api.ReleaseSession(session)
        free(inputName)
        free(outputName)
    }

    /// Runs the model on one float32 tensor of `shape`; returns the flat output and its shape.
    func run(_ input: [Float], shape: [Int64]) throws -> (values: [Float], shape: [Int64]) {
        let api = runtime.api.pointee
        guard shape.reduce(1, *) == Int64(input.count) else {
            throw OrtError.failure("input has \(input.count) values, shape \(shape) needs \(shape.reduce(1, *))")
        }
        var data = input
        return try data.withUnsafeMutableBytes { raw in
            var inputValue: OpaquePointer?
            try shape.withUnsafeBufferPointer { dims in
                try runtime.check(api.CreateTensorWithDataAsOrtValue(
                    memoryInfo, raw.baseAddress, raw.count, dims.baseAddress, dims.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &inputValue))
            }
            defer { api.ReleaseValue(inputValue) }

            var outputValue: OpaquePointer?
            var inputNames: [UnsafePointer<CChar>?] = [UnsafePointer(inputName)]
            var outputNames: [UnsafePointer<CChar>?] = [UnsafePointer(outputName)]
            var inputs: [OpaquePointer?] = [inputValue]
            try runtime.check(api.Run(session, nil, &inputNames, &inputs, 1, &outputNames, 1, &outputValue))
            defer { api.ReleaseValue(outputValue) }

            var info: OpaquePointer?
            try runtime.check(api.GetTensorTypeAndShape(outputValue, &info))
            defer { api.ReleaseTensorTypeAndShapeInfo(info) }
            var rank = 0
            try runtime.check(api.GetDimensionsCount(info, &rank))
            var outShape = [Int64](repeating: 0, count: rank)
            try runtime.check(api.GetDimensions(info, &outShape, rank))
            var count = 0
            try runtime.check(api.GetTensorShapeElementCount(info, &count))

            var out: UnsafeMutableRawPointer?
            try runtime.check(api.GetTensorMutableData(outputValue, &out))
            guard let out else { throw OrtError.failure("GetTensorMutableData returned nil") }
            let values = Array(UnsafeBufferPointer(start: out.assumingMemoryBound(to: Float.self), count: count))
            return (values, outShape)
        }
    }
}
