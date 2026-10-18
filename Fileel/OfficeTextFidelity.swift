import Foundation
import PDFKit

// reject a layout import when substituted PDF glyphs would silently damage editable text
enum OfficeTextFidelity {
    static func retainsText(of pdf: URL, in office: URL, runner: ProcessRunner) throws -> Bool {
        let expected = inventory(try PDFEngine.load(pdf).string ?? "")
        guard !expected.isEmpty else { return true }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-office-text-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try ArchiveEngine.extract(office, folder: folder, runner: runner)
        let xmlFiles: [URL]
        if office.pathExtension == "docx" {
            xmlFiles = [folder.appendingPathComponent("word/document.xml")]
        } else {
            xmlFiles = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("ppt/slides"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "xml" }
        }
        var text = ""
        for url in xmlFiles {
            try runner.checkCancellation()
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 * 1024 else { return false }
            let document = try XMLDocument(contentsOf: url, options: .nodeLoadExternalEntitiesNever)
            for node in try document.nodes(forXPath: "//*[local-name()='t']") {
                var ancestor = node.parent
                var duplicate = false
                while let current = ancestor {
                    if current.localName == "Fallback", let alternate = current.parent,
                       !(try alternate.nodes(forXPath: "./*[local-name()='Choice']//*[local-name()='t']")).isEmpty {
                        duplicate = true
                        break
                    }
                    ancestor = current.parent
                }
                if !duplicate { text += node.stringValue ?? "" }
            }
        }
        // character inventories tolerate line wrapping and shape order without accepting missing letters
        return inventory(text) == expected
    }

    private static func inventory(_ text: String) -> [Unicode.Scalar: Int] {
        var result: [Unicode.Scalar: Int] = [:]
        for scalar in text.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
            where CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
            result[scalar, default: 0] += 1
        }
        return result
    }
}
