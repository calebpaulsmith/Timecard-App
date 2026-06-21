import SwiftUI

/// Placeholder shell. Real feature views land in Phase 3. For now this also
/// serves as a smoke screen proving the pure Domain layer links and runs.
struct RootView: View {
    var body: some View {
        TabView {
            PeriodPlaceholderView()
                .tabItem { Label(AppRoute.period.title, systemImage: AppRoute.period.systemImage) }

            ComingSoonView(title: "Metrics")
                .tabItem { Label(AppRoute.metrics.title, systemImage: AppRoute.metrics.systemImage) }

            ComingSoonView(title: "Settings")
                .tabItem { Label(AppRoute.settings.title, systemImage: AppRoute.settings.systemImage) }
        }
    }
}

/// Proves the Domain layer is wired: shows the current pay-period name + window
/// computed by the ported logic. Replaced by the real carousel in Phase 3.
private struct PeriodPlaceholderView: View {
    // Matches the PWA's default anchor (a Sunday).
    private let anchor = "2026-05-03"

    var body: some View {
        let period = payPeriodFor(today: Date(), anchor: anchor)
        VStack(spacing: 12) {
            Text("Timecard").font(.largeTitle.bold())
            Text(payPeriodName(period, anchor: anchor))
                .font(.title3.monospaced())
            Text("\(formatDateShort(period.days.first ?? "")) → \(formatDateShort(period.days.last ?? ""))")
                .foregroundStyle(.secondary)
            Label("Domain layer is live", systemImage: "checkmark.seal")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding()
    }
}

private struct ComingSoonView: View {
    let title: String
    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text("Coming in a later phase."))
    }
}

#Preview {
    RootView()
}
