import SwiftUI
import WidgetKit

// The extension's @main entry. Lists every widget/control it vends. When you add
// the pay-period home-screen widget later, add it here too.
//
// STAGED — not in any target until wired per docs/CONTROL-WIDGET-SETUP.md.

@main
struct TimecardWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 18.0, *) {
            ClockControl()
        }
        // Future: PayPeriodWidget(), ClockLiveActivity(), …
    }
}
