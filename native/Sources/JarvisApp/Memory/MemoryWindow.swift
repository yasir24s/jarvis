import AppKit
import JarvisChat
import JarvisCore
import SwiftUI

/// Batch C part 3: the "JARVIS Memory" window in the J.A.R.V.I.S. theme. Facts (search, filters,
/// add, edit, delete), the forgotten bin (restore) and the archive (read-only). All of it goes
/// through `MemoryEditor`, which goes through `MemoryStore`.
///
/// An AppKit window rather than a SwiftUI scene, so `jarvis://memory` can open it before any
/// SwiftUI view has handed out `openWindow` (a launch from the Desktop shortcut).
@MainActor
final class MemoryWindowController {
    static let size = CGSize(width: 760, height: 560)
    private var window: NSWindow?
    let editor: MemoryEditor

    init(editor: MemoryEditor) {
        self.editor = editor
    }

    func show() {
        editor.reload()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = MemoryEditor.windowTitle
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: MemoryView(editor: editor))
            w.setContentSize(Self.size)
            w.minSize = CGSize(width: 600, height: 420)
            JarvisTheme.style(w)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct MemoryView: View {
    enum Section: String, CaseIterable { case facts = "Facts", forgotten = "Forgotten", archive = "Archive" }

    @Bindable var editor: MemoryEditor
    @State private var section: Section = .facts
    @State private var selection = Set<String>()
    @State private var editing: MemoryFact?
    @State private var newText = ""
    @State private var newAbout = ""
    @State private var newRelation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("JARVIS MEMORY").font(JarvisTheme.label).tracking(JarvisTheme.labelTracking)
                    .foregroundStyle(JarvisTheme.cyan.color)
                Spacer()
                Picker("", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 300)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Hairline()
            if !editor.isAvailable {
                Text("Memory is not available yet: JARVIS is still starting.")
                    .foregroundStyle(JarvisTheme.muted.color).padding(18)
                Spacer()
            } else {
                switch section {
                case .facts: facts
                case .forgotten: forgotten
                case .archive: archive
                }
            }
            Hairline()
            Text(editor.status.isEmpty ? " " : editor.status)
                .font(JarvisTheme.small).foregroundStyle(JarvisTheme.muted.color)
                .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .foregroundStyle(JarvisTheme.ice.color)
        .font(JarvisTheme.body)
        .tint(JarvisTheme.cyan.color)
        .background(JarvisTheme.navy.color)
        .preferredColorScheme(.dark)
        .sheet(item: $editing) { fact in
            FactEditSheet(fact: fact) { text, about, relation in
                editor.edit(id: fact.id, text: text, about: about, relation: relation)
            }
        }
    }

    // MARK: Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search facts", text: $editor.filter.query).textFieldStyle(.roundedBorder)
                Picker("About", selection: $editor.filter.about) {
                    Text("Anyone").tag(String?.none)
                    ForEach(editor.aboutChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                }.frame(width: 150)
                Picker("Source", selection: $editor.filter.source) {
                    Text("Any").tag(String?.none)
                    ForEach(editor.sourceChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                }.frame(width: 150)
            }
            HStack(spacing: 8) {
                Picker("Written by", selection: $editor.filter.writer) {
                    Text("Any").tag(FactWriter?.none)
                    ForEach(FactWriter.allCases, id: \.self) { Text($0.rawValue).tag(FactWriter?.some($0)) }
                }.frame(width: 200)
                Picker("Updated", selection: $editor.filter.withinDays) {
                    Text("Any time").tag(Int?.none)
                    Text("Today").tag(Int?.some(1))
                    Text("Last 7 days").tag(Int?.some(7))
                    Text("Last 30 days").tag(Int?.some(30))
                }.frame(width: 200)
                Spacer()
                Text("\(editor.shown.count) of \(editor.facts.count)").font(JarvisTheme.small)
                    .foregroundStyle(JarvisTheme.muted.color)
            }
            List(editor.shown, id: \.id, selection: $selection) { fact in
                FactRow(fact: fact)
                    .contextMenu {
                        Button("Edit…") { editing = fact }
                        Button("Delete") { editor.delete(ids: [fact.id]); selection.remove(fact.id) }
                    }
            }
            .scrollContentBackground(.hidden)
            .background(JarvisTheme.panel.color)
            HStack(spacing: 8) {
                Button("Edit…") { editing = editor.facts.first { selection.contains($0.id) } }
                    .disabled(selection.count != 1)
                Button("Delete \(selection.isEmpty ? "" : "\(selection.count) ")Selected") {
                    if editor.delete(ids: selection) { selection = [] }
                }
                .disabled(selection.isEmpty)
                Spacer()
            }
            .buttonStyle(SetupButtonStyle(kind: .quiet))
            Hairline()
            HStack(spacing: 8) {
                TextField("A new fact, in one line", text: $newText).textFieldStyle(.roundedBorder)
                TextField("About (blank: you)", text: $newAbout).textFieldStyle(.roundedBorder).frame(width: 140)
                TextField("Relation", text: $newRelation).textFieldStyle(.roundedBorder).frame(width: 100)
                Button("Add") {
                    if editor.add(newText, about: newAbout, relation: newRelation) {
                        newText = ""; newAbout = ""; newRelation = ""
                    }
                }
                .buttonStyle(SetupButtonStyle(kind: .prominent))
                .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    // MARK: Forgotten

    private var forgotten: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Forgotten facts are kept for 30 days, then removed for good.")
                .font(JarvisTheme.small).foregroundStyle(JarvisTheme.muted.color)
            List(editor.forgotten, id: \.fact.id) { entry in
                HStack {
                    FactRow(fact: entry.fact)
                    Spacer()
                    Text("forgotten \(Self.date(entry.forgotten))").font(JarvisTheme.small)
                        .foregroundStyle(JarvisTheme.muted.color)
                    Button("Restore") { editor.restore(ids: [entry.fact.id]) }
                        .buttonStyle(SetupButtonStyle(kind: .quiet))
                }
            }
            .scrollContentBackground(.hidden)
            .background(JarvisTheme.panel.color)
        }
        .padding(14)
    }

