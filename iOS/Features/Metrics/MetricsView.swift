import SwiftUI
import SwiftData
import Charts

/// Metrics for the current pay period: a hero number, a stat list, YTD roll-ups,
/// and a daily-hours stacked bar chart (regular / overtime / leave) with an 8h
/// reference line in 8-hour mode.
struct MetricsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.palette) private var palette
    @State private var model: MetricsViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Metrics")
        }
        .onAppear {
            if model == nil {
                model = MetricsViewModel(store: TimecardStore(context: context))
            } else {
                model?.reload()
            }
        }
    }

    private func content(_ model: MetricsViewModel) -> some View {
        List {
            Section { hero(model) }

            Section(model.periodName.isEmpty ? "This period" : model.periodName) {
                if !model.dateRange.isEmpty {
                    Text(model.dateRange).font(.footnote).foregroundStyle(.secondary)
                }
                statRow("Worked", formatHours(model.total) + " / 80 h")
                statRow("Hours left", formatHours(model.hoursLeft) + " h")
                if model.ot > 0 { statRow("Overtime", formatHours(model.ot) + " h") }
                if model.credit > 0 { statRow("Credit hours", formatHours(model.credit) + " h") }
                if model.showsMoney && model.otDollars > 0 {
                    statRow("Overtime pay", formatMoney(model.otDollars))
                }
                statRow("Pace", paceText(model))
            }

            if model.creditEnabled {
                creditBankSection(model)
            }

            Section("\(model.ytdYear) year-to-date") {
                statRow("Hours worked", formatHours(model.ytdHours) + " h")
                if model.ytdCredit > 0 {
                    statRow("Credit hours", formatHours(model.ytdCredit) + " h")
                }
                if model.showsMoney {
                    statRow("Overtime pay", formatMoney(model.ytdOtDollars))
                }
            }

            Section("Daily hours") {
                chart(model)
                    .frame(height: 240)
                    .padding(.vertical, 4)
            }

            if model.eightHourMode {
                Section("Recent overtime") {
                    Picker("Range", selection: Binding(get: { model.metricsRange },
                                                       set: { model.setRange($0) })) {
                        ForEach(MetricsRange.allCases) { r in Text(r.label).tag(r) }
                    }
                    .pickerStyle(.segmented)
                    recentOtChart(model)
                        .frame(height: 200)
                        .padding(.vertical, 4)
                }
            } else {
                Section("Pace") {
                    paceChart(model)
                        .frame(height: 200)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func recentOtChart(_ model: MetricsViewModel) -> some View {
        if model.recentOt.isEmpty {
            Text("No data in range")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            Chart(model.recentOt) { bar in
                BarMark(x: .value("Period", bar.label), y: .value("OT", bar.ot))
                    .foregroundStyle(palette.ot)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
            .chartYAxisLabel("OT hours")
        }
    }

    private func paceChart(_ model: MetricsViewModel) -> some View {
        let maxY = max(80, model.total + 4)
        return Chart {
            ForEach(model.paceIdeal) { p in
                LineMark(x: .value("Day", p.dayIndex + 1), y: .value("Hours", p.value),
                         series: .value("Series", "Ideal"))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.paceActual) { p in
                LineMark(x: .value("Day", p.dayIndex + 1), y: .value("Hours", p.value),
                         series: .value("Series", "Actual"))
                    .foregroundStyle(palette.work)
                    .symbol(.circle)
            }
            RuleMark(y: .value("Target", TimeConstants.payPeriodTarget))
                .foregroundStyle(palette.success.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .leading) {
                    Text("80 h").font(.caption2).foregroundStyle(palette.success)
                }
        }
        .chartYScale(domain: 0...maxY)
        .chartXScale(domain: 1...TimeConstants.payPeriodDays)
        .chartYAxisLabel("cumulative hours")
    }

    @ViewBuilder
    private func creditBankSection(_ model: MetricsViewModel) -> some View {
        Section {
            statRow("Credit balance", formatHours(model.creditBalance) + " h")
            if model.creditUsedThisPeriod > 0 {
                statRow("Used this period", formatHours(model.creditUsedThisPeriod) + " h")
            }
            if model.creditOverCap {
                Label {
                    Text("\(formatHours(model.creditLost)) h over the \(formatHours(model.creditCap))-hour carryover cap will be forfeited at period end. Use credit hours down to \(formatHours(model.creditCap)) h to keep them.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.warning)
                }
                .font(.footnote)
            }
        } header: {
            Text("Credit-hour bank")
        } footer: {
            Text("Credit hours carry forward, but at most \(formatHours(model.creditCap)) h roll into the next pay period — anything above is lost.")
        }
    }

    private func hero(_ model: MetricsViewModel) -> some View {
        VStack(spacing: 4) {
            Text(model.eightHourMode ? formatHours(model.ot) : formatHours(model.hoursLeft))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(model.eightHourMode ? palette.ot : palette.work)
            Text(model.eightHourMode ? "overtime hours this period" : "hours left to 80")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func paceText(_ model: MetricsViewModel) -> String {
        let label: String
        switch model.status {
        case .ahead: label = "ahead"
        case .behind: label = "behind"
        case .onPace: label = "on pace"
        }
        return "\(formatHours(model.pacePerDay)) h/day · \(label)"
    }

    private func chart(_ model: MetricsViewModel) -> some View {
        Chart {
            ForEach(model.bars) { bar in
                BarMark(x: .value("Day", bar.label), y: .value("Hours", bar.regular))
                    .foregroundStyle(by: .value("Type", "Regular"))
                BarMark(x: .value("Day", bar.label), y: .value("Hours", bar.ot))
                    .foregroundStyle(by: .value("Type", "Overtime"))
                BarMark(x: .value("Day", bar.label), y: .value("Hours", bar.credit))
                    .foregroundStyle(by: .value("Type", "Credit"))
                BarMark(x: .value("Day", bar.label), y: .value("Hours", bar.leave))
                    .foregroundStyle(by: .value("Type", "Leave"))
            }
            if model.eightHourMode {
                RuleMark(y: .value("Scheduled", TimeConstants.dailyOTThreshold))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale(["Regular": palette.work, "Overtime": palette.ot,
                                    "Credit": palette.credit, "Leave": palette.leave])
        .chartYAxisLabel("hours")
    }
}
