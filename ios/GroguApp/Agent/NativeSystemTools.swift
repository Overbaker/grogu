import Contacts
import CoreLocation
import Darwin
import EventKit
import Foundation
import Photos
import UIKit
import UserNotifications

/// Native iOS OS-level capabilities executed directly inside GroguApp without GUI hops
/// (aligned with Android Eta's OS-first philosophy).
@MainActor
final class NativeSystemTools: NSObject, CLLocationManagerDelegate {
    static let shared = NativeSystemTools()

    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()
    private var locationManager: CLLocationManager?
    private var locationContinuation: CheckedContinuation<CLLocation?, Error>?

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private override init() {
        super.init()
    }

    // MARK: - Tool Schema Definitions

    static let toolSchemas: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "device_info",
            description: "Read iPhone/iPad model, iOS version, battery level/state, thermal state, and Jetsam memory footprint without touching GUI.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        MCPToolDescriptor(
            name: "clipboard_get",
            description: "Read current plain-text contents of the iOS system clipboard.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        MCPToolDescriptor(
            name: "clipboard_set",
            description: "Write plain text to the iOS system clipboard.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string"), "description": .string("Text to place in clipboard")]),
                ]),
                "required": .array([.string("text")]),
            ])
        ),
        MCPToolDescriptor(
            name: "calendar_list_events",
            description: "List upcoming calendar events cleanly via native EventKit.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "days_ahead": .object(["type": .string("integer"), "description": .string("Days forward from now (default 7, max 60)")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max events to return (default 25)")]),
                ]),
            ])
        ),
        MCPToolDescriptor(
            name: "calendar_create_event",
            description: "Create a native iOS calendar event using ISO-8601 timestamps.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string")]),
                    "start_iso": .object(["type": .string("string")]),
                    "end_iso": .object(["type": .string("string")]),
                    "location": .object(["type": .string("string")]),
                    "notes": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("title"), .string("start_iso"), .string("end_iso")]),
            ])
        ),
        MCPToolDescriptor(
            name: "reminders_list",
            description: "List incomplete (or all) Apple Reminders natively via EventKit.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "include_completed": .object(["type": .string("boolean")]),
                    "limit": .object(["type": .string("integer")]),
                ]),
            ])
        ),
        MCPToolDescriptor(
            name: "reminders_create",
            description: "Create a native Apple Reminder item.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string")]),
                    "notes": .object(["type": .string("string")]),
                    "due_iso": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("title")]),
            ])
        ),
        MCPToolDescriptor(
            name: "contacts_search",
            description: "Search iOS Contacts by name (bounded to 15 results).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        MCPToolDescriptor(
            name: "location_get",
            description: "Read current GPS coordinates and accuracy via CoreLocation.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        MCPToolDescriptor(
            name: "photos_list_recent",
            description: "List metadata (date, pixel dimensions, media type) of recent Photo Library items without decoding full images.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer")]),
                ]),
            ])
        ),
        MCPToolDescriptor(
            name: "notification_post",
            description: "Post a local notification banner/sound on the device.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string")]),
                    "body": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("title"), .string("body")]),
            ])
        ),
        MCPToolDescriptor(
            name: "url_open",
            description: "Open an https:// or app URL scheme from GroguApp directly via UIApplication.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("url")]),
            ])
        ),
        MCPToolDescriptor(
            name: "shortcut_run",
            description: "Trigger an Apple Shortcut by name with optional text input.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                    "input": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("name")]),
            ])
        ),
        MCPToolDescriptor(
            name: "http_fetch",
            description: "Perform a bounded HTTP GET or POST request directly from the device (max 128 KB response).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string")]),
                    "method": .object(["type": .string("string")]),
                    "body": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("url")]),
            ])
        ),
    ]

    // MARK: - Execution

    func execute(toolName: String, arguments: [String: JSONValue]) async -> MCPToolCallResult {
        do {
            let resultValue: [String: JSONValue]
            switch toolName {
            case "device_info":
                resultValue = await getDeviceInfo()
            case "clipboard_get":
                resultValue = ["text": .string(UIPasteboard.general.string ?? "")]
            case "clipboard_set":
                let text = arguments.string("text") ?? ""
                UIPasteboard.general.string = text
                resultValue = ["ok": .bool(true), "chars": .int(text.count)]
            case "calendar_list_events":
                resultValue = try await listCalendarEvents(
                    daysAhead: min(max(arguments.int("days_ahead") ?? 7, 1), 60),
                    limit: min(max(arguments.int("limit") ?? 25, 1), 60)
                )
            case "calendar_create_event":
                resultValue = try await createCalendarEvent(arguments)
            case "reminders_list":
                resultValue = try await listReminders(
                    includeCompleted: arguments.bool("include_completed") ?? false,
                    limit: min(max(arguments.int("limit") ?? 25, 1), 60)
                )
            case "reminders_create":
                resultValue = try await createReminder(arguments)
            case "contacts_search":
                resultValue = try await searchContacts(query: arguments.string("query") ?? "")
            case "location_get":
                resultValue = try await getCurrentLocation()
            case "photos_list_recent":
                resultValue = try await listRecentPhotos(limit: min(max(arguments.int("limit") ?? 10, 1), 30))
            case "notification_post":
                resultValue = try await postNotification(
                    title: arguments.string("title") ?? "Grogu",
                    body: arguments.string("body") ?? ""
                )
            case "url_open":
                guard let raw = arguments.string("url"), let url = URL(string: raw) else {
                    return .error("url_open requires a valid url")
                }
                let ok = await UIApplication.shared.open(url)
                resultValue = ["url": .string(raw), "opened": .bool(ok)]
            case "shortcut_run":
                guard let name = arguments.string("name"), !name.isEmpty else {
                    return .error("shortcut_run requires name")
                }
                var comps = URLComponents(string: "shortcuts://run-shortcut")!
                var items = [URLQueryItem(name: "name", value: name)]
                if let input = arguments.string("input"), !input.isEmpty {
                    items.append(URLQueryItem(name: "input", value: "text"))
                    items.append(URLQueryItem(name: "text", value: input))
                }
                comps.queryItems = items
                let opened: Bool
                if let targetURL = comps.url {
                    opened = await UIApplication.shared.open(targetURL)
                } else {
                    opened = false
                }
                resultValue = ["shortcut": .string(name), "opened": .bool(opened)]
            case "http_fetch":
                resultValue = try await httpFetch(arguments)
            default:
                return .error("Unknown native tool: \(toolName)")
            }
            return .json(resultValue)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Tool Implementations

    private func getDeviceInfo() async -> [String: JSONValue] {
        let dev = UIDevice.current
        dev.isBatteryMonitoringEnabled = true
        let mem = MemorySnapshot.current()
        let batteryState: String
        switch dev.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        default: batteryState = "unknown"
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        var info: [String: JSONValue] = [
            "model_identifier": .string(Self.modelIdentifier()),
            "system_name": .string(dev.systemName),
            "system_version": .string(dev.systemVersion),
            "battery_percent": .int(dev.batteryLevel >= 0 ? Int((dev.batteryLevel * 100).rounded()) : -1),
            "battery_state": .string(batteryState),
            "thermal_state": .string(thermal),
            "phys_footprint_mb": .double(mem.physFootprintMB),
            "available_mb": .double(mem.availableMB),
            "memory_pressure": .string(mem.pressure.rawValue),
        ]
        if let runnerHealth = try? await RunnerClient.shared.health() {
            info["runner"] = .object(runnerHealth)
        }
        return info
    }

    private func listCalendarEvents(daysAhead: Int, limit: Int) async throws -> [String: JSONValue] {
        let granted = try await eventStore.requestFullAccessToEvents()
        guard granted else {
            throw NSError(domain: "GroguNative", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access denied"])
        }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: start) ?? start.addingTimeInterval(Double(daysAhead) * 86400)
        let pred = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let iso = ISO8601DateFormatter()
        let events = eventStore.events(matching: pred)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { ev in
                JSONValue.object([
                    "title": .string(ev.title ?? ""),
                    "start": .string(iso.string(from: ev.startDate)),
                    "end": .string(iso.string(from: ev.endDate)),
                    "all_day": .bool(ev.isAllDay),
                    "location": .string(ev.location ?? ""),
                    "calendar": .string(ev.calendar.title),
                ])
            }
        return ["events": .array(Array(events))]
    }

    private func createCalendarEvent(_ args: [String: JSONValue]) async throws -> [String: JSONValue] {
        let granted = try await eventStore.requestFullAccessToEvents()
        guard granted else {
            throw NSError(domain: "GroguNative", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access denied"])
        }
        let iso = ISO8601DateFormatter()
        guard let title = args.string("title"),
              let startStr = args.string("start_iso"),
              let endStr = args.string("end_iso"),
              let start = iso.date(from: startStr),
              let end = iso.date(from: endStr) else {
            throw NSError(domain: "GroguNative", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid title or ISO-8601 start_iso/end_iso"])
        }
        let ev = EKEvent(eventStore: eventStore)
        ev.title = title
        ev.startDate = start
        ev.endDate = end
        ev.location = args.string("location")
        ev.notes = args.string("notes")
        ev.calendar = eventStore.defaultCalendarForNewEvents
        try eventStore.save(ev, span: .thisEvent)
        return ["created": .bool(true), "title": .string(title), "event_id": .string(ev.eventIdentifier ?? "")]
    }

    private func listReminders(includeCompleted: Bool, limit: Int) async throws -> [String: JSONValue] {
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else {
            throw NSError(domain: "GroguNative", code: 3, userInfo: [NSLocalizedDescriptionKey: "Reminders access denied"])
        }
        let pred: NSPredicate = includeCompleted
            ? eventStore.predicateForReminders(in: nil)
            : eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let iso = ISO8601DateFormatter()

        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            eventStore.fetchReminders(matching: pred) { items in
                cont.resume(returning: items ?? [])
            }
        }
        let out = reminders.prefix(limit).map { r in
            JSONValue.object([
                "title": .string(r.title ?? ""),
                "completed": .bool(r.isCompleted),
                "due_iso": .string(r.dueDateComponents?.date.map { iso.string(from: $0) } ?? ""),
                "notes": .string(String((r.notes ?? "").prefix(200))),
            ])
        }
        return ["reminders": .array(Array(out))]
    }

    private func createReminder(_ args: [String: JSONValue]) async throws -> [String: JSONValue] {
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else {
            throw NSError(domain: "GroguNative", code: 3, userInfo: [NSLocalizedDescriptionKey: "Reminders access denied"])
        }
        guard let title = args.string("title"), !title.isEmpty else {
            throw NSError(domain: "GroguNative", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing title"])
        }
        let rem = EKReminder(eventStore: eventStore)
        rem.title = title
        rem.notes = args.string("notes")
        rem.calendar = eventStore.defaultCalendarForNewReminders()
        if let dueStr = args.string("due_iso"), let due = ISO8601DateFormatter().date(from: dueStr) {
            rem.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        try eventStore.save(rem, commit: true)
        return ["created": .bool(true), "title": .string(title)]
    }

    private func searchContacts(query: String) async throws -> [String: JSONValue] {
        let granted = try await contactStore.requestAccess(for: .contacts)
        guard granted else {
            throw NSError(domain: "GroguNative", code: 5, userInfo: [NSLocalizedDescriptionKey: "Contacts access denied"])
        }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let pred = CNContact.predicateForContacts(matchingName: query)
        let matches = try contactStore.unifiedContacts(matching: pred, keysToFetch: keys).prefix(15)
        let items = matches.map { c in
            JSONValue.object([
                "name": .string("\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)),
                "phone": .string(c.phoneNumbers.first?.value.stringValue ?? ""),
                "email": .string((c.emailAddresses.first?.value as String?) ?? ""),
            ])
        }
        return ["contacts": .array(Array(items))]
    }

    private func getCurrentLocation() async throws -> [String: JSONValue] {
        let mgr = locationManager ?? CLLocationManager()
        locationManager = mgr
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters

        if mgr.authorizationStatus == .notDetermined {
            mgr.requestWhenInUseAuthorization()
            try? await Task.sleep(for: .milliseconds(800))
        }
        let status = mgr.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw NSError(domain: "GroguNative", code: 6, userInfo: [NSLocalizedDescriptionKey: "Location permission not granted"])
        }

        let loc: CLLocation? = try await withCheckedThrowingContinuation { cont in
            self.locationContinuation = cont
            mgr.requestLocation()
        }
        guard let loc else {
            throw NSError(domain: "GroguNative", code: 6, userInfo: [NSLocalizedDescriptionKey: "Location unavailable"])
        }
        return [
            "latitude": .double(loc.coordinate.latitude),
            "longitude": .double(loc.coordinate.longitude),
            "horizontal_accuracy_m": .double(loc.horizontalAccuracy),
            "timestamp": .string(ISO8601DateFormatter().string(from: loc.timestamp)),
        ]
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.locationContinuation?.resume(returning: locations.last)
            self.locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.locationContinuation?.resume(throwing: error)
            self.locationContinuation = nil
        }
    }

    private func listRecentPhotos(limit: Int) async throws -> [String: JSONValue] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "GroguNative", code: 7, userInfo: [NSLocalizedDescriptionKey: "Photos permission denied"])
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let fetched = PHAsset.fetchAssets(with: options)
        let iso = ISO8601DateFormatter()
        var out: [JSONValue] = []
        fetched.enumerateObjects { asset, _, _ in
            out.append(.object([
                "id": .string(asset.localIdentifier),
                "media_type": .string(asset.mediaType == .video ? "video" : "image"),
                "width": .int(asset.pixelWidth),
                "height": .int(asset.pixelHeight),
                "created": .string(asset.creationDate.map { iso.string(from: $0) } ?? ""),
            ]))
        }
        return ["photos": .array(out)]
    }

    private func postNotification(title: String, body: String) async throws -> [String: JSONValue] {
        let center = UNUserNotificationCenter.current()
        let ok = try await center.requestAuthorization(options: [.alert, .sound])
        guard ok else {
            return ["posted": .bool(false), "reason": .string("Notification authorization denied")]
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = LogRedactor.sanitize(body, maxChars: 240)
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await center.add(req)
        return ["posted": .bool(true)]
    }

    private func httpFetch(_ args: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let urlStr = args.string("url"), let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw NSError(domain: "GroguNative", code: 8, userInfo: [NSLocalizedDescriptionKey: "http_fetch requires valid http/https url"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = (args.string("method") ?? "GET").uppercased()
        if let body = args.string("body") {
            req.httpBody = Data(body.utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await urlSession.data(for: req)
        let maxBytes = 131_072
        let slice = data.prefix(maxBytes)
        let text = String(data: slice, encoding: .utf8) ?? "<binary \(data.count) bytes>"
        return [
            "status": .int((resp as? HTTPURLResponse)?.statusCode ?? 0),
            "truncated": .bool(data.count > maxBytes),
            "body": .string(LogRedactor.sanitize(text, maxChars: 16_000)),
        ]
    }

    private static func modelIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cStr in
                String(cString: cStr)
            }
        }
    }
}
