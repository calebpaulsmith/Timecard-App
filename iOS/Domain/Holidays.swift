import Foundation

struct Holiday: Equatable {
    var date: String   // "YYYY-MM-DD"
    var name: String
}

/// nth (1-based) `weekday0` (0=Sun..6=Sat) of `month` (1-based) in `year`.
func nthWeekdayOfMonth(_ year: Int, month: Int, weekday0: Int, n: Int,
                       calendar: Calendar = DomainCalendar.shared) -> Date {
    let first = dateFrom(year: year, month: month, day: 1, calendar: calendar)
    let firstDow0 = dow0(first, calendar: calendar)
    let shift = (weekday0 - firstDow0 + 7) % 7
    let day = 1 + shift + (n - 1) * 7
    return dateFrom(year: year, month: month, day: day, calendar: calendar)
}

/// Last `weekday0` of `month` (1-based) in `year`.
func lastWeekdayOfMonth(_ year: Int, month: Int, weekday0: Int,
                        calendar: Calendar = DomainCalendar.shared) -> Date {
    let firstOfMonth = dateFrom(year: year, month: month, day: 1, calendar: calendar)
    let lastDom = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 28
    let lastDate = dateFrom(year: year, month: month, day: lastDom, calendar: calendar)
    let lastDow0 = dow0(lastDate, calendar: calendar)
    let shift = (lastDow0 - weekday0 + 7) % 7
    return dateFrom(year: year, month: month, day: lastDom - shift, calendar: calendar)
}

/// Observed date for a fixed-date holiday (Sat → Fri, Sun → Mon).
func observedDate(year: Int, month: Int, day: Int,
                  calendar: Calendar = DomainCalendar.shared) -> Date {
    let d = dateFrom(year: year, month: month, day: day, calendar: calendar)
    let dw = dow0(d, calendar: calendar)
    if dw == 6 { return addDays(d, -1, calendar: calendar) }   // Saturday → Friday
    if dw == 0 { return addDays(d, 1, calendar: calendar) }    // Sunday → Monday
    return d
}

/// The 11 U.S. federal holidays for `year` (OPM rules), sorted ascending.
/// Fixed-date holidays shift to the nearest weekday when on a weekend and get
/// " (observed)" appended; floating Monday/Thursday holidays never shift.
func federalHolidays(_ year: Int, calendar: Calendar = DomainCalendar.shared) -> [Holiday] {
    var list: [Holiday] = []

    // (month 1-based, day, name)
    let fixed: [(Int, Int, String)] = [
        (1, 1, "New Year's Day"),
        (6, 19, "Juneteenth National Independence Day"),
        (7, 4, "Independence Day"),
        (11, 11, "Veterans Day"),
        (12, 25, "Christmas Day"),
    ]
    for (m, day, name) in fixed {
        let actual = dateFrom(year: year, month: m, day: day, calendar: calendar)
        let obs = observedDate(year: year, month: m, day: day, calendar: calendar)
        let shifted = obs != actual
        list.append(Holiday(date: formatLocalDate(obs, calendar: calendar),
                            name: name + (shifted ? " (observed)" : "")))
    }

    let floating: [(Date, String)] = [
        (nthWeekdayOfMonth(year, month: 1, weekday0: 1, n: 3, calendar: calendar), "Birthday of Martin Luther King, Jr."),
        (nthWeekdayOfMonth(year, month: 2, weekday0: 1, n: 3, calendar: calendar), "Washington's Birthday"),
        (lastWeekdayOfMonth(year, month: 5, weekday0: 1, calendar: calendar), "Memorial Day"),
        (nthWeekdayOfMonth(year, month: 9, weekday0: 1, n: 1, calendar: calendar), "Labor Day"),
        (nthWeekdayOfMonth(year, month: 10, weekday0: 1, n: 2, calendar: calendar), "Columbus Day"),
        (nthWeekdayOfMonth(year, month: 11, weekday0: 4, n: 4, calendar: calendar), "Thanksgiving Day"),
    ]
    for (d, name) in floating {
        list.append(Holiday(date: formatLocalDate(d, calendar: calendar), name: name))
    }

    list.sort { $0.date < $1.date }
    return list
}

/// The federal-holiday name for a date (from the computed calendar), or nil.
/// Mirrors the PWA's `federalHolidayNameFor`.
func federalHolidayName(_ date: String, calendar: Calendar = DomainCalendar.shared) -> String? {
    let year = calendar.component(.year, from: parseLocalDate(date, calendar: calendar))
    return federalHolidays(year, calendar: calendar).first { $0.date == date }?.name
}