    // MARK: Archive

    private var archive: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search the archive (read-only)", text: $editor.archiveQuery).textFieldStyle(.roundedBorder)
            List(Array(editor.shownArchive().enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.role == .user ? "You" : "JARVIS") · \(entry.channel) · \(Self.date(entry.timestamp))")
                        .font(JarvisTheme.small).foregroundStyle(entry.role == .user ? JarvisTheme.muted.color : JarvisTheme.cyan.color)
                    Text(entry.text).textSelection(.enabled)
                }
            }
            .scrollContentBackground(.hidden)
            .background(JarvisTheme.panel.color)
        }
        .padding(14)
    }

    static func date(_ epoch: Double) -> String {
        Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened)
    }
}

extension MemoryFact: Identifiable {}

private struct FactRow: View {
    let fact: MemoryFact

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fact.text).textSelection(.enabled)
            Text(meta).font(JarvisTheme.small).foregroundStyle(JarvisTheme.muted.color)
        }
        .padding(.vertical, 2)
    }

    private var meta: String {
        var who = fact.isAboutUser ? "about you" : "about \(fact.about)"
        if let r = fact.relation { who += " (\(r))" }
        return "\(who) · \(MemoryEditor.sourceKind(fact.source)) · by \(fact.by.rawValue) · \(MemoryView.date(fact.updated))"
    }
}

private struct FactEditSheet: View {
    let fact: MemoryFact
    let save: (String, String, String?) -> Bool
    @State private var text: String
    @State private var about: String
    @State private var relation: String
    @Environment(\.dismiss) private var dismiss

    init(fact: MemoryFact, save: @escaping (String, String, String?) -> Bool) {
        self.fact = fact
        self.save = save
        _text = State(initialValue: fact.text)
        _about = State(initialValue: fact.isAboutUser ? "" : fact.about)
        _relation = State(initialValue: fact.relation ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EDIT FACT").font(JarvisTheme.label).tracking(JarvisTheme.labelTracking)
                .foregroundStyle(JarvisTheme.cyan.color)
            TextField("Fact", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            Text("\(text.count) / \(MemoryFact.maxLength)").font(JarvisTheme.small)
                .foregroundStyle(text.count > MemoryFact.maxLength ? JarvisTheme.gold.color : JarvisTheme.muted.color)
            HStack {
                TextField("About (blank: you)", text: $about).textFieldStyle(.roundedBorder)
                TextField("Relation", text: $relation).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SetupButtonStyle(kind: .quiet))
                Button("Save") { if save(text, about, relation) { dismiss() } }
                    .buttonStyle(SetupButtonStyle(kind: .prominent))
            }
        }
        .padding(18)
        .frame(width: 460)
        .foregroundStyle(JarvisTheme.ice.color)
        .font(JarvisTheme.body)
        .background(JarvisTheme.navy.color)
    }
}

/// "Memory…", in the app menu and the menu-bar menu.
struct MemoryItem: View {
    let open: () -> Void

    var body: some View {
        Button(MemoryEditor.menuTitle) { open() }
    }
}
