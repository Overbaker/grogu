import Foundation
import Observation

/// Lightweight markdown memory + skill catalog backed by Documents/GroguWorkspace/.
/// Bounded read sizes keep prompt token and RAM usage predictable.
@MainActor
@Observable
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    struct SkillDoc: Identifiable, Hashable, Sendable {
        var id: String { name }
        let name: String
        let summary: String
        let content: String
    }

    private(set) var soulText: String = ""
    private(set) var memoryText: String = ""
    private(set) var skills: [SkillDoc] = []

    private static let maxPromptMemoryChars = 6_000

    private var rootDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GroguWorkspace", isDirectory: true)
    }

    private var soulURL: URL { rootDir.appendingPathComponent("SOUL.md") }
    private var memoryURL: URL { rootDir.appendingPathComponent("MEMORY.md") }
    private var skillsDir: URL { rootDir.appendingPathComponent("skills", isDirectory: true) }

    private init() {
        bootstrapDefaults()
        reload()
    }

    func reload() {
        soulText = (try? String(contentsOf: soulURL, encoding: .utf8)) ?? Self.defaultSoul
        memoryText = (try? String(contentsOf: memoryURL, encoding: .utf8)) ?? Self.defaultMemory
        loadSkills()
    }

    func saveSoul(_ text: String) {
        let trimmed = String(text.prefix(8_000))
        try? trimmed.write(to: soulURL, atomically: true, encoding: .utf8)
        soulText = trimmed
    }

    func saveMemory(_ text: String) {
        let clean = LogRedactor.sanitize(text, maxChars: 24_000)
        try? clean.write(to: memoryURL, atomically: true, encoding: .utf8)
        memoryText = clean
    }

    func appendMemory(_ note: String) {
        let cleanNote = LogRedactor.sanitize(note.trimmingCharacters(in: .whitespacesAndNewlines), maxChars: 1_200)
        guard !cleanNote.isEmpty else { return }
        let date = ISO8601DateFormatter().string(from: Date())
        let updated = memoryText + "\n- [\(date)] \(cleanNote)"
        saveMemory(updated)
    }

    func saveSkill(name: String, content: String) {
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return }
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        let url = skillsDir.appendingPathComponent("\(slug).md")
        try? String(content.prefix(12_000)).write(to: url, atomically: true, encoding: .utf8)
        loadSkills()
    }

    func deleteSkill(name: String) {
        let url = skillsDir.appendingPathComponent("\(name).md")
        try? FileManager.default.removeItem(at: url)
        loadSkills()
    }

    func buildSystemPromptAdditions() -> String {
        var parts: [String] = []
        parts.append("## Grogu Soul\n" + String(soulText.prefix(2_400)))
        if !memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let memTail = String(memoryText.suffix(Self.maxPromptMemoryChars))
            parts.append("## Persistent Memory (`MEMORY.md`)\n" + memTail)
        }
        if !skills.isEmpty {
            let catalog = skills.prefix(20).map { "- `\($0.name)`: \($0.summary)" }.joined(separator: "\n")
            parts.append("## Available Local Skills (call `skill_read` to load full steps)\n" + catalog)
        }
        return parts.joined(separator: "\n\n")
    }

    private func bootstrapDefaults() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: soulURL.path) {
            try? Self.defaultSoul.write(to: soulURL, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: memoryURL.path) {
            try? Self.defaultMemory.write(to: memoryURL, atomically: true, encoding: .utf8)
        }
        let sampleSkill = skillsDir.appendingPathComponent("ios-native-first.md")
        if !fm.fileExists(atPath: sampleSkill.path) {
            try? Self.defaultSkill.write(to: sampleSkill, atomically: true, encoding: .utf8)
        }
    }

    private func loadSkills() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: nil
        ) else {
            skills = []
            return
        }
        skills = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                let summary = text
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? "Custom workflow skill"
                return SkillDoc(name: name, summary: String(summary.prefix(120)), content: text)
            }
    }

    private static let defaultSoul = """
    You are Grogu, an on-device native iOS/iPadOS autonomous assistant.
    You are GroguApp and host your own MCP server; use `grogu_self_info`, `mcp_server_manage`, `runner_wake` and `permissions_status` to inspect and fix your own setup.
    Principles:
    1. Prefer Native OS APIs (device_info, clipboard, calendar, reminders, contacts, location, http_fetch, url_open, shortcuts) and connected MCP tools BEFORE slow GUI automation.
    2. When GUI interaction IS needed, read `ios_ui_tree` or `ios_find_element` first; use `ios_screenshot` + `ios_ocr` when trees lack webview/canvas text.
    3. Use exact coordinate taps (`ios_tap`) and non-blocking URL launches (`ios_open_url`) for speed.
    4. Never fabricate results, never log secrets, and stop immediately to ask confirmation before financial payments, irreversible deletions, or public posts.
    """

    private static let defaultMemory = """
    # Grogu Workspace Memory
    Store concise user preferences, app URL schemes, and stable facts here.
    """

    private static let defaultSkill = """
    # iOS Native-First Checklist
    Always check native OS tools and URL schemes before opening Settings or third-party apps via GUI.
    - Battery / RAM check: `device_info`
    - Open web / deep link: `url_open` or `ios_open_url`
    - Calendar / Reminders: `calendar_list_events`, `calendar_create_event`, `reminders_list`, `reminders_create`
    - Screenshots after mutating tap: call `ios_wait_stable` or capture updated `ios_ui_tree`.
    - `ios_*` tools failing because GroguRunner is down: call `runner_wake`, then retry.
    """
}
