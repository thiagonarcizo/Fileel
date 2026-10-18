import AppKit
import PDFKit

// use native attributed text where possible and isolated local office profiles for conversions
enum DocumentEngine {
    static func convert(_ input: URL, format: String, folder: URL, options: OperationOptions, runner: ProcessRunner) throws -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        let output = folder.appendingPathComponent("\(stem) Converted.\(format)")
        let sourceFormat = Catalog.canonical(input.pathExtension)
        let family = FileFamily.detect(input)
        if family == .pdf {
            if ["png", "jpg"].contains(format) {
                let pages = folder.appendingPathComponent("\(stem) Pages")
                try PDFEngine.exportImages(input, format: format, folder: pages, options: options, runner: runner)
                return pages
            }
            if format == "pptx" {
                do {
                    try office(input, format: format, output: output, runner: runner, inputFilter: "impress_pdf_import")
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // keep the page-image fallback for PDFs the editable import filter cannot open
                    try? FileManager.default.removeItem(at: output)
                    try OfficePackage.slides(from: input, output: output, runner: runner)
                }
                return output
            }
            if ["docx", "pages"].contains(format) {
                let document = try PDFEngine.load(input)
                let hasTextOnEveryPage = document.pageCount > 0 && (0..<document.pageCount).allSatisfy {
                    !(document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if hasTextOnEveryPage {
                    let editable = format == "docx" ? output : folder.appendingPathComponent("pdf-layout.docx")
                    var imported = false
                    do {
                        try office(input, format: "docx", output: editable, runner: runner, inputFilter: "writer_pdf_import")
                        imported = true
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        // fall back to text extraction if the layout importer cannot handle this PDF
                        try? FileManager.default.removeItem(at: editable)
                    }
                    if imported {
                        if format == "pages" { try pages(editable, output: output) }
                        return output
                    }
                }
            }
            let text = try PDFEngine.text(input, runner: runner)
            if format == "xlsx" {
                try OfficePackage.workbook(text: text, output: output, runner: runner)
                return output
            }
            if ["txt", "md"].contains(format) {
                try text.write(to: output, atomically: true, encoding: .utf8)
                return output
            }
            let textFile = folder.appendingPathComponent("pdf-text.txt")
            try text.write(to: textFile, atomically: true, encoding: .utf8)
            if format == "pages" {
                let docx = try convert(textFile, format: "docx", folder: folder, options: options, runner: runner)
                try pages(docx, output: output)
            } else {
                try pandoc(textFile, output: output, runner: runner)
            }
            return output
        }
        if ["jpg", "png"].contains(format) {
            let pdf = try convert(input, format: "pdf", folder: folder, options: options, runner: runner)
            let pages = folder.appendingPathComponent("\(stem) Pages")
            try PDFEngine.exportImages(pdf, format: format, folder: pages, options: options, runner: runner)
            return pages
        }
        if format == "pages" {
            let docx = sourceFormat == "docx" ? input : try convert(input, format: "docx", folder: folder, options: options, runner: runner)
            try pages(docx, output: output)
            return output
        }
        if sourceFormat == "textclipping" {
            guard let pasteboard = NSPasteboard(name: .init(input.path)) as NSPasteboard?,
                  let text = pasteboard.string(forType: .string) else { throw FileelError.message("Cannot read this Finder text clipping.") }
            let txt = folder.appendingPathComponent("clipping.txt")
            try text.write(to: txt, atomically: true, encoding: .utf8)
            return try convert(txt, format: format, folder: folder, options: options, runner: runner)
        }
        if ["pages", "rtf", "rtfd"].contains(sourceFormat), ["md", "epub", "txt", "html"].contains(format) {
            let docx = folder.appendingPathComponent("rich-text-source.docx")
            try office(input, format: "docx", output: docx, runner: runner)
            try pandoc(docx, output: output, runner: runner)
            return output
        }
        if family == .spreadsheet || family == .presentation || ["pdf", "pages", "rtf", "rtfd"].contains(sourceFormat) || format == "pdf" {
            // pandoc first turns Markdown and EPUB into a document that the office engine can render
            var officeInput = input
            if ["md", "epub"].contains(sourceFormat) {
                officeInput = folder.appendingPathComponent("document.docx")
                try pandoc(input, output: officeInput, runner: runner)
            }
            try office(officeInput, format: format, output: output, runner: runner)
            return output
        }
        if sourceFormat == format {
            try FileManager.default.copyItem(at: input, to: output)
        } else {
            try pandoc(input, output: output, runner: runner)
        }
        return output
    }

    static func pandoc(_ input: URL, output: URL, runner: ProcessRunner) throws {
        let reflow = output.deletingLastPathComponent().appendingPathComponent("reflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: reflow) }
        let readable = try DocxTextBoxes.normalized(input, workspace: reflow, runner: runner)
        var args = [readable.path, "--standalone", "--output", output.path]
        let ext = input.pathExtension.lowercased()
        if ext == "txt" { args += ["--from", "markdown"] }
        if output.pathExtension == "txt" { args += ["--to", "plain"] }
        if output.pathExtension == "md" { args += ["--to", "gfm"] }
        if output.pathExtension == "html" { args += ["--embed-resources"] }
        // resource paths stay local and no conversion calls a remote service
        args += ["--resource-path", input.deletingLastPathComponent().path]
        try runner.run(Engines.require("pandoc"), args)
    }

    static func office(_ input: URL, format: String, output: URL, runner: ProcessRunner, inputFilter: String? = nil) throws {
        let temp = output.deletingLastPathComponent().appendingPathComponent("office-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let profile = temp.appendingPathComponent("profile")
        let filter = format == "tsv" ? "csv:Text - txt - csv (StarCalc):9,34,76,1" : format
        var arguments = ["-env:UserInstallation=\(profile.absoluteString)", "--headless"]
        if let inputFilter { arguments.append("--infilter=\(inputFilter)") }
        arguments += ["--convert-to", filter, "--outdir", temp.path, input.path]
        try runner.run(Engines.require("soffice"), arguments)
        let ext = format == "tsv" ? "csv" : format
        let result = temp.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "." + ext)
        guard FileManager.default.fileExists(atPath: result.path) else {
            throw FileelError.message("LibreOffice did not produce \(format.uppercased()) for this file.")
        }
        try FileManager.default.moveItem(at: result, to: output)
    }

    static func pages(_ input: URL, output: URL) throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages") != nil else {
            throw FileelError.message("Apple Pages must be installed to create a PAGES document.")
        }
        // apple events prompt for consent at runtime and target only this conversion's document
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let script = """
        tell application id "com.apple.iWork.Pages"
            set convertedDocument to open POSIX file \(quoted(input.path))
            try
                save convertedDocument in POSIX file \(quoted(output.path))
                close convertedDocument saving no
            on error errorText number errorNumber
                close convertedDocument saving no
                error errorText number errorNumber
            end try
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { throw FileelError.message("Pages could not save the document: \(error)") }
        guard FileManager.default.fileExists(atPath: output.path) else { throw FileelError.message("Pages did not produce an output document.") }
    }
}

// generate small standards-based OOXML packages without importing a proprietary implementation
enum OfficePackage {
    static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func xml(_ string: String, at path: String, root: URL) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + string).write(to: target, atomically: true, encoding: .utf8)
    }

    static func pack(_ root: URL, output: URL, runner: ProcessRunner) throws {
        try runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--norsrc", "--noextattr", root.path, output.path])
    }

    static func workbook(text: String, output: URL, runner: ProcessRunner) throws {
        let root = output.deletingLastPathComponent().appendingPathComponent("xlsx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try xml("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>", at: "[Content_Types].xml", root: root)
        try xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>", at: "_rels/.rels", root: root)
        try xml("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"PDF Text\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>", at: "xl/workbook.xml", root: root)
        try xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>", at: "xl/_rels/workbook.xml.rels", root: root)
        let rows = text.components(separatedBy: .newlines).enumerated().map { index, line in
            "<row r=\"\(index + 1)\"><c r=\"A\(index + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(line))</t></is></c></row>"
        }.joined()
        try xml("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>", at: "xl/worksheets/sheet1.xml", root: root)
        try pack(root, output: output, runner: runner)
    }

    static func slides(from input: URL, output: URL, runner: ProcessRunner) throws {
        let pdf = try PDFEngine.load(input)
        guard let first = pdf.page(at: 0) else { throw FileelError.message("This PDF has no pages.") }
        let firstBounds = try PDFEngine.displayedBounds(first)
        let longest = max(firstBounds.width, firstBounds.height)
        let slideWidth = max(1, Int(firstBounds.width / longest * 9_144_000))
        let slideHeight = max(1, Int(firstBounds.height / longest * 9_144_000))
        let root = output.deletingLastPathComponent().appendingPathComponent("pptx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var overrides = "", ids = "", relationships = ""
        for index in 1...pdf.pageCount {
            try runner.checkCancellation()
            overrides += "<Override PartName=\"/ppt/slides/slide\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            ids += "<p:sldId id=\"\(255 + index)\" r:id=\"rId\(index)\"/>"
            relationships += "<Relationship Id=\"rId\(index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(index).xml\"/>"
            let media = root.appendingPathComponent("ppt/media/page\(index).png")
            try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
            let image = try PDFEngine.render(pdf.page(at: index - 1)!, dpi: 144)
            try ImageEngine.write(image, to: media, options: .init())
            // mixed page sizes fit inside one slide canvas without stretching their content
            let fit = min(Double(slideWidth) / Double(image.width), Double(slideHeight) / Double(image.height))
            let width = Int(Double(image.width) * fit), height = Int(Double(image.height) * fit)
            let x = (slideWidth - width) / 2, y = (slideHeight - height) / 2
            try xml("<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"PDF page \(index)\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId1\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld></p:sld>", at: "ppt/slides/slide\(index).xml", root: root)
            try xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/page\(index).png\"/></Relationships>", at: "ppt/slides/_rels/slide\(index).xml.rels", root: root)
        }
        try xml("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>\(overrides)</Types>", at: "[Content_Types].xml", root: root)
        try xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>", at: "_rels/.rels", root: root)
        try xml("<p:presentation xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx=\"\(slideWidth)\" cy=\"\(slideHeight)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>", at: "ppt/presentation.xml", root: root)
        try xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>", at: "ppt/_rels/presentation.xml.rels", root: root)
        try pack(root, output: output, runner: runner)
    }
}
