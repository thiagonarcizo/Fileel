import AppKit
import PDFKit
import Vision

// recover visible cell spacing instead of putting every extracted line into column a
enum PDFSpreadsheetEngine {
    struct Sheet {
        let name: String
        let rows: [[String]]
    }
    private struct Word {
        let text: String
        let bounds: CGRect
    }
    private struct Cell {
        var text: String
        var bounds: CGRect
    }
    private struct Layout {
        let cells: [[Cell]]
        let cuts: [Double]
    }

    static func convert(_ input: URL, output: URL, runner: ProcessRunner) throws {
        let document = try PDFEngine.load(input)
        let sheets = try (0..<document.pageCount).map { index in
            try runner.checkCancellation()
            let page = document.page(at: index)!
            var words = nativeWords(page)
            if words.isEmpty { words = try recognizedWords(page, runner: runner) }
            return try Sheet(name: "Page \(index + 1)", rows: rows(from: words))
        }
        try write(sheets, output: output, runner: runner)
    }

    private static func nativeWords(_ page: PDFPage) -> [Word] {
        guard let source = page.string else { return [] }
        let text = source as NSString
        let tokens = try! NSRegularExpression(pattern: #"\S+"#)
        return tokens.matches(in: source, range: NSRange(location: 0, length: text.length)).compactMap { match in
            // selection ranges include pdfkit's inferred spaces while raw glyph indices do not
            guard let bounds = page.selection(for: match.range)?.bounds(for: page), !bounds.isNull, !bounds.isEmpty,
                  bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite else { return nil }
            return Word(text: text.substring(with: match.range), bounds: bounds)
        }
    }

    private static func recognizedWords(_ page: PDFPage, runner: ProcessRunner) throws -> [Word] {
        try runner.checkCancellation()
        let image = try PDFEngine.render(page, dpi: 200)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = false
        try VisionExecution.perform([request], handler: VNImageRequestHandler(cgImage: image))
        try runner.checkCancellation()
        let pageSize = try PDFEngine.displayedBounds(page).size
        let tokens = try NSRegularExpression(pattern: #"\S+"#)
        var words: [Word] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            for match in tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), let box = try? candidate.boundingBox(for: range) else { continue }
                let normalized = box.boundingBox
                let bounds = CGRect(x: normalized.minX * pageSize.width, y: normalized.minY * pageSize.height,
                                    width: normalized.width * pageSize.width, height: normalized.height * pageSize.height)
                words.append(Word(text: String(text[range]), bounds: bounds))
            }
        }
        return try fillingMissingCells(words, image: image, pageSize: pageSize, runner: runner)
    }

    private static func fillingMissingCells(_ words: [Word], image: CGImage, pageSize: CGSize, runner: ProcessRunner) throws -> [Word] {
        let grid = layout(from: words)
        guard !grid.cuts.isEmpty else { return words }
        let occupied = grid.cells.filter { $0.count > 1 }
        guard let top = occupied.first?.first?.bounds.midY, let bottom = occupied.last?.first?.bounds.midY else { return words }
        let all = words.reduce(CGRect.null) { $0.union($1.bounds) }
        let edges = [max(0, all.minX - 8)] + grid.cuts + [min(pageSize.width, all.maxX + 8)]
        let scaleX = Double(image.width) / pageSize.width, scaleY = Double(image.height) / pageSize.height
        var result = words
        for row in grid.cells {
            let bounds = row.reduce(CGRect.null) { $0.union($1.bounds) }
            guard bounds.midY <= top + bounds.height, bounds.midY >= bottom - bounds.height else { continue }
            for column in 0..<(edges.count - 1) {
                guard !row.contains(where: { cell in grid.cuts.filter { $0 < cell.bounds.minX }.count == column }) else { continue }
                try runner.checkCancellation()
                let visible = CGRect(x: edges[column], y: bounds.minY - bounds.height * 0.35,
                                     width: edges[column + 1] - edges[column], height: bounds.height * 1.7)
                let pixels = CGRect(x: visible.minX * scaleX, y: Double(image.height) - visible.maxY * scaleY,
                                    width: visible.width * scaleX, height: visible.height * scaleY).integral
                    .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard !pixels.isEmpty, let cropped = image.cropping(to: pixels) else { continue }
                // a cell-sized pass gives isolated digits enough context and pixel size for the detector
                let current = VNRecognizeTextRequest.currentRevision
                let revisions = [current] + (current != 2 && VNRecognizeTextRequest.supportedRevisions.contains(2) ? [2] : [])
                for revision in revisions {
                    let request = VNRecognizeTextRequest()
                    request.revision = revision
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    // the legacy detector recognizes isolated glyphs that newer line models can omit
                    if revision == 2 { request.recognitionLanguages = ["en-US"] }
                    try VisionExecution.perform([request], handler: VNImageRequestHandler(cgImage: cropped))
                    let observations = request.results ?? []
                    for observation in observations {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let rect = observation.boundingBox
                        let location = CGRect(x: (pixels.minX + rect.minX * pixels.width) / scaleX,
                            y: (Double(image.height) - pixels.maxY + rect.minY * pixels.height) / scaleY,
                            width: rect.width * pixels.width / scaleX, height: rect.height * pixels.height / scaleY)
                        result.append(Word(text: candidate.string, bounds: location))
                    }
                    if !observations.isEmpty { break }
                }
            }
        }
        return result
    }

    private static func layout(from words: [Word]) -> Layout {
        guard !words.isEmpty else { return Layout(cells: [], cuts: []) }
        let sorted = words.sorted { $0.bounds.midY > $1.bounds.midY }
        var lines: [[Word]] = []
        for word in sorted {
            if let last = lines.last, let first = last.first,
               abs(first.bounds.midY - word.bounds.midY) <= max(1, min(first.bounds.height, word.bounds.height) * 0.45) {
                lines[lines.count - 1].append(word)
            } else { lines.append([word]) }
        }
        let cells: [[Cell]] = lines.map { line in
            var result: [Cell] = []
            for word in line.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                if let previous = result.last,
                   word.bounds.minX - previous.bounds.maxX <= max(14, min(word.bounds.height, previous.bounds.height) * 0.85) {
                    result[result.count - 1].text += " " + word.text
                    result[result.count - 1].bounds = previous.bounds.union(word.bounds)
                } else { result.append(Cell(text: word.text, bounds: word.bounds)) }
            }
            return result
        }
        // repeated empty gutters align right-justified values with their column headers
        var events: [Double: Int] = [:]
        let tableRows = cells.filter { $0.count > 1 }
        for row in tableRows {
            for pair in zip(row, row.dropFirst()) {
                events[pair.0.bounds.maxX, default: 0] += 1
                events[pair.1.bounds.minX, default: 0] -= 1
            }
        }
        let positions = events.keys.sorted()
        let required = tableRows.count <= 1 ? 1 : max(2, Int(ceil(Double(tableRows.count) * 0.4)))
        var active = 0
        var bands: [(range: ClosedRange<Double>, votes: Int)] = []
        for index in positions.indices.dropLast() {
            let x = positions[index], next = positions[index + 1]
            active += events[x] ?? 0
            if next > x {
                if let last = bands.last, last.votes == active { bands[bands.count - 1] = (last.range.lowerBound...next, active) }
                else { bands.append((x...next, active)) }
            }
        }
        let gutters = bands.indices.compactMap { index -> ClosedRange<Double>? in
            let band = bands[index]
            let left = index > 0 ? bands[index - 1].votes : 0
            let right = index + 1 < bands.count ? bands[index + 1].votes : 0
            return band.votes >= required && band.votes > left && band.votes > right ? band.range : nil
        }
        let cuts = gutters.map { ($0.lowerBound + $0.upperBound) / 2 }
        return Layout(cells: cells, cuts: cuts)
    }

    private static func rows(from words: [Word]) throws -> [[String]] {
        let grid = layout(from: words)
        let cuts = grid.cuts, cells = grid.cells
        guard cuts.count < 16_384, cells.count <= 1_048_576 else {
            throw FileelError.message("This PDF exceeds the row or column limits of an Excel worksheet.")
        }
        return cells.map { row in
            var values = Array(repeating: "", count: cuts.count + 1)
            for cell in row {
                let column = cuts.filter { $0 < cell.bounds.minX }.count
                values[column] += (values[column].isEmpty ? "" : " ") + cell.text
            }
            return values
        }
    }

    private static func write(_ sheets: [Sheet], output: URL, runner: ProcessRunner) throws {
        let root = output.deletingLastPathComponent().appendingPathComponent("xlsx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var overrides = "", entries = "", relationships = ""
        for (index, sheet) in sheets.enumerated() {
            try runner.checkCancellation()
            let number = index + 1
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            entries += "<sheet name=\"\(OfficePackage.escape(sheet.name))\" sheetId=\"\(number)\" r:id=\"rId\(number)\"/>"
            relationships += "<Relationship Id=\"rId\(number)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(number).xml\"/>"
            let data = sheet.rows.enumerated().map { row, values in
                let cells = values.enumerated().filter { !$0.element.isEmpty }.map { column, text in
                    let reference = columnName(column) + String(row + 1)
                    if let numeric = numberValue(text) {
                        let style = numeric.contains(".") ? " s=\"1\"" : ""
                        return "<c r=\"\(reference)\"\(style)><v>\(numeric)</v></c>"
                    }
                    // inline strings preserve identifiers and never turn document text into executable formulas
                    return "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(OfficePackage.escape(text))</t></is></c>"
                }.joined()
                return "<row r=\"\(row + 1)\">\(cells)</row>"
            }.joined()
            let columns = (0..<(sheet.rows.map(\.count).max() ?? 0)).map { column in
                let longest = sheet.rows.compactMap { $0.indices.contains(column) ? $0[column].count : nil }.max() ?? 0
                return "<col min=\"\(column + 1)\" max=\"\(column + 1)\" width=\"\(min(72, max(10, longest + 2)))\" customWidth=\"1\"/>"
            }.joined()
            try OfficePackage.xml("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><cols>\(columns)</cols><sheetData>\(data)</sheetData></worksheet>", at: "xl/worksheets/sheet\(number).xml", root: root)
        }
        try OfficePackage.xml("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\(overrides)</Types>", at: "[Content_Types].xml", root: root)
        try OfficePackage.xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>", at: "_rels/.rels", root: root)
        try OfficePackage.xml("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(entries)</sheets></workbook>", at: "xl/workbook.xml", root: root)
        try OfficePackage.xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)<Relationship Id=\"styles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>", at: "xl/_rels/workbook.xml.rels", root: root)
        try OfficePackage.xml("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Arial\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border/></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"2\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs></styleSheet>", at: "xl/styles.xml", root: root)
        try OfficePackage.pack(root, output: output, runner: runner)
    }

    private static func columnName(_ index: Int) -> String {
        var value = index + 1, result = ""
        while value > 0 {
            value -= 1
            result = String(UnicodeScalar(65 + value % 26)!) + result
            value /= 26
        }
        return result
    }

    private static func numberValue(_ text: String) -> String? {
        guard text.range(of: #"^-?(?:0|[1-9][0-9]*)(?:[.,][0-9]{1,2})?$"#, options: .regularExpression) != nil,
              text.filter(\.isNumber).count <= 15 else { return nil }
        return text.replacingOccurrences(of: ",", with: ".")
    }
}
