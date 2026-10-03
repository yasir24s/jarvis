import AppKit
import Foundation
import JarvisTools

/// Batch C part 5: `JARVIS --probe-tv "<show>" [storefront]`, the read-only TV feasibility probe
/// (`TVProbe`). Headless; it plays nothing, launches nothing and asks the TV app only when it is
/// already running. Prints one line per finding.
enum TVProbeMain {
    static let flag = "--probe-tv"

    static func run(arguments: [String]) -> Int32 {
        guard let show = arguments.first, !show.isEmpty else {
            FileHandle.standardError.write(Data("usage: JARVIS \(flag) \"<show>\" [storefront]\n".utf8))
            return 64
        }
        let storefront = arguments.count > 1 ? arguments[1] : (Locale.current.region?.identifier.lowercased() ?? "us")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await probe(show: show, storefront: storefront)
            done.signal()
        }
        done.wait()
        return 0
    }

    static func fetch(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func probe(show: String, storefront: String) async {
        // 1. The TV app's dictionary.
        let sdef = Process()
        sdef.executableURL = URL(filePath: "/usr/bin/sdef")
        sdef.arguments = ["/System/Applications/TV.app"]
        let pipe = Pipe()
        sdef.standardOutput = pipe
        sdef.standardError = FileHandle.nullDevice
        if (try? sdef.run()) != nil {
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            sdef.waitUntilExit()
            let missing = TVProbe.missingTerms(inDictionary: text)
            print("tv-app dictionary: " + (missing.isEmpty ? "has every needed term (\(TVProbe.neededTerms.joined(separator: ", ")))"
                                                         : "missing \(missing.joined(separator: ", "))"))
        } else {
            print("tv-app dictionary: sdef could not run")
        }
        // 2. tv.apple.com, public pages only.
        guard let searchURL = TVProbe.searchURL(show, storefront: storefront), let search = await fetch(searchURL) else {
            print("tv.apple.com search: no page"); return
        }
        let shows = TVProbe.showURLs(inSearchPage: search)
        print("tv.apple.com search: \(shows.count) show link(s)")
        guard let showURL = TVProbe.showURL(for: show, inSearchPage: search) else {
            print("tv.apple.com show: no link whose name matches \"\(show)\""); return
        }
        print("tv.apple.com show: \(showURL)")
        if let page = await fetch(URL(string: showURL)!) {
            let seasons = TVProbe.seasons(inShowPage: page)
            print("tv.apple.com seasons: " + seasons.map { "S\($0.number) (\($0.episodes) episodes)" }.joined(separator: ", "))
            let episodes = TVProbe.episodeURLs(inShowPage: page)
            print("tv.apple.com episode links in the server page: \(episodes.count)" + (episodes.first.map { ", first \($0)" } ?? ""))
        }
        // 3. Now playing, only if the TV app is already running.
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TV").isEmpty
        if running {
            print("tv-app now playing: " + (await LiveScripts().run(TVProbe.nowPlayingScript)))
        } else {
            print("tv-app now playing: the TV app is not running; not asked")
        }
        print("playback: not probed (it would play sound); see the at-screen steps")
    }
}
