import AppIntents
import Foundation

/// Native iOS/iPadOS AppIntent forwarding Siri speech directly to Grogu's
/// Fast Decision API + LM Gateway over Tailscale.
/// Configure the gateway URL in Info.plist under `GROGU_GATEWAY_URL`
/// (e.g., `http://100.64.0.1:18830`), or replace the fallback URL below.
@available(iOS 17.0, *)
struct GroguControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Control device with Grogu"
    static var description = IntentDescription(
        "Send a spoken command to the Grogu Tailscale gateway for native UI control or DVT telemetry."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Command",
        requestValueDialog: IntentDialog("What should Grogu do?")
    )
    var command: String

    private static var gatewayBaseURL: String {
        if let val = Bundle.main.object(forInfoDictionaryKey: "GROGU_GATEWAY_URL") as? String,
           !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return val.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "http://100.64.0.1:18830"
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let base = Self.gatewayBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/siri/command") else {
            return .result(dialog: IntentDialog("Invalid Grogu gateway URL."))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": command])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            return .result(dialog: IntentDialog("Gateway returned HTTP \(http.statusCode)."))
        }

        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let speak = (obj?["speak"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .result(dialog: IntentDialog(stringLiteral: speak?.isEmpty == false ? speak! : "Command sent."))
    }
}

@available(iOS 17.0, *)
struct GroguShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GroguControlIntent(),
            phrases: [
                "Control device with \(.applicationName)",
                "Run Grogu command with \(.applicationName)"
            ],
            shortTitle: "Grogu Control",
            systemImageName: "waveform.circle.fill"
        )
    }
}
