import AppKit

// normalize native mac text packages before passing them to command-line document engines
enum NativeDocumentInput {
    static func normalize(_ input: URL, workspace: URL, runner: ProcessRunner) throws -> URL {
        try runner.checkCancellation()
        let ext = input.pathExtension.lowercased()
        var attributes: NSDictionary?
        let content: NSAttributedString
        if ext == "rtfd" {
            content = try NSAttributedString(url: input, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: &attributes)
        } else {
            content = try clipping(input)
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = workspace.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".rtf")
        var settings: [NSAttributedString.DocumentAttributeKey: Any] = [:]
        for (key, value) in attributes ?? [:] {
            if let name = key as? String { settings[.init(rawValue: name)] = value }
        }
        settings[.documentType] = NSAttributedString.DocumentType.rtf
        let editable = NSMutableAttributedString(attributedString: content)
        var pictures: [(String, String)] = []
        var failure: Error?
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length), options: .reverse) { value, range, stop in
            guard let attachment = value as? NSTextAttachment else { return }
            do {
                try runner.checkCancellation()
                guard let imageData = attachment.fileWrapper?.regularFileContents,
                      let bitmap = NSBitmapImageRep(data: imageData),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw FileelError.message("This document contains an attachment that cannot be converted without losing it.")
                }
                let token = "fileelimage" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let size = attachment.bounds.size != .zero ? attachment.bounds.size : attachment.attachmentCell?.cellSize() ?? bitmap.size
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      size.width < 1_000_000, size.height < 1_000_000 else {
                    throw FileelError.message("An attachment has invalid display dimensions.")
                }
                let width = max(1, Int((size.width * 20).rounded()))
                let height = max(1, Int((size.height * 20).rounded()))
                let hex = try hexadecimal(png, runner: runner)
                pictures.append((token, "{\\pict\\pngblip\\picw\(bitmap.pixelsWide)\\pich\(bitmap.pixelsHigh)\\picwgoal\(width)\\pichgoal\(height)\n\(hex)\n}"))
                // the same attachment can appear more than once in one attributed run
                let text = content.string as NSString
                for index in (range.location..<NSMaxRange(range)).reversed() where text.character(at: index) == 0xfffc {
                    editable.replaceCharacters(in: NSRange(location: index, length: 1), with: token)
                    editable.removeAttribute(.attachment, range: NSRange(location: index, length: token.utf16.count))
                }
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        // the native DOCX and plain RTF writers omit attachments, so embed PNG pict groups in the rich text stream
        var data = try editable.data(from: NSRange(location: 0, length: editable.length), documentAttributes: settings)
        for (token, picture) in pictures {
            try runner.checkCancellation()
            let placeholder = Data(token.utf8)
            guard data.range(of: placeholder) != nil else { throw FileelError.message("An image could not be embedded in the converted document.") }
            while let range = data.range(of: placeholder) { data.replaceSubrange(range, with: Data(picture.utf8)) }
        }
        try data.write(to: output, options: .atomic)
        return output
    }

    // finder clippings store their representations in the file, not in a pasteboard named after its path
    static func clipping(_ input: URL) throws -> NSAttributedString {
        let data = try Data(contentsOf: input)
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let types = plist["UTI-Data"] as? [String: Any] {
            if let value = types["public.rtf"], let bytes = bytes(value), let rich = NSAttributedString(rtf: bytes, documentAttributes: nil) { return rich }
            for (name, encoding) in [("public.utf8-plain-text", String.Encoding.utf8),
                ("public.utf16-external-plain-text", .utf16), ("public.utf16-plain-text", .utf16BigEndian),
                ("com.apple.traditional-mac-plain-text", .macOSRoman)] {
                if let value = types[name] {
                    if let text = value as? String { return NSAttributedString(string: text) }
                    if let bytes = value as? Data, let text = String(data: bytes, encoding: encoding) { return NSAttributedString(string: text) }
                }
            }
        }
        let forkURL = URL(fileURLWithPath: input.path + "/..namedfork/rsrc")
        if let fork = try? Data(contentsOf: forkURL), let content = try legacyClipping(fork) { return content }
        if let content = try legacyClipping(data) { return content }
        throw FileelError.message("This Finder clipping does not contain readable text.")
    }

    // read only text resources from the classic resource map, with bounds checked before every access
    private static func legacyClipping(_ data: Data) throws -> NSAttributedString? {
        guard data.count >= 16 else { return nil }
        func integer(_ offset: Int, _ width: Int) -> Int? {
            guard offset >= 0, offset <= data.count, width <= data.count - offset else { return nil }
            return data[offset..<offset + width].reduce(0) { ($0 << 8) | Int($1) }
        }
        guard let dataStart = integer(0, 4), let mapStart = integer(4, 4),
              let dataSize = integer(8, 4), let mapSize = integer(12, 4), mapSize >= 28,
              dataStart <= data.count, dataSize <= data.count - dataStart,
              mapStart <= data.count, mapSize <= data.count - mapStart,
              let relativeTypes = integer(mapStart + 24, 2), relativeTypes >= 28, relativeTypes <= mapSize - 2 else { return nil }
        let types = mapStart + relativeTypes
        guard let declaredTypes = integer(types, 2) else { return nil }
        if declaredTypes == 0xffff { return nil }
        let count = declaredTypes + 1
        guard count <= (mapStart + mapSize - types - 2) / 8 else { return nil }
        var representations: [String: Data] = [:]
        for index in 0..<count {
            let entry = types + 2 + index * 8
            let name = String(decoding: data[entry..<entry + 4], as: UTF8.self)
            guard ["RTF ", "utf8", "ut16", "utxt", "TEXT"].contains(name), representations[name] == nil,
                  let declaredResources = integer(entry + 4, 2), declaredResources != 0xffff,
                  let relativeReferences = integer(entry + 6, 2) else { continue }
            let references = types + relativeReferences
            let resources = declaredResources + 1
            guard references >= types + 2 + count * 8, references <= mapStart + mapSize,
                  resources <= (mapStart + mapSize - references) / 12 else { return nil }
            var reference = references
            for candidate in 0..<resources where integer(references + candidate * 12, 2) == 256 {
                reference = references + candidate * 12
                break
            }
            guard let offset = integer(reference + 5, 3), offset <= dataSize - 4,
                  let length = integer(dataStart + offset, 4), length <= dataSize - offset - 4 else { return nil }
            representations[name] = data.subdata(in: dataStart + offset + 4..<dataStart + offset + 4 + length)
        }
        if let rtf = representations["RTF "], let rich = NSAttributedString(rtf: rtf, documentAttributes: nil) { return rich }
        for (name, encoding) in [("utf8", String.Encoding.utf8), ("ut16", .utf16), ("utxt", .utf16BigEndian), ("TEXT", .macOSRoman)] {
            if let bytes = representations[name], let text = String(data: bytes, encoding: encoding) { return NSAttributedString(string: text) }
        }
        return nil
    }

    private static func bytes(_ value: Any) -> Data? {
        if let data = value as? Data { return data }
        return (value as? String)?.data(using: .utf8)
    }

    // avoid allocating one formatted string per image byte when embedding large pictures
    private static func hexadecimal(_ data: Data, runner: ProcessRunner) throws -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded = [UInt8](repeating: 0, count: data.count * 2)
        for (index, byte) in data.enumerated() {
            if index % 65_536 == 0 { try runner.checkCancellation() }
            encoded[index * 2] = digits[Int(byte >> 4)]
            encoded[index * 2 + 1] = digits[Int(byte & 15)]
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
