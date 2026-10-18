import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// reflow floating word text for semantic exports while leaving the original positioned document intact
enum DocxTextBoxes {
    static func normalized(_ input: URL, workspace: URL, runner: ProcessRunner) throws -> URL {
        guard input.pathExtension.lowercased() == "docx" else { return input }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let xmlURL = workspace.appendingPathComponent("document.xml")
        try runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", input.path, "word/document.xml"], output: xmlURL)
        let size = try xmlURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw FileelError.message("This Word document is too large to reflow safely.") }
        let data = try Data(contentsOf: xmlURL)
        guard String(decoding: data, as: UTF8.self).contains("txbxContent") else { return input }
        let document = try XMLDocument(data: data, options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever])
        guard let body = try document.nodes(forXPath: "//*[local-name()='body']").first as? XMLElement else { return input }
        let boxes = try document.nodes(forXPath: "//*[local-name()='txbxContent']")
        guard !boxes.isEmpty else { return input }
        var offsets: [ObjectIdentifier: Int] = [:]
        for box in boxes {
            try runner.checkCancellation()
            var ancestor = box.parent
            var fallbackDuplicate = false
            while let current = ancestor {
                if current.localName == "Fallback", let alternate = current.parent {
                    let preferred = try alternate.nodes(forXPath: "./*[local-name()='Choice']//*[local-name()='txbxContent']")
                    if !preferred.isEmpty { fallbackDuplicate = true; break }
                }
                ancestor = current.parent
            }
            if fallbackDuplicate { continue }
            var anchor = box
            while let parent = anchor.parent, parent !== body { anchor = parent }
            guard anchor.parent === body, let children = body.children,
                  let index = children.firstIndex(where: { $0 === anchor }) else { continue }
            let paragraphs = (box.children ?? []).filter { ["p", "tbl"].contains($0.localName ?? "") }
                .compactMap { $0.copy() as? Foundation.XMLNode }
            let key = ObjectIdentifier(anchor)
            let offset = offsets[key] ?? 0
            body.insertChildren(paragraphs, at: index + 1 + offset)
            offsets[key] = offset + paragraphs.count
        }
        // remove both compatibility representations so readers cannot count the same textbox twice
        for box in boxes { box.detach() }
        let package = workspace.appendingPathComponent("package")
        try ArchiveEngine.extract(input, folder: package, runner: runner)
        try document.xmlData.write(to: package.appendingPathComponent("word/document.xml"))
        let normalized = workspace.appendingPathComponent("reflowed.docx")
        try OfficePackage.pack(package, output: normalized, runner: runner)
        return normalized
    }
}
