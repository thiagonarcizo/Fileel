import AppKit

// compile with IconArtwork.swift so every exported size uses the app's own geometry
@main
enum RenderIcon {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var entries: [[String: String]] = []
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let image = FileelIcon.image(size: points * scale)
                let bitmap = image.representations[0] as! NSBitmapImageRep
                let filename = "icon-\(points)@\(scale)x.png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(filename))
                entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
            }
        }
        let json = try JSONSerialization.data(withJSONObject: ["images": entries, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: root.appendingPathComponent("Contents.json"))
        // optionally export a review image without adding loose files to the asset catalog
        if CommandLine.arguments.count > 2 {
            let previewRoot = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)
            let preview = FileelIcon.image(size: 512, accent: .controlAccentColor)
            let bitmap = preview.representations[0] as! NSBitmapImageRep
            try bitmap.representation(using: .png, properties: [:])!.write(to: previewRoot.appendingPathComponent("icon-accent-preview.png"))
        }
    }
}
