import Foundation

/// One clock-in record — core domain vocabulary (the totals engine, the store,
/// and the CSV bridge all speak it). Mirrors the PWA `entries` row
/// (`{ id, date, startTime, endTime, lunchMinutes, isOvertime, incomplete, fromDefault }`),
/// with `startTime`/`endTime` as native `Date?` instead of ISO strings.
struct EntryRecord: Equatable, Sendable, Identifiable {
    var id: String
    var date: String          // "YYYY-MM-DD" (the day the entry belongs to)
    var startTime: Date?
    var endTime: Date?
    var lunchMinutes: Int
    var isOvertime: Bool
    var incomplete: Bool
    var fromDefault: Bool

    init(id: String = UUID().uuidString, date: String,
         startTime: Date? = nil, endTime: Date? = nil,
         lunchMinutes: Int = 0, isOvertime: Bool = false,
         incomplete: Bool = false, fromDefault: Bool = false) {
        self.id = id
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.lunchMinutes = lunchMinutes
        self.isOvertime = isOvertime
        self.incomplete = incomplete
        self.fromDefault = fromDefault
    }

    /// Paid hours for this entry (lunch-deducted). 0 while in-progress/incomplete.
    var paidHours: Double {
        guard !incomplete, startTime != nil, endTime != nil else { return 0 }
        return hoursForEntry(start: startTime, end: endTime, lunchMinutes: Double(lunchMinutes)).hours
    }
}
