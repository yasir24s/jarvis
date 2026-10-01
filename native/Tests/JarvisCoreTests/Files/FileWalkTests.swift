import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// D-51 P3, piece 1: the walk and every exclusion, on a temp home tree (never the real one).

private func walk(_ home: TempHome, stateRoot: String = "jarvis",
                  probe: FakeFileProbe = FakeFileProbe()) -> (paths: [String], walk: FileWalk) {
    var walk = FileWalk(home: home.root, stateRoot: home.url(stateRoot), probe: probe)
    var paths: [String] = []
    let prefix = FakeFileProbe.key(home.root)       // listings name /private/var as /var's real path
    while let candidate = walk.next() {
        paths.append(String(FakeFileProbe.key(candidate.url).dropFirst(prefix.count + 1)))
    }
    return (paths, walk)
}

@Suite("File walk and exclusions (D-51 P3)")
struct FileWalkTests {
    @Test func documentsAreFoundAndSourceCodeIsNot() throws {
        let home = try TempHome()
        defer { home.remove() }
        for name in ["notes.txt", "todo.md", "data.csv", "letter.rtf", "essay.docx", "paper.pdf",
                     "README", "main.swift", "script.py", "index.html", "Makefile"] {
            try home.write("Documents/\(name)")
        }
        try home.write("Documents/story.rtfd/TXT.rtf")
        let (paths, walk) = walk(home)
        #expect(paths == ["Documents/README", "Documents/data.csv", "Documents/essay.docx",
                          "Documents/letter.rtf", "Documents/notes.txt", "Documents/paper.pdf",
                          "Documents/story.rtfd", "Documents/todo.md"])
        #expect(walk.skipped[.notADocument] == 4)
    }

    @Test func kindsFollowTheExtensionInAnyCase() {
        let cases: [(String, DocumentKind?)] = [
            ("a.TXT", .plainText), ("a.md", .markdown), ("a.Markdown", .markdown), ("a.csv", .csv),
            ("a.rtf", .rtf), ("a.rtfd", .rtfd), ("a.DOCX", .docx), ("a.pdf", .pdf),
            ("README.rst", .plainText), ("readme", .plainText), ("Readme.MD", .markdown),
            ("a.swift", nil), ("a.py", nil), ("a.doc", nil), ("a.pages", nil),
        ]
        for (name, kind) in cases {
            #expect(FileExclusions.documentKind(name: name, inRepository: false) == kind, "\(name)")
        }
    }

    @Test func insideARepositoryOnlyReadmesAreRead() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write("code/app/.git/HEAD")
        try home.write("code/app/README.md")
        try home.write("code/app/CMakeLists.txt")
        try home.write("code/app/docs/guide.md")
        try home.write("code/app/Sources/Thing/README")
        try home.write("code/worktree/.git", "gitdir: elsewhere")     // a worktree's .git is a file
        try home.write("code/worktree/README.txt")
        try home.write("code/worktree/notes.md")
        try home.write("code/loose.md")                                 // not in a repository
        let (paths, _) = walk(home)
        #expect(paths == ["code/loose.md", "code/app/README.md", "code/app/Sources/Thing/README",
                          "code/worktree/README.txt"])
    }

    @Test func hiddenFilesAndFoldersAreNeverEntered() throws {
        let home = try TempHome()
        let probe = FakeFileProbe()
        defer { home.remove() }
        for path in [".ssh/notes.txt", ".aws/config.md", ".claude/memory.md", ".signing/a.txt",
                     ".git/description.md", ".hidden.md", "Documents/.secret-plan.md"] {
            try home.write(path)
        }
        try home.write("Documents/plan.md")
        let (paths, walk) = walk(home, probe: probe)
        #expect(paths == ["Documents/plan.md"])
        #expect(walk.skipped[.hidden] == 7)                          // 5 folders and 2 files
        // The home folder's own .git (dotfiles in git) does not make it a repository.
        #expect(!probe.listed.contains { $0.contains("/.") })
    }

    @Test func libraryIsSkippedButICloudDriveIsWalked() throws {
        let home = try TempHome()
        let probe = FakeFileProbe()
        defer { home.remove() }
        try home.write("Library/Notes/private.md")
        try home.write("Library/Mobile Documents/com~apple~Pages/Documents/x.md")
        try home.write("Library/Mobile Documents/com~apple~CloudDocs/Plans/trip.md")
        try home.write("Documents/plan.md")
        let (paths, walk) = walk(home, probe: probe)
        #expect(paths == ["Documents/plan.md", "Library/Mobile Documents/com~apple~CloudDocs/Plans/trip.md"])
        #expect(walk.skipped[.library] == 1)
        #expect(!probe.listed.contains(FakeFileProbe.key(home.url("Library"))))
        #expect(!probe.listed.contains { $0.contains("com~apple~Pages") })
    }

    @Test func iCloudFilesNotOnTheMacAreNeverRead() throws {
        let home = try TempHome()
        let probe = FakeFileProbe()
        defer { home.remove() }
        let drive = "Library/Mobile Documents/com~apple~CloudDocs"
        let evicted = try home.write("\(drive)/evicted.pdf")
        let remote = try home.write("\(drive)/remote.docx")
        let stale = try home.write("\(drive)/stale.md")
        let current = try home.write("\(drive)/current.md")
        let desk = try home.write("Desktop/evicted.txt")       // Desktop & Documents sync: outside the drive
        try home.write("\(drive)/Evicted folder/inside.md")
        probe.dataless(evicted)
        probe.cloud(remote, .notDownloaded)
        probe.cloud(stale, .downloaded)
        probe.cloud(current, .current)
        probe.dataless(desk)
        probe.dataless(home.url("\(drive)/Evicted folder"))
        let (paths, walk) = walk(home, probe: probe)
        #expect(paths == ["\(drive)/current.md"])
        #expect(walk.skipped[.notDownloaded] == 5)
        #expect(!probe.listed.contains { $0.hasSuffix("Evicted folder") })   // listing would download it
    }

    @Test func theStateRootAndEverythingInItIsSkipped() throws {
        let home = try TempHome()
        let probe = FakeFileProbe()
        defer { home.remove() }
        for path in ["jarvis/knowledge.json", "jarvis/memory/facts.json", "jarvis/research/usage.json",
                     "jarvis/research/notes.md", "jarvis/logs/jarvis.log", "jarvis/voices/a.txt",
                     "jarvis/README.md", "jarvis/plan/notes.md"] {
            try home.write(path)
        }
        try home.write("jarvis-notes.md")
        let (paths, walk) = walk(home, probe: probe)
        #expect(paths == ["jarvis-notes.md"])
        #expect(walk.skipped[.stateRoot] == 1)
        #expect(!probe.listed.contains { $0.contains("/jarvis/") || $0.hasSuffix("/jarvis") })
    }

    @Test func theStateRootIsRecognisedThroughASymlinkedName() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write("jarvis/memory/facts.json")
        try home.write("jarvis/notes.md")
        try home.mkdir("Desktop")
        try home.symlink("Desktop/jarvis-link", to: home.url("jarvis").path(percentEncoded: false))
        let (paths, walk) = walk(home, stateRoot: "Desktop/jarvis-link")
        #expect(paths.isEmpty)
        #expect(walk.skipped[.stateRoot] == 1)
        #expect(walk.skipped[.symlink] == 1)
    }

    @Test func buildOutputAndBundlesAreSkipped() throws {
        let home = try TempHome()
        defer { home.remove() }
        for path in ["proj/node_modules/pkg/README.md", "proj/build/out.txt", "proj/dist/a.md",
                     "proj/DerivedData/b.md", "proj/Pods/c.md", "proj2/Build/d.md", "proj/.build/e.md",
                     "Apps/Thing.app/Contents/readme.txt", "Apps/X.framework/notes.md",
                     "Apps/Y.xcframework/Info.md", "Apps/Z.bundle/notes.txt"] {
            try home.write(path)
        }
        try home.write("proj/notes.md")
        let (paths, walk) = walk(home)
        #expect(paths == ["proj/notes.md"])
        #expect(walk.skipped[.buildOutput] == 6)
        #expect(walk.skipped[.bundle] == 4)
        #expect(walk.skipped[.hidden] == 1)
    }

    @Test func mediaArchivesDiskImagesAndBinariesAreSkippedByType() throws {
        let home = try TempHome()
        defer { home.remove() }
        for name in ["photo.JPG", "song.mp3", "film.mov", "backup.zip", "logs.tar.gz", "disk.dmg",
                     "os.iso", "tool.dylib", "lib.so", "a.out.o", "app.exe", "data.sqlite"] {
            try home.write("Downloads/\(name)")
        }
        try home.write("Pictures/Photos Library.photoslibrary/database/notes.txt")
        try home.write("Pictures/Vault.sparsebundle/Info.txt")
        let (paths, walk) = walk(home)
        #expect(paths.isEmpty)
        #expect(walk.skipped[.byType] == 14)
    }

    @Test(arguments: ["server.pem", "my.key", "cert.p12", "cert.pfx", "a.cer", "b.crt", "id_rsa",
                      "id_rsa.pub", "id_rsa_backup.txt", "login.keychain-db", "old.keychain",
                      "bank-passwords.txt", "API_TOKEN.md", "client_secret.txt",
                      "aws-credentials.csv", "Credential notes.docx", "prod.env", "ENV.txt",
                      "app.env.local", "env"])
    func credentialNamesAreSkipped(_ name: String) {
        #expect(FileExclusions.skip(name: name, isDirectory: false) == .credential, "\(name)")
        #expect(FileExclusions.skip(name: name, isDirectory: true) == .credential, "\(name)")
    }

    @Test func credentialFilesAndFoldersNeverReachTheWalkOutput() throws {
        let home = try TempHome()
        defer { home.remove() }
        for path in ["Documents/passwords.txt", "Documents/tokens.md", "Documents/my.key",
                     "Documents/secrets/plan.md", "Documents/.env", "Documents/prod.env",
                     "Documents/environment.md"] {
            try home.write(path)
        }
        let (paths, walk) = walk(home)
        #expect(paths == ["Documents/environment.md"])
        #expect(walk.skipped[.credential] == 5)
        #expect(walk.skipped[.hidden] == 1)
    }

    @Test func filesOverTwentyMegabytesAreSkipped() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.sized("Documents/at-limit.txt", bytes: UInt64(FileExclusions.maxBytes))
        try home.sized("Documents/over-limit.pdf", bytes: UInt64(FileExclusions.maxBytes) + 1)
        let (paths, walk) = walk(home)
        #expect(paths == ["Documents/at-limit.txt"])
        #expect(walk.skipped[.tooLarge] == 1)
        #expect(FileExclusions.maxBytes == 20 * 1024 * 1024)
    }

    @Test func symlinksAreNeverFollowedSoLoopsEnd() throws {
        let home = try TempHome()
        let probe = FakeFileProbe()
        defer { home.remove() }
        try home.write("docs/real.md")
        try home.symlink("docs/alias.md", to: "real.md")
        try home.symlink("docs/self", to: ".")
        try home.symlink("docs/up", to: "..")
        try home.symlink("home-loop", to: home.root.path(percentEncoded: false))
        try home.symlink("outside", to: "/etc")
        let (paths, walk) = walk(home, probe: probe)
        #expect(paths == ["docs/real.md"])
        #expect(walk.skipped[.symlink] == 5)
        #expect(probe.listed.count == 2)                           // the home folder and docs/
    }

    @Test func nothingIsReadFromAFolderThatCannotBeListed() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write("Locked/plan.md")
        let locked = home.url("Locked").path(percentEncoded: false)
        #expect(chmod(locked, 0) == 0)
        defer { _ = chmod(locked, 0o755) }
        let (paths, walk) = walk(home)
        #expect(paths.isEmpty)
        #expect(walk.skipped[.unreadable] == 1)
    }

    @Test func aMissingHomeOrICloudDriveWalksNothing() throws {
        let home = try TempHome()
        defer { home.remove() }
        var walk = FileWalk(home: home.url("nowhere"), stateRoot: home.url("jarvis"),
                            probe: FakeFileProbe())
        #expect(walk.next() == nil)
        #expect(walk.directoriesListed == 0)
    }
}
