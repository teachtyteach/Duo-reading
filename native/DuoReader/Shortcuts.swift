import AppIntents

/// "Hey Siri, continue reading in Duo Reader"
struct ContinueReadingIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue Reading"
    static var description: IntentDescription = IntentDescription("Opens your current book where you left off.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NativeBridge.shared.send("window.duoContinue && window.duoContinue()")
        return .result()
    }
}

/// "Hey Siri, how much have I read today in Duo Reader"
struct ReadingTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "Reading Today"
    static var description: IntentDescription = IntentDescription("Tells you how many minutes you’ve read today and your streak.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let defaults = UserDefaults.standard
        let isToday = defaults.string(forKey: "statsDay") == Reminders.dayKey(Date())
        let minutes = isToday ? defaults.integer(forKey: "todayMin") : 0
        let goal = max(1, defaults.integer(forKey: "goal"))
        let streak = defaults.integer(forKey: "streak")
        let streakText = streak == 1 ? "1 day" : "\(streak) days"
        let message: String
        if minutes >= goal {
            message = "You’ve read \(minutes) minutes today. Goal met! Your streak is \(streakText)."
        } else {
            message = "You’ve read \(minutes) of \(goal) minutes today. Your streak is \(streakText)."
        }
        return .result(dialog: "\(message)")
    }
}

struct DuoReaderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueReadingIntent(),
            phrases: [
                "Continue reading in \(.applicationName)",
                "Open my book in \(.applicationName)"
            ],
            shortTitle: "Continue Reading",
            systemImageName: "book"
        )
        AppShortcut(
            intent: ReadingTodayIntent(),
            phrases: [
                "How much have I read today in \(.applicationName)",
                "Check my reading in \(.applicationName)"
            ],
            shortTitle: "Reading Today",
            systemImageName: "chart.bar"
        )
    }
}
