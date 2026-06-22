import Foundation

/// Top-level navigation destinations. Mirrors the PWA's `body[data-view]` views.
enum AppRoute: String, CaseIterable, Identifiable {
    case period
    case calendar
    case metrics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .period: return "Period"
        case .calendar: return "Calendar"
        case .metrics: return "Metrics"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .period: return "list.bullet.rectangle"
        case .calendar: return "calendar"
        case .metrics: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}
