import Foundation

/// The numbers on the Home page, worked out from the dictation history.
struct DictationStats: Equatable {
    /// One dictation, reduced to what the stats need.
    struct Entry {
        let words: Int
        let createdAt: Date
        let duration: Double?
    }

    /// A typical typing speed, used to estimate the time dictation saved.
    static let typingWordsPerMinute: Double = 40

    /// Recordings shorter than this are taps or cancels, not speech, and would skew the speed.
    static let minimumSpeechSeconds: Double = 1

    var dictations = 0
    var words = 0
    /// Average speaking speed. Nil until there is a recording long enough to measure.
    var wordsPerMinute: Int?
    /// Consecutive days with at least one dictation, ending today, or yesterday when today has none yet.
    var streakDays = 0
    var minutesSaved = 0

    init() {}

    init(entries: [Entry], now: Date = .now, calendar: Calendar = .current) {
        dictations = entries.count
        words = entries.reduce(0) { $0 + $1.words }

        let timed = entries.filter { ($0.duration ?? 0) >= Self.minimumSpeechSeconds }
        let timedWords = timed.reduce(0) { $0 + $1.words }
        let speakingMinutes = timed.reduce(0) { $0 + ($1.duration ?? 0) } / 60
        if speakingMinutes > 0, timedWords > 0 {
            wordsPerMinute = Int((Double(timedWords) / speakingMinutes).rounded())
        }

        // Untimed dictations count as spoken at the measured speed, so they neither
        // inflate nor erase the saving.
        let untimedWords = Double(words - timedWords)
        let untimedMinutes = wordsPerMinute.map { untimedWords / Double(max($0, 1)) } ?? 0
        let typingMinutes = Double(words) / Self.typingWordsPerMinute
        minutesSaved = max(0, Int((typingMinutes - speakingMinutes - untimedMinutes).rounded()))

        streakDays = Self.streak(days: entries.map(\.createdAt), now: now, calendar: calendar)
    }

    static func make(from transcripts: [Transcript], now: Date = .now, calendar: Calendar = .current) -> DictationStats {
        DictationStats(
            entries: transcripts.map { Entry(words: wordCount($0.text), createdAt: $0.createdAt, duration: $0.durationSeconds) },
            now: now,
            calendar: calendar
        )
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func streak(days dates: [Date], now: Date, calendar: Calendar) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        let today = calendar.startOfDay(for: now)
        guard var day = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today),
              days.contains(day) else { return 0 }

        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// "45m", "2h 14m".
    static func formatMinutes(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }
}

/// Items that fall on the same calendar day, newest day first.
struct DayGroup<Item>: Identifiable {
    let day: Date
    let items: [Item]
    var id: Date { day }

    /// Keeps the order of `items` inside each day, so pass them newest first.
    static func group(_ items: [Item], date: (Item) -> Date, calendar: Calendar = .current) -> [DayGroup<Item>] {
        var groups: [DayGroup<Item>] = []
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if let last = groups.last, last.day == day {
                groups[groups.count - 1] = DayGroup(day: day, items: last.items + [item])
            } else {
                groups.append(DayGroup(day: day, items: [item]))
            }
        }
        return groups
    }

    /// "Today", "Yesterday", or a short date such as "Mon, Nov 23".
    static func title(for day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return sameYear
            ? day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : day.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
