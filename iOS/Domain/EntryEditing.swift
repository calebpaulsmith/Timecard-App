import Foundation

/// Pure helpers backing the Day editor's clock-in/out + entry/time editing.
/// No SwiftUI/SwiftData — unit-tested like the rest of Domain.

/// The lunch minutes the creation flow stamps onto a new/edited entry: 30 when
/// the span is ≥ 4h, else 0. The totals engine deducts from this STORED value
/// (it does not re-derive lunch), so creation is where the auto-deduction rule
/// is applied — mirroring how the PWA persists `lunchMinutes`.
func autoLunchMinutes(start: Date, end: Date) -> Int {
    let span = end.timeIntervalSince(start) / 3600
    return span >= TimeConstants.lunchThresholdHours ? Int((TimeConstants.lunchDeductHours * 60).rounded()) : 0
}

/// Same auto-lunch rule from a span given in minutes (30 when ≥ 4h, else 0).
/// Used by the entry editor to seed the editable lunch field from the picked
/// start/end before any Dates exist.
func autoLunchMinutes(spanMinutes: Int) -> Int {
    spanMinutes >= Int(TimeConstants.lunchThresholdHours * 60)
        ? Int((TimeConstants.lunchDeductHours * 60).rounded())
        : 0
}

/// Minutes since local midnight for a Date (0..1439).
func minutesOfDay(_ date: Date, calendar: Calendar = DomainCalendar.shared) -> Int {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

/// 12-hour clock components → minutes since midnight. `hour12` is 1...12.
func minutesFromClock(hour12: Int, minute: Int, isPM: Bool) -> Int {
    var h = hour12 % 12          // 12 → 0
    if isPM { h += 12 }
    return h * 60 + minute
}

/// Minutes since midnight → 12-hour clock components (the picker model).
func clockFromMinutes(_ m: Int) -> (hour12: Int, minute: Int, isPM: Bool) {
    let mm = ((m % 1440) + 1440) % 1440
    let h24 = mm / 60
    let minute = mm % 60
    let isPM = h24 >= 12
    var h12 = h24 % 12
    if h12 == 0 { h12 = 12 }
    return (h12, minute, isPM)
}

/// Outcome of scanning a day's entries for the running clock-in.
struct OpenEntryScan: Equatable {
    /// The id of the still-running (open, < 16h) entry, if any.
    var openId: String?
    /// Ids of open entries past the 16h cutoff — the caller marks these
    /// incomplete (they then contribute 0 hours), mirroring the PWA.
    var forgottenIds: [String]
}

/// Find the current open entry and any "forgotten" (open > 16h) ones. An entry
/// is open when it has a `startTime`, no `endTime`, and isn't already
/// incomplete. Ports the PWA's `getOpenEntry` 16-hour rule.
func scanOpenEntry(_ entries: [EntryRecord], now: Date = Date()) -> OpenEntryScan {
    var openId: String?
    var openStart: Date?
    var forgotten: [String] = []
    for e in entries where e.endTime == nil && !e.incomplete {
        guard let start = e.startTime else { continue }
        if isForgotten(start: start, now: now) {
            forgotten.append(e.id)
        } else if openStart == nil || start > openStart! {
            openId = e.id
            openStart = start
        }
    }
    return OpenEntryScan(openId: openId, forgottenIds: forgotten)
}
