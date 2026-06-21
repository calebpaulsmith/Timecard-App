import Foundation

/// Top-level navigation destinations. Mirrors the PWA's `body[data-view]` views.
enum AppRoute: String, CaseIterable, Identifiable {
    case period
    case metrics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .period: return "Period"
        case .metrics: return "Metrics"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .period: return "calendar"
        case .metrics: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}
