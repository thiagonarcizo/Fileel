import Foundation

// parse workbook data locally and export a selected sheet without requiring a scripting bridge
enum SpreadsheetEngine {
    static func export(_ input: URL, output: URL, options: OperationOptions, runner: ProcessRunner) throws {
        var workbook = input
        if input.pathExtension.lowercased() != "xlsx" {
            workbook = output.deletingLastPathComponent().appendingPathComponent("sheet-source.xlsx")
            try DocumentEngine.office(input, format: "xlsx", output: workbook, runner: runner)
        }
        func read(_ path: String) throws -> XMLNode {
            let xml = try runner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xOf", workbook.path, path])
            return try XMLNode.parse(Data(xml.utf8))
        }
        let book = try read("xl/workbook.xml")
        let sheets = book.descendants("sheet")
        guard let selected = sheets.first(where: { options.sheetName.isEmpty || $0.attributes["name"] == options.sheetName }) else {
            throw FileelError.message("Sheet not found. Available sheets: \(sheets.compactMap { $0.attributes["name"] }.joined(separator: ", ")).")
        }
        let relationships = try read("xl/_rels/workbook.xml.rels")
        guard let relation = relationships.descendants("Relationship").first(where: { $0.attributes["Id"] == selected.attributes["r:id"] }),
              let target = relation.attributes["Target"] else { throw FileelError.message("The worksheet relationship is missing.") }
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        guard ArchiveEngine.safePath(path), path.hasPrefix("xl/") else { throw FileelError.message("The worksheet has an unsafe path.") }
        let sheet = try read(path)
        let strings = (try? read("xl/sharedStrings.xml"))?.descendants("si").map { $0.descendants("t").map(\.text).joined() } ?? []
        let rows = sheet.descendants("row").map { row -> [String] in
            var values: [String] = []
            for cell in row.children where cell.name == "c" {
                let letters = (cell.attributes["r"] ?? "A").prefix(while: { $0.isLetter })
                let column = letters.uppercased().utf8.reduce(0) { $0 * 26 + Int($1) - 64 } - 1
                guard column >= 0 && column < 16384 else { continue }
                while values.count <= column { values.append("") }
                let raw = cell.descendants("v").first?.text ?? ""
                if cell.attributes["t"] == "s", let index = Int(raw), strings.indices.contains(index) { values[column] = strings[index] }
                else if cell.attributes["t"] == "inlineStr" { values[column] = cell.descendants("t").map(\.text).joined() }
                else { values[column] = raw }
            }
            return values
        }
        let delimiter = options.delimiter == "\\t" ? "\t" : options.delimiter
        guard delimiter.count == 1, delimiter != "\"", delimiter != "\n", delimiter != "\r" else {
            throw FileelError.message("Choose a one-character delimiter, such as comma, semicolon, or tab.")
        }
        let text = rows.map { row in
            row.map { value in
                if value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: delimiter)
        }.joined(separator: "\r\n")
        let encoding: String.Encoding = options.encoding == "utf16" ? .utf16 : options.encoding == "latin1" ? .isoLatin1 : .utf8
        guard let data = text.data(using: encoding) else { throw FileelError.message("Some characters cannot be represented in this encoding. Choose UTF-8.") }
        try data.write(to: output)
    }
}

// disable external entities when reading document XML
final class XMLNode: NSObject, XMLParserDelegate {
    var name = ""
    var attributes: [String: String] = [:]
    var text = ""
    var children: [XMLNode] = []
    private var stack: [XMLNode] = []

    static func parse(_ data: Data) throws -> XMLNode {
        let root = XMLNode()
        root.stack = [root]
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = root
        guard parser.parse() else { throw FileelError.message("The workbook contains invalid XML.") }
        root.stack = []
        return root
    }

    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node = XMLNode()
        node.name = name
        node.attributes = attributes
        stack.last?.children.append(node)
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
}
