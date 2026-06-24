import Foundation

/// How an entry's worked hours are classified for pay in **Maxiflex** mode.
/// Stored per entry and **user-editable**; a period default only sets the value
/// stamped on *new* entries — changing it never reclassifies existing hours.
/// (8-hour mode ignores this — its OT is purely schedule-based.)
///
/// - `auto`       — engine decides: hours beyond schedule (once the period passes
///                  80, leave included) pay **overtime**; the rest regular. Default.
/// - `autoCredit` — like `auto`, but the beyond-schedule portion banks as
///                  **credit hours** (no premium). The "flex period" default.
/// - `overtime`   — force the **whole** entry to overtime (ordered OT).
/// - `credit`     — force the **whole** entry to credit hours.
/// - `regular`    — force the **whole** entry to regular (never premium).
enum PayKind: String, Codable, Sendable, CaseIterable {
    case auto, autoCredit, overtime, credit, regular
}

/// One clock-in record — core domain vocabulary (the totals engine, the store,
/// and the CSV bridge all speak it). Mirrors the PWA `entries` row
/// (`{ id, date, startTime, endTime, lunchMinutes, payKind, incomplete, fromDefault }`),
/// with `startTime`/`endTime` as native `Date?` instead of ISO strings.
struct EntryRecord: Equatable, Sendable, Identifiable {
    var id: String
    var date: String          // "YYYY-MM-DD" (the day the entry belongs to)
    var startTime: Date?
    var endTime: Date?
    var lunchMinutes: Int
    var payKind: PayKind
    var incomplete: Bool
    var fromDefault: Bool

    init(id: String = UUID().uuidString, date: String,
         startTime: Date? = nil, endTime: Date? = nil,
         lunchMinutes: Int = 0, payKind: PayKind = .auto,
         incomplete: Bool = false, fromDefault: Bool = false) {
        self.id = id
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.lunchMinutes = lunchMinutes
        self.payKind = payKind
        self.incomplete = incomplete
        self.fromDefault = fromDefault
    }

    /// Legacy bool bridge so existing call sites and the CSV "Overtime yes/no"
    /// column keep working: reads true only for forced overtime; the setter maps
    /// true→`overtime`, false→`auto`.
    var isOvertime: Bool {
        get { payKind == .overtime }
        set { payKind = newValue ? .overtime : .auto }
    }

    /// Paid hours for this entry (lunch-deducted). 0 while in-progress/incomplete.
    var paidHours: Double {
        guard !incomplete, startTime != nil, endTime != nil else { return 0 }
        return hoursForEntry(start: startTime, end: endTime, lunchMinutes: Double(lunchMinutes)).hours
    }
}
