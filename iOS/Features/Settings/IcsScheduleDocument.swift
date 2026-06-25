import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Dynamic `.ics` (iCalendar) type — avoids an Info.plist UTI declaration.
    static var icsCalendar: UTType { UTType(filenameExtension: "ics", conformingTo: .text) ?? .text }
}

/// Wraps the RFC-5545 schedule `.ics` (from `buildScheduleIcs`, via
/// `SettingsViewModel.exportScheduleIcsText`) so `.fileExporter` can save/share it
/// as a `.ics` file. Export-only.
struct IcsScheduleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.icsCalendar, .text, .plainText] }
    static var writableContentTypes: [UTType] { [.icsCalendar] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
