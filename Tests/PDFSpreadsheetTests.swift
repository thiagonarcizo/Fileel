import AppKit
import PDFKit
import XCTest
@testable import FileelCore

// inspect real worksheet cells and open the exported workbook in the bundled office engine
final class PDFSpreadsheetTests: XCTestCase {
    private var folder: URL!
    private var source: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-pdf-table-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        source = folder.appendingPathComponent("inventory.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &bounds, nil))
        for number in 1...2 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let font: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular), .foregroundColor: NSColor.black]
            func text(_ value: String, x: Double, y: Double) { (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: font) }
            text("Inventory \(number)", x: 60, y: 730)
            text("Item", x: 60, y: 680); text("Qty", x: 320, y: 680); text("Price", x: 450, y: 680)
            text("Aged Copper", x: 60, y: 640); text("2", x: 340, y: 640); text("12.50", x: 450, y: 640)
            text("Velvet Ink", x: 60, y: 600); text("3", x: 340, y: 600); text("9.99", x: 450, y: 600)
            text("007", x: 60, y: 560); text("1", x: 340, y: 560); text("2,50", x: 450, y: 560)
            text("=1+1", x: 60, y: 520); text("1", x: 340, y: 520); text("1.00", x: 450, y: 520)
            text("Empty Slot", x: 60, y: 480); text("5.00", x: 450, y: 480)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func worksheet(_ workbook: URL, page: Int = 1) throws -> XMLDocument {
        let data = folder.appendingPathComponent("sheet-\(page).xml")
        try ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", workbook.path, "xl/worksheets/sheet\(page).xml"], output: data)
        return try XMLDocument(contentsOf: data, options: .nodeLoadExternalEntitiesNever)
    }

    private func value(_ address: String, in sheet: XMLDocument) throws -> String? {
        try sheet.nodes(forXPath: "//*[local-name()='c'][@r='\(address)']").first?.stringValue
    }

    func testSelectableTableBecomesColumnsAndNumbersAcrossSeparatePageSheets() throws {
        let original = try Data(contentsOf: source)
        let output = folder.appendingPathComponent("inventory.xlsx")
        try PDFSpreadsheetEngine.convert(source, output: output, runner: ProcessRunner())
        let sheet = try worksheet(output)
        XCTAssertEqual(try value("A2", in: sheet), "Item")
        XCTAssertEqual(try value("B2", in: sheet), "Qty")
        XCTAssertEqual(try value("C2", in: sheet), "Price")
        XCTAssertEqual(try value("A3", in: sheet), "Aged Copper")
        XCTAssertEqual(try value("B3", in: sheet), "2")
        XCTAssertEqual(try value("C3", in: sheet), "12.50")
        XCTAssertEqual(try value("B4", in: sheet), "3")
        XCTAssertEqual(try value("B5", in: sheet), "1")
        XCTAssertEqual(try value("B6", in: sheet), "1")
        XCTAssertNil(try value("B7", in: sheet))
        XCTAssertEqual(try value("C7", in: sheet), "5.00")
        XCTAssertEqual(try value("A5", in: sheet), "007")
        XCTAssertEqual(try sheet.nodes(forXPath: "//*[local-name()='c'][@r='A5']/@t").first?.stringValue, "inlineStr")
        XCTAssertEqual(try value("C5", in: sheet), "2.50")
        XCTAssertEqual(try value("A6", in: sheet), "=1+1")
        XCTAssertTrue(try sheet.nodes(forXPath: "//*[local-name()='f']").isEmpty)
        XCTAssertEqual(try value("A1", in: worksheet(output, page: 2)), "Inventory 2")
        XCTAssertEqual(try Data(contentsOf: source), original)
        if Engines.locate("soffice") != nil {
            let csv = folder.appendingPathComponent("table.csv")
            try DocumentEngine.office(output, format: "csv", output: csv, runner: ProcessRunner())
            let text = try String(contentsOf: csv, encoding: .utf8)
            let row = text.components(separatedBy: .newlines).first { $0.hasPrefix("Aged Copper,") } ?? ""
            XCTAssertNotNil(row.range(of: #"^Aged Copper,2,(?:"12[.,]50?"|12[.,]50?)$"#, options: .regularExpression), text)
        }
    }

    func testScannedTableRecoversItsColumnsWithLocalOCR() throws {
        let first = try XCTUnwrap(PDFEngine.load(source).page(at: 0))
        let bitmap = try PDFEngine.render(first, dpi: 144)
        let scanned = PDFDocument()
        scanned.insert(try XCTUnwrap(PDFPage(image: NSImage(cgImage: bitmap, size: .zero))), at: 0)
        let input = folder.appendingPathComponent("scan.pdf")
        XCTAssertTrue(scanned.write(to: input))
        let output = folder.appendingPathComponent("scan.xlsx")
        try PDFSpreadsheetEngine.convert(input, output: output, runner: ProcessRunner())
        let sheet = try worksheet(output)
        XCTAssertEqual(try value("A2", in: sheet), "Item")
        XCTAssertEqual(try value("B2", in: sheet), "Qty")
        XCTAssertEqual(try value("C2", in: sheet), "Price")
        XCTAssertEqual(try value("A3", in: sheet), "Aged Copper")
        XCTAssertEqual(try value("B3", in: sheet), "2")
        XCTAssertEqual(try value("C3", in: sheet), "12.50")
        XCTAssertEqual(try value("B4", in: sheet), "3")
        XCTAssertEqual(try value("B5", in: sheet), "1")
        XCTAssertEqual(try value("B6", in: sheet), "1")
        XCTAssertNil(try value("B7", in: sheet))
        XCTAssertEqual(try value("C7", in: sheet), "5.00")
    }

    func testSelectableTableKeepsItsCellOrderAfterPageRotation() throws {
        let document = try PDFEngine.load(source)
        document.page(at: 0)?.rotation = 90
        let rotated = folder.appendingPathComponent("rotated.pdf")
        XCTAssertTrue(document.write(to: rotated))
        let output = folder.appendingPathComponent("rotated.xlsx")
        try PDFSpreadsheetEngine.convert(rotated, output: output, runner: ProcessRunner())
        let sheet = try worksheet(output)
        XCTAssertEqual(try value("A3", in: sheet), "Aged Copper")
        XCTAssertEqual(try value("B3", in: sheet), "2")
        XCTAssertEqual(try value("C3", in: sheet), "12.50")
    }
}
