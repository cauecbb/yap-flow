import Foundation
import Testing
@testable import Yap

struct DictationStatsTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }()

    /// Thursday 2026-11-26, 15:00 in São Paulo.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15))!
    }

    private func daysAgo(_ days: Int, hour: Int = 10) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private func entry(_ words: Int, _ date: Date, _ duration: Double? = 10) -> DictationStats.Entry {
        .init(words: words, createdAt: date, duration: duration)
    }

    @Test func countsWordsAcrossSpacesAndLineBreaks() {
        #expect(DictationStats.wordCount("manda pro  Morgan\nhoje") == 4)
        #expect(DictationStats.wordCount("   ") == 0)
    }

    @Test func emptyHistoryHasNoSpeedAndNoStreak() {
        let stats = DictationStats(entries: [], now: now, calendar: calendar)
        #expect(stats.dictations == 0)
        #expect(stats.words == 0)
        #expect(stats.wordsPerMinute == nil)
        #expect(stats.streakDays == 0)
        #expect(stats.minutesSaved == 0)
    }

    @Test func speedIsTotalWordsOverTotalSpeakingTime() {
        // 50 words in 20 s and 100 words in 40 s: 150 words in a minute.
        let stats = DictationStats(entries: [entry(50, daysAgo(0), 20), entry(100, daysAgo(0), 40)], now: now, calendar: calendar)
        #expect(stats.wordsPerMinute == 150)
    }

    @Test func tapsDoNotSkewTheSpeed() {
        let stats = DictationStats(entries: [entry(60, daysAgo(0), 30), entry(3, daysAgo(0), 0.4)], now: now, calendar: calendar)
        #expect(stats.wordsPerMinute == 120)
        #expect(stats.words == 63)
    }

    @Test func timeSavedComparesTypingWithSpeaking() {
        // 400 words: 10 min to type at 40 wpm, 2 min spoken.
        let stats = DictationStats(entries: [entry(400, daysAgo(0), 120)], now: now, calendar: calendar)
        #expect(stats.minutesSaved == 8)
    }

    @Test func timeSavedNeverGoesNegative() {
        let stats = DictationStats(entries: [entry(2, daysAgo(0), 60)], now: now, calendar: calendar)
        #expect(stats.minutesSaved == 0)
    }

    @Test func streakCountsBackFromToday() {
        let stats = DictationStats(
            entries: [entry(5, daysAgo(0)), entry(5, daysAgo(0, hour: 8)), entry(5, daysAgo(1)), entry(5, daysAgo(2)), entry(5, daysAgo(4))],
            now: now, calendar: calendar
        )
        #expect(stats.streakDays == 3)
    }

    @Test func streakSurvivesUntilTheDayEnds() {
        // Nothing yet today, but yesterday and the day before count.
        let stats = DictationStats(entries: [entry(5, daysAgo(1)), entry(5, daysAgo(2))], now: now, calendar: calendar)
        #expect(stats.streakDays == 2)
    }

    @Test func streakResetsAfterAMissedDay() {
        let stats = DictationStats(entries: [entry(5, daysAgo(2)), entry(5, daysAgo(3))], now: now, calendar: calendar)
        #expect(stats.streakDays == 0)
    }

    @Test func formatsMinutes() {
        #expect(DictationStats.formatMinutes(0) == "0m")
        #expect(DictationStats.formatMinutes(45) == "45m")
        #expect(DictationStats.formatMinutes(60) == "1h")
        #expect(DictationStats.formatMinutes(134) == "2h 14m")
    }

    @Test func groupsByDayKeepingOrder() {
        let dates = [daysAgo(0, hour: 14), daysAgo(0, hour: 9), daysAgo(1, hour: 23), daysAgo(3)]
        let groups = DayGroup.group(dates, date: { $0 }, calendar: calendar)
        #expect(groups.count == 3)
        #expect(groups[0].items == [dates[0], dates[1]])
        #expect(groups[1].items == [dates[2]])
        #expect(groups[2].items == [dates[3]])
    }

    @Test func titlesTodayAndYesterday() {
        #expect(DayGroup<Date>.title(for: daysAgo(0), now: now, calendar: calendar) == "Today")
        #expect(DayGroup<Date>.title(for: daysAgo(1), now: now, calendar: calendar) == "Yesterday")
        #expect(DayGroup<Date>.title(for: daysAgo(3), now: now, calendar: calendar) != "Yesterday")
    }
}
