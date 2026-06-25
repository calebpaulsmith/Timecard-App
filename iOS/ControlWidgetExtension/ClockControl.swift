import SwiftUI
import WidgetKit
import AppIntents

// THE CONTROL CENTER TILE (iOS 18+). A toggle that shows whether you're clocked
// in and flips it on tap. Lives in the widget extension; gated @available(iOS 18).
//
// STAGED — not in any target until wired per docs/CONTROL-WIDGET-SETUP.md.

@available(iOS 18.0, *)
struct ClockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.thegrandpipeline.timecard.ClockControl",
            provider: ClockControlValueProvider()
        ) { isClockedIn in
            ControlWidgetToggle(
                "Timecard",
                isOn: isClockedIn,
                action: SetClockIntent()
            ) { running in
                Label(running ? "Clocked In" : "Clocked Out",
                      systemImage: running ? "clock.fill" : "clock")
            }
            .tint(.orange)
        }
        .displayName("Timecard Clock")
        .description("Clock in or out without opening the app.")
    }
}
