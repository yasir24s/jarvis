import Darwin
import Foundation
import JarvisBrain

/// `JARVIS --mcp-relay <socket> --token-file <path>` (plan §3.7 "Relay mode"). `claude` starts
/// this as its stdio MCP server; it connects to the app's socket, sends the token, and then
/// copies bytes between its stdin/stdout and the socket. The work is `MCPRelay` in JarvisBrain,
/// where the tests drive it in-process. Entry dispatches here before any AppKit or SwiftUI use
/// and before the single-instance lock.
enum RelayMain {
    /// `--mcp-relay <socket> --token-file <path>`, exactly; nil for anything else.
    static func parse(_ arguments: ArraySlice<String>) -> (socket: String, tokenFile: String)? {
        let a = Array(arguments)
        guard a.count == 4, a[0] == "--mcp-relay", a[2] == "--token-file", !a[1].isEmpty, !a[3].isEmpty else {
            return nil
        }
        return (a[1], a[3])
    }

    /// Returns the exit status: 0 after EOF on either side, 1 on handshake failure.
    static func run(socket: String, tokenFile: String) -> Int32 {
        signal(SIGPIPE, SIG_IGN)   // a closed stdout gives EPIPE, and the pump exits
        return MCPRelay.main(socketPath: socket, tokenFile: tokenFile, input: STDIN_FILENO, output: STDOUT_FILENO)
    }
}
