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
                    guard try OfficeTextFidelity.retainsText(of: input, in: output, runner: runner) else {
                        throw FileelError.message("The editable slide import changed PDF characters.")
                    }
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
                        guard try OfficeTextFidelity.retainsText(of: input, in: editable, runner: runner) else {
                            throw FileelError.message("The editable document import changed PDF characters.")
                        }
                        imported = true
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        // fall back to text extraction if the layout importer cannot handle this PDF
                        try? FileManager.default.removeItem(at: editable)
                    }
                    if imported {
                        if format == "pages" { try pages(editable, output: output, runner: runner) }
                        return output
                    }
                }
            }
            if format == "xlsx" {
                try PDFSpreadsheetEngine.convert(input, output: output, runner: runner)
                return output
            }
            let text = try PDFEngine.text(input, runner: runner)
            if ["txt", "md"].contains(format) {
                try text.write(to: output, atomically: true, encoding: .utf8)
                return output
            }
            let textFile = folder.appendingPathComponent("pdf-text.txt")
            try text.write(to: textFile, atomically: true, encoding: .utf8)
            if format == "pages" {
                let docx = try convert(textFile, format: "docx", folder: folder, options: options, runner: runner)
                try pages(docx, output: output, runner: runner)
            } else {
                return try pandoc(textFile, output: output, runner: runner)
            }
            return output
        }
        if ["rtfd", "textclipping"].contains(sourceFormat) {
            let temporary = folder.appendingPathComponent("native-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try runner.checkCancellation()
            let normalized = try NativeDocumentInput.normalize(input, workspace: temporary, runner: runner)
            return try convert(normalized, format: format, folder: folder, options: options, runner: runner)
        }
        if ["jpg", "png"].contains(format) {
            let pdf = try convert(input, format: "pdf", folder: folder, options: options, runner: runner)
            let pages = folder.appendingPathComponent("\(stem) Pages")
            try PDFEngine.exportImages(pdf, format: format, folder: pages, options: options, runner: runner)
            return pages
        }
        if format == "pages" {
            let docx = sourceFormat == "docx" ? input : try convert(input, format: "docx", folder: folder, options: options, runner: runner)
            try pages(docx, output: output, runner: runner)
            return output
        }
        if ["pages", "rtf", "rtfd"].contains(sourceFormat), ["md", "epub", "txt", "html"].contains(format) {
            let docx = folder.appendingPathComponent("rich-text-source.docx")
            try office(input, format: "docx", output: docx, runner: runner)
            return try pandoc(docx, output: output, runner: runner)
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
            return try pandoc(input, output: output, runner: runner)
        }
        return output
    }

    @discardableResult
    static func pandoc(_ input: URL, output: URL, runner: ProcessRunner) throws -> URL {
        let reflow = output.deletingLastPathComponent().appendingPathComponent("reflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: reflow) }
        let readable = try DocxTextBoxes.normalized(input, workspace: reflow, runner: runner)
        let package = output.pathExtension == "md" ? output.deletingPathExtension() : nil
        var createdPackage = false
        var retainPackage = false
        defer { if let package, createdPackage, !retainPackage { try? FileManager.default.removeItem(at: package) } }
        var destination = output
        if let package {
            guard !FileManager.default.fileExists(atPath: package.path) else { throw FileelError.message("The Markdown export folder already exists.") }
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            createdPackage = true
            destination = package.appendingPathComponent(output.lastPathComponent)
        }
        var args = [readable.path, "--standalone", "--output", destination.path]
        let ext = input.pathExtension.lowercased()
        if ext == "txt" { args += ["--from", "markdown"] }
        if output.pathExtension == "txt" { args += ["--to", "plain"] }
        if output.pathExtension == "md" {
            // image sizing attributes force raw HTML, which word readers cannot import back as pictures
            try FileManager.default.createDirectory(at: reflow, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let filter = reflow.appendingPathComponent("markdown-images.lua")
            let script = """
            function Image(image)
              image.attr = pandoc.Attr()
              return image
            end

            function Figure(figure)
              -- keep captions visible without an HTML figure wrapper
              local blocks = figure.content
              if figure.caption and figure.caption.long then
                blocks:extend(figure.caption.long)
              end
              return blocks
            end
            """
            try script.write(to: filter, atomically: true, encoding: .utf8)
            args += ["--to", "gfm", "--extract-media=assets", "--lua-filter", filter.path]
        }
        if output.pathExtension == "html" { args += ["--embed-resources"] }
        // look up linked resources beside the original document
        args += ["--resource-path", input.deletingLastPathComponent().path]
        try runner.run(Engines.require("pandoc"), args, directory: package)
        try runner.checkCancellation()
        if let package {
            // publish the whole folder when images exist so every relative link survives the transaction cleanup
            let assets = package.appendingPathComponent("assets")
            let items = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey])
            var hasMedia = false
            while let item = items?.nextObject() as? URL {
                if try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { hasMedia = true; break }
            }
            if hasMedia { retainPackage = true; return package }
            try FileManager.default.moveItem(at: destination, to: output)
        }
        return output
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

    static func pages(_ input: URL, output: URL, runner: ProcessRunner) throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages") != nil else {
            throw FileelError.message("Apple Pages must be installed to create a PAGES document.")
        }
        // the child process inherits fileel's automation consent and participates in job cancellation
        try PagesExporter.export(input, output: output, runner: runner)
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
