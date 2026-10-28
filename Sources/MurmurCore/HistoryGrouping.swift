import Foundation

/// One day of dictations, newest first.
public struct HistoryDay: Identifiable, Equatable {
    public let id: Date
    public let title: String
    public let items: [HistoryItem]
}

public enum HistoryGrouping {
    /// Splits dictations (newest first) into days titled "Today", "Yesterday", or the date.
    public static func days(
        _ items: [HistoryItem], now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> [HistoryDay] {
        var days: [HistoryDay] = []
        for item in items {
            let start = calendar.startOfDay(for: item.date)
            if let last = days.last, last.id == start {
                days[days.count - 1] = HistoryDay(id: start, title: last.title, items: last.items + [item])
            } else {
                days.append(HistoryDay(id: start, title: title(for: start, now: now, calendar: calendar, locale: locale), items: [item]))
            }
        }
        return days
    }

    private static func title(for day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = style.weekday(.wide).month(.wide).day()
        return day.formatted(style)
    }
}

extension HistoryItem {
    /// True when the search text appears in what was typed, what was heard, or the app it went to.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(q)
            || rawText.localizedCaseInsensitiveContains(q)
            || (app?.localizedCaseInsensitiveContains(q) ?? false)
    }
}
