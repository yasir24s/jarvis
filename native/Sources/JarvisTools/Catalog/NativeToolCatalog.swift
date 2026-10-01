// The tools native JARVIS has and Python never had (P4: his own memory), with hand-written
// schemas. ToolCatalog stays the generated Python catalog, byte for byte; these are served
// after it, and only when the app has a memory store.

/// search_memory, forget_memory and correct_memory, in that order. Each `parametersJSON` is
/// written in `json.dumps`'s style, like the Python catalog's.
public enum NativeToolCatalog {
    public static let memoryTools: [ToolSchema] = [
        ToolSchema(
            name: "search_memory",
            description: "Search your long-term memory of the user and the people in their life (from earlier conversations and the user's files), by keyword and meaning together. Returns each note's id and text. The MEMORY block in your prompt holds only a few notes, so search here before saying you don't know or don't remember something. An empty query lists the newest notes.",
            parametersJSON: #"{"type": "object", "properties": {"query": {"type": "string", "description": "Words or a question to look for"}}, "required": ["query"]}"#),
        ToolSchema(
            name: "forget_memory",
            description: "Remove notes from your long-term memory when the user says one is wrong or asks you to forget it. Give the ids from search_memory, or a query: then the notes that contain that exact phrase are removed, at most 10. The reply lists exactly what was removed.",
            parametersJSON: #"{"type": "object", "properties": {"ids": {"type": "array", "items": {"type": "string"}, "description": "The ids of the notes to remove, from search_memory"}, "query": {"type": "string", "description": "Instead of ids, a phrase the notes to remove contain"}}, "required": []}"#),
        ToolSchema(
            name: "correct_memory",
            description: "Correct one note in your long-term memory when the user says it is wrong: reword it, or say whose it is (the user's, or someone in their life). A note about the user is a short sentence starting 'The user'; a note about someone else names them. The reply shows the note before and after.",
            parametersJSON: #"{"type": "object", "properties": {"id": {"type": "string", "description": "The note's id, from search_memory"}, "text": {"type": "string", "description": "The corrected note"}, "about": {"type": "string", "description": "'user', or the full name of the person the note is about"}, "relation": {"type": "string", "description": "How that person is related to the user, such as 'mother'; empty to clear it"}}, "required": ["id"]}"#),
    ]

    /// The tool names, in order.
    public static var memoryToolNames: [String] { memoryTools.map(\.name) }

    static func schema(named name: String) -> ToolSchema {
        memoryTools.first { $0.name == name } ?? ToolSchema(name: name)
    }
}
