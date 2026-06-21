import Foundation

/// JSON fragment encode/decode for setting values, matching the PWA's
/// `JSON.stringify` / `JSON.parse` so backups round-trip byte-compatibly. Values
/// may be scalars (string/number/bool) or objects, hence `.fragmentsAllowed`;
/// `.sortedKeys` keeps object output deterministic.
enum JSONValue {
    static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.fragmentsAllowed, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func decode(_ string: String) -> Any? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

/// Encode/decode the 14-slot default schedule to/from the PWA's JSON array shape:
/// each element is `null` or `{ enabled, startMin, endMin, leaveHours }`.
enum ScheduleCodec {
    static func toJSONArray(_ schedule: [ScheduleSlot?]) -> [Any] {
        schedule.map { slot -> Any in
            guard let s = slot else { return NSNull() }
            var d: [String: Any] = ["enabled": s.enabled, "leaveHours": s.leaveHours]
            d["startMin"] = s.startMin.map { $0 as Any } ?? NSNull()
            d["endMin"] = s.endMin.map { $0 as Any } ?? NSNull()
            return d
        }
    }

    static func fromJSONArray(_ arr: [Any]) -> [ScheduleSlot?] {
        var out: [ScheduleSlot?] = arr.map { el in
            guard let d = el as? [String: Any] else { return nil }
            let enabled = (d["enabled"] as? NSNumber)?.boolValue ?? true
            let startMin = (d["startMin"] as? NSNumber)?.intValue
            let endMin = (d["endMin"] as? NSNumber)?.intValue
            let leave = (d["leaveHours"] as? NSNumber)?.intValue ?? 0
            return ScheduleSlot(enabled: enabled, startMin: startMin, endMin: endMin, leaveHours: leave)
        }
        let n = TimeConstants.payPeriodDays
        if out.count < n { out += Array(repeating: nil, count: n - out.count) }
        else if out.count > n { out = Array(out.prefix(n)) }
        return out
    }
}
