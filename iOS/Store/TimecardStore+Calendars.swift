import Foundation

/// Multi-calendar registry (the per-device-calendar config that drives color,
/// timeline tier, and visibility). Stored as a JSON array in the local-only
/// `calendarConfigs` setting — device calendar identifiers are device-specific, so
/// it's excluded from CSV backups (like `eventKitCalendarId`).
///
/// This is the data behind "pick which calendar an event goes to, give each its
/// own color, and choose whether it shows on the timeline page or only on the
/// calendar page." The pure `CalendarConfig` / `CalendarTier` types live in Domain.
extension TimecardStore {

    // MARK: - Registry read/write

    func calendarConfigs() -> [CalendarConfig] {
        guard let raw = rawSetting("calendarConfigs"),
              let arr = JSONValue.decode(raw) as? [Any] else { return [] }
        return arr.compactMap { Self.configFromJSON($0) }
    }

    func setCalendarConfigs(_ configs: [CalendarConfig]) {
        setRawSetting("calendarConfigs", JSONValue.encode(configs.map(Self.configToJSON)))
    }

    func calendarConfig(id: String?) -> CalendarConfig? {
        guard let id, !id.isEmpty else { return nil }
        return calendarConfigs().first { $0.id == id }
    }

    /// Insert or replace one calendar's config (matched by id), preserving order.
    func upsertCalendarConfig(_ config: CalendarConfig) {
        var all = calendarConfigs()
        if let i = all.firstIndex(where: { $0.id == config.id }) { all[i] = config }
        else { all.append(config) }
        // At most one task-default calendar.
        if config.isTaskDefault {
            for i in all.indices where all[i].id != config.id { all[i].isTaskDefault = false }
        }
        setCalendarConfigs(all)
    }

    func removeCalendarConfig(id: String) {
        setCalendarConfigs(calendarConfigs().filter { $0.id != id })
    }

    // MARK: - Derived helpers

    /// Calendar identifiers the app should read/write (the synced ones). Falls back
    /// to the single legacy `eventKitCalendarId` when no registry exists yet, so a
    /// user who set up sync before this feature keeps working.
    func syncedCalendarIds() -> [String] {
        let ids = calendarConfigs().filter { $0.synced }.map { $0.id }
        if !ids.isEmpty { return ids }
        if let legacy = stringSetting("eventKitCalendarId"), !legacy.isEmpty { return [legacy] }
        return []
    }

    /// The calendar new tasks go to (the task-default config, else the first
    /// `.below`-tier synced calendar), or nil if none is set up.
    func taskCalendarId() -> String? {
        let configs = calendarConfigs().filter { $0.synced }
        return configs.first { $0.isTaskDefault }?.id
            ?? configs.first { $0.tier == .tasks }?.id
    }

    /// Resolve an event's timeline tier: the owning calendar's configured tier,
    /// else a fallback from the legacy color token (`.me` → mine, `.person` →
    /// others).
    func tier(forEvent ev: CalEvent) -> CalendarTier {
        if let c = calendarConfig(id: ev.calendarId) { return c.tier }
        return ev.color.lane == .me ? .mine : .others
    }

    /// Resolve an event's color hex from its calendar config, or nil to fall back
    /// to the theme's `EventColor` swatch.
    func colorHex(forEvent ev: CalEvent) -> String? {
        calendarConfig(id: ev.calendarId)?.effectiveColorHex
    }

    /// True when this event's calendar is hidden from the timeline overlay (shows
    /// only on the Calendar page). Events with no registered calendar always show.
    func hiddenFromTimeline(_ ev: CalEvent) -> Bool {
        guard let c = calendarConfig(id: ev.calendarId) else { return false }
        return !c.showOnTimeline
    }

    // MARK: - JSON mapping (house style: Foundation JSON objects via JSONValue)

    private static func configToJSON(_ c: CalendarConfig) -> [String: Any] {
        var d: [String: Any] = [
            "id": c.id, "title": c.title, "account": c.account,
            "tier": c.tier.rawValue, "showOnTimeline": c.showOnTimeline,
            "synced": c.synced, "isTaskDefault": c.isTaskDefault,
        ]
        if let h = c.colorHex { d["colorHex"] = h }
        if let h = c.deviceColorHex { d["deviceColorHex"] = h }
        return d
    }

    private static func configFromJSON(_ any: Any) -> CalendarConfig? {
        guard let d = any as? [String: Any], let id = d["id"] as? String, !id.isEmpty else { return nil }
        return CalendarConfig(
            id: id,
            title: d["title"] as? String ?? "",
            account: d["account"] as? String ?? "",
            colorHex: d["colorHex"] as? String,
            deviceColorHex: d["deviceColorHex"] as? String,
            tier: (d["tier"] as? String).map(CalendarTier.init(stored:)) ?? .mine,
            showOnTimeline: (d["showOnTimeline"] as? NSNumber)?.boolValue ?? true,
            synced: (d["synced"] as? NSNumber)?.boolValue ?? true,
            isTaskDefault: (d["isTaskDefault"] as? NSNumber)?.boolValue ?? false)
    }
}
