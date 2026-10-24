import Foundation
import UIKit
import CoreSpotlight
import UniformTypeIdentifiers
import UserNotifications

/// Passes events between the native app and the web reader.
final class NativeBridge {
    static let shared = NativeBridge()

    weak var host: WebHostController?
    private var pending: [String] = []
    private(set) var isReady = false

    // MARK: Sending JavaScript to the reader

    func send(_ script: String) {
        if isReady, let host = host {
            host.runJavaScript(script)
        } else {
            pending.append(script)
        }
    }

    func markReady() {
        isReady = true
        let queued = pending
        pending.removeAll()
        queued.forEach { host?.runJavaScript($0) }
    }

    func markNotReady() {
        isReady = false
    }

    /// Makes a string safe to drop into JavaScript source.
    static func js(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    // MARK: Opening book files from Files, Mail, Safari, or the share sheet

    static var importFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imports", isDirectory: true)
    }

    func importFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let folderName = UUID().uuidString
        let folder = NativeBridge.importFolder.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            let name = url.lastPathComponent
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let address = "duoreader://app/__import/\(folderName)/\(encoded)"
            send("window.duoImport && window.duoImport(\(NativeBridge.js(address)), \(NativeBridge.js(name)))")
        } catch {
            send("window.duoToast && window.duoToast(\(NativeBridge.js("That file couldn’t be opened. Try saving it to Files first.")))")
        }
    }

    // MARK: Library state (Siri, Spotlight, reminders)

    func receiveState(_ body: [String: Any]) {
        let defaults = UserDefaults.standard
        if let current = body["current"] as? [String: Any] {
            defaults.set(current["title"] as? String ?? "", forKey: "currentTitle")
            defaults.set(current["author"] as? String ?? "", forKey: "currentAuthor")
            defaults.set(current["pct"] as? Double ?? 0, forKey: "currentPct")
        }
        defaults.set(body["today"] as? Int ?? 0, forKey: "todayMin")
        defaults.set(body["goal"] as? Int ?? 15, forKey: "goal")
        defaults.set(body["streak"] as? Int ?? 0, forKey: "streak")
        defaults.set(body["day"] as? String ?? "", forKey: "statsDay")

        if let books = body["books"] as? [[String: Any]] {
            indexBooks(books)
        }
        Reminders.shared.refresh()
    }

    private var lastIndexed = ""

    private func indexBooks(_ books: [[String: Any]]) {
        let signature = books.compactMap { $0["id"] as? String }.joined(separator: ",")
        guard signature != lastIndexed else { return }
        lastIndexed = signature

        let items: [CSSearchableItem] = books.compactMap { book in
            guard let id = book["id"] as? String, let title = book["title"] as? String else { return nil }
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
            attributes.title = title
            attributes.displayName = title
            let author = book["author"] as? String ?? ""
            attributes.contentDescription = author.isEmpty ? "Book in Duo Reader" : "by \(author) · Duo Reader"
            return CSSearchableItem(uniqueIdentifier: "book:" + id, domainIdentifier: "books", attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: ["books"]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }

    func openFromSpotlight(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        let id = identifier.replacingOccurrences(of: "book:", with: "")
        send("window.duoOpenBook && window.duoOpenBook(\(NativeBridge.js(id)))")
    }
}

/// Daily streak reminders.
final class Reminders {
    static let shared = Reminders()

    private let ids = (0..<7).map { "streak-\($0)" }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "remindersOn") }
        set { UserDefaults.standard.set(newValue, forKey: "remindersOn") }
    }

    func configure(on: Bool, hour: Int, minute: Int) {
        enabled = on
        UserDefaults.standard.set(hour, forKey: "remindHour")
        UserDefaults.standard.set(minute, forKey: "remindMinute")
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard on else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    self.refresh()
                } else {
                    self.enabled = false
                    NativeBridge.shared.send("window.duoToast && window.duoToast(\(NativeBridge.js("Turn on notifications for Duo Reader in Settings to get reminders.")))")
                }
            }
        }
    }

    func refresh() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard enabled else { return }

        let defaults = UserDefaults.standard
        let hour = defaults.object(forKey: "remindHour") as? Int ?? 19
        let minute = defaults.object(forKey: "remindMinute") as? Int ?? 30
        let goal = max(1, defaults.integer(forKey: "goal"))
        let streak = defaults.integer(forKey: "streak")
        let todayKey = Reminders.dayKey(Date())
        let today = defaults.string(forKey: "statsDay") == todayKey ? defaults.integer(forKey: "todayMin") : 0
        let calendar = Calendar.current

        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: Date()),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if fire <= Date() { continue }
            if offset == 0 && today >= goal { continue }

            let content = UNMutableNotificationContent()
            if offset == 0 && streak > 0 {
                content.title = "Keep your \(streak)-day streak"
                content.body = "Read \(max(1, goal - today)) more minutes today to make it \(streak + 1)."
            } else {
                content.title = "Time to read"
                content.body = "A few pages tonight? Your goal is \(goal) minutes."
            }
            content.sound = .default
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            center.add(UNNotificationRequest(identifier: ids[offset], content: content, trigger: trigger))
        }
    }

    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
