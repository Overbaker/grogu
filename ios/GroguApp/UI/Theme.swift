import SwiftUI

enum GroguTheme {
    static let accent = Color(red: 0.14, green: 0.62, blue: 0.56)
    static let warning = Color(red: 0.88, green: 0.55, blue: 0.16)
    static let critical = Color(red: 0.85, green: 0.24, blue: 0.26)
    static let surface = Color(.secondarySystemGroupedBackground)

    static func pressureColor(_ pressure: MemorySnapshot.Pressure) -> Color {
        switch pressure {
        case .nominal: return accent
        case .elevated: return warning
        case .critical: return critical
        }
    }
}

struct GlassPill: View {
    let icon: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(label)
                .font(.caption2.monospacedDigit().weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.8)
        )
    }
}

struct SectionCard<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
            )
        }
    }
}
