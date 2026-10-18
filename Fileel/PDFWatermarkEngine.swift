import CoreText
import Foundation
import PDFKit

// preview and export share the same vector drawing rather than approximating the watermark in UI
enum PDFWatermarkEngine {
    static func data(document: PDFDocument, pages: [Int], options: OperationOptions, checkCancellation: (() throws -> Void)? = nil) throws -> Data {
        guard !options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FileelError.message("Enter watermark text.") }
        guard options.watermarkFontSize.isFinite, options.watermarkAngle.isFinite, options.watermarkOpacity.isFinite else {
            throw FileelError.message("Choose valid watermark settings.")
        }
        let output = NSMutableData()
        var metadata: [CFString: Any] = [:]
        if options.preserveMetadata, !options.stripMetadata, let attributes = document.documentAttributes {
            for (source, destination) in [(PDFDocumentAttribute.titleAttribute, kCGPDFContextTitle),
                                         (.authorAttribute, kCGPDFContextAuthor), (.subjectAttribute, kCGPDFContextSubject),
                                         (.creatorAttribute, kCGPDFContextCreator), (.keywordsAttribute, kCGPDFContextKeywords)] {
                if let value = attributes[source] { metadata[destination] = value }
            }
        }
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: nil, metadata as CFDictionary) else {
            throw FileelError.message("The watermarked PDF could not be created.")
        }
        for index in pages {
            try Task.checkCancellation()
            try checkCancellation?()
            guard let page = document.page(at: index) else { throw FileelError.message("A PDF page is unavailable.") }
            guard let reference = page.pageRef else { throw FileelError.message("A PDF page could not be rendered.") }
            let originalBox = reference.getBoxRect(.mediaBox)
            var box = CGRect(origin: .zero, size: originalBox.size)
            // use core graphics explicitly since pdfkit's drawing rotation differs between macos releases
            let rotation = ((page.rotation % 360) + 360) % 360
            if rotation == 90 || rotation == 270 { box.size = CGSize(width: box.height, height: box.width) }
            let mediaBox = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: mediaBox] as CFDictionary)
            context.saveGState()
            context.concatenate(reference.getDrawingTransform(.mediaBox, rect: box,
                                                               rotate: Int32(page.rotation) - reference.rotationAngle,
                                                               preserveAspectRatio: true))
            context.drawPDFPage(reference)
            for annotation in page.annotations where annotation.shouldPrint {
                annotation.draw(with: .mediaBox, in: context)
            }
            context.restoreGState()
            draw(in: context, bounds: box, options: options)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    static func draw(in context: CGContext, bounds: CGRect, options: OperationOptions) {
        let font = CTFontCreateWithName("Helvetica" as CFString, max(8, min(200, options.watermarkFontSize)), nil)
        let text = NSAttributedString(string: options.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ImageEngine.color(options.watermarkHex)
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.saveGState()
        context.clip(to: bounds)
        context.setAlpha(min(1, max(0, options.watermarkOpacity)))
        let y = options.watermarkPosition == "top" ? bounds.maxY - bounds.height * 0.12 :
            options.watermarkPosition == "bottom" ? bounds.minY + bounds.height * 0.12 : bounds.midY
        context.translateBy(x: bounds.midX, y: y)
        context.rotate(by: min(90, max(-90, options.watermarkAngle)) * .pi / 180)
        let scale = min(1, bounds.width * 0.86 / max(1, width))
        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -width / 2, y: -(ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
