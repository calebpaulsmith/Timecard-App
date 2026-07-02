import Foundation

/// "Work wraps around leave" — the entry edits behind the leave drag-to-place
/// (LOGIC-FREEZE §3). When the teal leave block is dropped **on top of** a work
/// entry, the workday reshapes around it: an entry strictly containing the
/// block splits into two entries (before/after), an entry the block overlaps at
/// an edge is trimmed, and an entry the block fully covers is removed. Moving
/// the block off a previous placement first **heals** that split (merges the
/// two pieces that exactly abut the old span) so the "hole" follows the block
/// instead of shredding the day a little more on every drag.
///
/// Pure and unit-tested; `TimecardStore.placeLeave` applies the plan on commit
/// and `DayTimelineView` renders the same plan live mid-drag as a preview.

/// The entry edits a leave placement implies: rows to write + rows to remove.
struct LeavePlacementPlan: Equatable {
    var upserts: [EntryRecord] = []
    var deleteIds: [String] = []
    var isEmpty: Bool { upserts.isEmpty && deleteIds.isEmpty }
}

/// The merge that undoes a previous split: the combined entry + the id of the
/// now-redundant second piece.
struct LeaveHeal: Equatable {
    var merged: EntryRecord
    var deleteId: String
}

/// If exactly one complete entry ends at `leaveStartMin` and exactly one starts
/// at `leaveEndMin` (the signature of a previous split), merge them back into a
/// single entry — earlier piece's id/start, later piece's end, lunches summed.
/// Returns nil when the pattern doesn't match (the user has since moved a
/// handle, or the day was never split), in which case nothing is merged.
func healAroundLeave(entries: [EntryRecord], leaveStartMin: Int, leaveEndMin: Int,
                     calendar: Calendar = DomainCalendar.shared) -> LeaveHeal? {
    let complete = entries.filter { $0.startTime != nil && $0.endTime != nil && !$0.incomplete }
    let before = complete.filter { entryEndMinutes($0, calendar: calendar) == leaveStartMin }
    let after = complete.filter {
        guard let st = $0.startTime else { return false }
        return minutesOfDay(st, calendar: calendar) == leaveEndMin
    }
    guard before.count == 1, after.count == 1,
          let b = before.first, let a = after.first,
          b.id != a.id, b.payKind == a.payKind else { return nil }
    var merged = b
    merged.endTime = a.endTime
    merged.lunchMinutes = b.lunchMinutes + a.lunchMinutes
    merged.fromDefault = b.fromDefault && a.fromDefault
    return LeaveHeal(merged: merged, deleteId: a.id)
}

/// The full entry-edit plan for placing the day's leave block at `newStartMin`:
/// heal a previous split at `oldStartMin` (when the block is moving), then
/// carve every overlapped entry around the new span. Open (`endTime == nil`)
/// and incomplete entries are never touched — they have no fixed span to carve.
///
/// Splitting keeps the entry's total lunch a single deduction: it stays with
/// the piece containing the original lunch band's midpoint (lunch renders
/// centered on the entry), or falls to the longer piece when the leave swallows
/// that midpoint. The first piece keeps the entry's id; the second gets
/// `makeId(originalId)` (a fresh UUID by default; injectable so tests and the
/// live drag preview stay deterministic).
func leavePlacementPlan(entries: [EntryRecord], date: String, leaveMinutes: Int,
                        newStartMin: Int, oldStartMin: Int? = nil,
                        makeId: (String) -> String = { _ in UUID().uuidString },
                        calendar: Calendar = DomainCalendar.shared) -> LeavePlacementPlan {
    guard leaveMinutes > 0 else { return LeavePlacementPlan() }
    var working = entries.filter { $0.startTime != nil && $0.endTime != nil && !$0.incomplete }
    var plan = LeavePlacementPlan()
    // Upserts keyed by id: a healed merge may be re-carved below, and the last
    // write wins without emitting the intermediate row.
    var pending: [String: EntryRecord] = [:]

    if let old = oldStartMin, old != newStartMin,
       let heal = healAroundLeave(entries: working, leaveStartMin: old,
                                  leaveEndMin: old + leaveMinutes, calendar: calendar) {
        working.removeAll { $0.id == heal.merged.id || $0.id == heal.deleteId }
        working.append(heal.merged)
        pending[heal.merged.id] = heal.merged
        plan.deleteIds.append(heal.deleteId)
    }

    let ls = newStartMin
    let le = newStartMin + leaveMinutes
    for e in working {
        guard let start = e.startTime else { continue }
        let s = minutesOfDay(start, calendar: calendar)
        let en = entryEndMinutes(e, calendar: calendar)
        guard max(s, ls) < min(en, le) else { continue }         // no overlap
        if ls <= s && le >= en {
            // Fully covered — no work left around the leave; remove the entry.
            pending[e.id] = nil
            plan.deleteIds.append(e.id)
        } else if s < ls && le < en {
            // Strictly inside — split into two pieces around the block.
            var first = e
            first.endTime = buildDateTime(date, hour24: ls / 60, minute: ls % 60, calendar: calendar)
            var second = e
            second.id = makeId(e.id)
            second.startTime = buildDateTime(date, hour24: le / 60, minute: le % 60, calendar: calendar)
            let mid = (s + en) / 2
            let lunchToFirst = mid < ls || (mid < le && (ls - s) > (en - le))
            first.lunchMinutes = lunchToFirst ? e.lunchMinutes : 0
            second.lunchMinutes = lunchToFirst ? 0 : e.lunchMinutes
            pending[first.id] = first
            pending[second.id] = second
        } else if ls <= s {
            // Overlaps the left edge — work starts when the leave ends.
            var t = e
            t.startTime = buildDateTime(date, hour24: le / 60, minute: le % 60, calendar: calendar)
            pending[t.id] = t
        } else {
            // Overlaps the right edge — work ends where the leave starts.
            var t = e
            t.endTime = buildDateTime(date, hour24: ls / 60, minute: ls % 60, calendar: calendar)
            pending[t.id] = t
        }
    }
    plan.upserts = pending.values.sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
    return plan
}

/// Apply a plan to an in-memory entry list (the live drag preview): drop the
/// deleted/replaced rows, add the plan's rows, re-sort by start.
func applyLeavePlacementPlan(_ plan: LeavePlacementPlan, to entries: [EntryRecord]) -> [EntryRecord] {
    guard !plan.isEmpty else { return entries }
    var replaced = Set(plan.deleteIds)
    for e in plan.upserts { replaced.insert(e.id) }
    return (entries.filter { !replaced.contains($0.id) } + plan.upserts)
        .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
}
