import SwiftUI
import UniformTypeIdentifiers

/// A trivial text document wrapper so `.fileExporter` can write the CSV backup to
/// Files / share it. The CSV string itself is produced by `TimecardStore.exportCsv`
/// (via `SettingsViewModel.exportCsvText`); this only adapts it to `FileDocument`.
struct CsvBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText, .text] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

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
