import Darwin
import Foundation
import Synchronization

// WebRTC's voice activity detector, from py-webrtcvad 2.0.10's extension module (plan:
// M08-M13 §3.5, T0.3, T10.1). The module is a Python extension, but its WebRtcVad_* C entry
// points need no interpreter. dyld binds four Python data symbols at load time
// (`dyld_info -fixups`: PyExc_ValueError, _Py_NoneStruct, _Py_TrueStruct, _Py_FalseStruct), so
// libpystubs.dylib, which defines them, is loaded RTLD_GLOBAL first. The module itself is
// loaded RTLD_LAZY, not the plan's RTLD_NOW: RTLD_NOW also binds its nine lazy Py* function
// pointers at once, and dlopen fails with "symbol not found in flat namespace
// '_PyArg_ParseTuple'" (seen in the T0.3 bundle). Lazily bound, they stay unbound, and none
// is ever called.
//
// The signatures, from disassembling the arm64 slice (fe15c00f…):
//   int  WebRtcVad_Create(VadInst **out)      cbz x0; malloc(0x2e0); str x0,[x19]; 0 or -1
//   int  WebRtcVad_Init(VadInst *)            b WebRtcVad_InitCore
//   int  WebRtcVad_set_mode(VadInst *, int)   -1 unless initialised (the 42 flag at +0x2dc)
//   int  WebRtcVad_Process(VadInst *, int fs, const int16_t *, size_t len)   1, 0 or -1
//   void WebRtcVad_Free(VadInst *)            b free

/// Loading or running the VAD failed.
public enum WebRTCVADError: Error, Equatable, CustomStringConvertible {
    /// libpystubs.dylib or the module is not on disk.
    case missing(String)
    /// dlopen or dlsym failed.
    case load(String)
    /// A WebRtcVad_* call returned -1 (`what` names it).
    case call(String)

    public var description: String {
        switch self {
        case .missing(let path): return "webrtcvad: missing \(path)"
        case .load(let why): return "webrtcvad did not load: \(why)"
        case .call(let what): return "webrtcvad: \(what) failed"
        }
    }
}

/// The module's entry points, resolved once per process.
public final class WebRTCVADLibrary: @unchecked Sendable {
    typealias Create = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    typealias Init = @convention(c) (OpaquePointer?) -> Int32
    typealias SetMode = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias Process = @convention(c) (OpaquePointer?, Int32, UnsafePointer<Int16>?, Int) -> Int32
    typealias Free = @convention(c) (OpaquePointer?) -> Void

    let create: Create
    let initialize: Init
    let setMode: SetMode
    let process: Process
    let free: Free

    private static let loaded = Mutex<WebRTCVADLibrary?>(nil)

    private init(create: Create, initialize: Init, setMode: SetMode, process: Process, free: Free) {
        self.create = create
        self.initialize = initialize
        self.setMode = setMode
        self.process = process
        self.free = free
    }

    /// Loads libpystubs (RTLD_GLOBAL), then the module (RTLD_LAZY), once per process. Later calls
    /// return the first library whatever paths they pass.
    public static func load(stubs: URL, module: URL) throws -> WebRTCVADLibrary {
        for url in [stubs, module] where !FileManager.default.fileExists(atPath: url.path) {
            throw WebRTCVADError.missing(url.path)
        }
        return try loaded.withLock { cached in
            if let cached { return cached }
            guard let stubsHandle = dlopen(stubs.path, RTLD_NOW | RTLD_GLOBAL) else {
                throw WebRTCVADError.load(lastDlerror("dlopen libpystubs"))
            }
            guard dlsym(stubsHandle, "jarvis_pystubs_loaded") != nil else {
                throw WebRTCVADError.load("\(stubs.lastPathComponent) is not libpystubs")
            }
            guard let handle = dlopen(module.path, RTLD_LAZY | RTLD_LOCAL) else {
                throw WebRTCVADError.load(lastDlerror("dlopen \(module.lastPathComponent)"))
            }
            func symbol<T>(_ name: String, as type: T.Type) throws -> T {
                guard let raw = dlsym(handle, name) else { throw WebRTCVADError.load("no \(name)") }
                return unsafeBitCast(raw, to: type)
            }
            let library = WebRTCVADLibrary(
                create: try symbol("WebRtcVad_Create", as: Create.self),
                initialize: try symbol("WebRtcVad_Init", as: Init.self),
                setMode: try symbol("WebRtcVad_set_mode", as: SetMode.self),
                process: try symbol("WebRtcVad_Process", as: Process.self),
                free: try symbol("WebRtcVad_Free", as: Free.self))
            cached = library
            return library
        }
    }

    private static func lastDlerror(_ what: String) -> String {
        dlerror().map { "\(what): " + String(cString: $0) } ?? what
    }
}

/// One VAD instance, as `webrtcvad.Vad(mode)`. Not Sendable: one owner runs it.
public final class WebRTCVAD {
    private let library: WebRTCVADLibrary
    private let handle: OpaquePointer

    /// `webrtcvad.Vad(mode)`: create, init, then set_mode. Mode 3 is the most aggressive.
    public init(library: WebRTCVADLibrary, mode: Int32 = 3) throws {
        var handle: OpaquePointer?
        guard library.create(&handle) == 0, let handle else { throw WebRTCVADError.call("WebRtcVad_Create") }
        guard library.initialize(handle) == 0 else {
            library.free(handle)
            throw WebRTCVADError.call("WebRtcVad_Init")
        }
        guard library.setMode(handle, mode) == 0 else {
            library.free(handle)
            throw WebRTCVADError.call("WebRtcVad_set_mode(\(mode))")
        }
        self.library = library
        self.handle = handle
    }

    deinit { library.free(handle) }

    /// `Vad.is_speech(frame, sample_rate)`: true for speech. The frame must be 10, 20 or 30 ms
    /// at 8, 16, 32 or 48 kHz; anything else throws, as Python raises.
    public func isSpeech(_ frame: ArraySlice<Int16>, sampleRate: Int32 = 16000) throws -> Bool {
        let result = frame.withUnsafeBufferPointer {
            library.process(handle, sampleRate, $0.baseAddress, $0.count)
        }
        switch result {
        case 1: return true
        case 0: return false
        default: throw WebRTCVADError.call("WebRtcVad_Process(\(sampleRate) Hz, \(frame.count) samples)")
        }
    }

    public func isSpeech(_ frame: [Int16], sampleRate: Int32 = 16000) throws -> Bool {
        try isSpeech(frame[...], sampleRate: sampleRate)
    }

    /// One flag per whole `frameMs` frame of `samples` (16 kHz), as Python's loop over
    /// `is_speech` would give; a trailing partial frame is dropped.
    public func flags(_ samples: [Int16], frameMs: Int) throws -> [Bool] {
        let size = 16 * frameMs
        guard size > 0 else { return [] }
        return try stride(from: 0, to: samples.count - size + 1, by: size).map {
            try isSpeech(samples[$0 ..< $0 + size])
        }
    }
}
