import SwiftUI

struct MemorySkillsView: View {
    @State private var workspace = WorkspaceStore.shared
    @State private var jetsam = JetsamGuard.shared
    @State private var selectedSection = 0
    @State private var memoryDraft = ""
    @State private var soulDraft = ""
    @State private var showNewSkill = false
    @State private var skillName = ""
    @State private var skillBody = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Section", selection: $selectedSection) {
                    Text("Memory").tag(0)
                    Text("Soul").tag(1)
                    Text("Skills").tag(2)
                    Text("Logs").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)

                Group {
                    switch selectedSection {
                    case 0: memoryEditor
                    case 1: soulEditor
                    case 2: skillsList
                    default: logsView
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Workspace & Telemetry")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                memoryDraft = workspace.memoryText
                soulDraft = workspace.soulText
            }
            .toolbar {
                if selectedSection == 2 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showNewSkill = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showNewSkill) {
                newSkillSheet
            }
        }
    }

    private var memoryEditor: some View {
        VStack(spacing: 10) {
            TextEditor(text: $memoryDraft)
                .font(.caption.monospaced())
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 14)

            HStack {
                Text("\(memoryDraft.count) chars")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save MEMORY.md") {
                    workspace.saveMemory(memoryDraft)
                }
                .buttonStyle(.borderedProminent)
                .tint(GroguTheme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var soulEditor: some View {
        VStack(spacing: 10) {
            TextEditor(text: $soulDraft)
                .font(.caption.monospaced())
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 14)

            HStack {
                Spacer()
                Button("Save SOUL.md") {
                    workspace.saveSoul(soulDraft)
                }
                .buttonStyle(.borderedProminent)
                .tint(GroguTheme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var skillsList: some View {
        List {
            ForEach(workspace.skills) { skill in
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.headline)
                    Text(skill.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(skill.content)
                        .font(.caption2.monospaced())
                        .lineLimit(4)
                        .foregroundStyle(.tertiary)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        workspace.deleteSkill(name: skill.name)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var logsView: some View {
        VStack(spacing: 8) {
            HStack {
                Text(String(format: "Footprint %.1f MB • Free %.0f MB", jetsam.snapshot.physFootprintMB, jetsam.snapshot.availableMB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Trim Caches") {
                    jetsam.trimCaches(reason: "Manual trim")
                }
                .font(.caption)
            }
            .padding(.horizontal, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(jetsam.logs.snapshot().reversed(), id: \.self) { line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
        }
    }

    private var newSkillSheet: some View {
        NavigationStack {
            Form {
                TextField("Skill name (e.g. check-expenses)", text: $skillName)
                TextEditor(text: $skillBody)
                    .frame(minHeight: 180)
                    .font(.caption.monospaced())
            }
            .navigationTitle("New Skill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewSkill = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        workspace.saveSkill(name: skillName, content: skillBody)
                        skillName = ""
                        skillBody = ""
                        showNewSkill = false
                    }
                    .disabled(skillName.isEmpty || skillBody.isEmpty)
                }
            }
        }
    }
}
