import Foundation

// keep the public feature contract independent from the UI and conversion engines
enum FileFamily: String, CaseIterable, Sendable {
    case image, audio, video, pdf, document, presentation, spreadsheet, subtitle, archive, other

    static func detect(_ url: URL) -> FileFamily {
        let ext = url.pathExtension.lowercased()
        return inputs.first { $0.value.contains(ext) }?.key ?? .other
    }

    static let inputs: [FileFamily: [String]] = [
        .image: ["jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "avif", "svg", "bmp"],
        .audio: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aif", "wma"],
        .video: ["mp4", "mov", "mkv", "webm", "gif", "avi", "wmv"],
        .pdf: ["pdf"],
        .document: ["docx", "pages", "md", "markdown", "txt", "epub", "rtf", "rtfd", "textclipping"],
        .presentation: ["ppt", "pptx"], .spreadsheet: ["xlsx", "xls", "ods", "csv", "tsv"],
        .subtitle: ["srt", "vtt"], .archive: ["zip", "tar", "gz", "tgz", "rar"]
    ]

    var outputs: [String] {
        switch self {
        case .image: return ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"]
        case .audio: return ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
        case .video: return ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"]
        case .pdf: return ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md"]
        case .document: return ["docx", "pages", "pdf", "html", "epub", "txt", "md", "jpg", "png"]
        case .presentation: return ["pdf", "jpg", "png"]
        case .spreadsheet: return ["xlsx", "ods", "csv", "tsv", "pdf"]
        case .subtitle: return ["srt", "vtt", "txt"]
        case .archive: return ["zip", "tar", "gz"]
        case .other: return []
        }
    }

    var tools: [FileTool] {
        switch self {
        case .image: return [.compress, .resize, .rotate, .metadata, .editImage, .annotateImage, .background, .cropImage, .redactImage, .removeBackground, .ocrImage, .createPDF, .collage]
        case .audio: return [.compress, .metadata, .normalize, .trimAudio, .channels, .visualizer, .bleep, .fade, .removeSilence, .joinAudio]
        case .video: return [.compress, .resize, .rotate, .metadata, .trimVideo, .cropVideo, .speed, .mute, .snapshots, .joinVideos, .redactVideo, .extractAudio, .embedSubtitles, .extractSubtitles]
        case .pdf: return [.compress, .metadata, .mergePDF, .splitPDF, .organizePDF, .protectPDF, .watermarkPDF, .ocrPDF]
        case .document: return [.wordCount, .compareDocuments, .cleanFormatting]
        case .spreadsheet: return [.exportSheet]
        case .subtitle: return [.shiftSubtitles, .speedSubtitles, .joinSubtitles]
        case .archive: return [.extract, .listArchive, .testArchive, .encryptArchive]
        default: return []
        }
    }
}

// these are independently named operations, not assets or code from the reference app
enum FileTool: String, CaseIterable, Identifiable, Sendable {
    case compress, metadata, editImage, annotateImage, background, cropImage, redactImage, createPDF, collage
    case normalize, trimAudio, channels, visualizer, bleep
    case trimVideo, splitVideo, cropVideo, speed, mute, snapshots, joinVideos, redactVideo
    case mergePDF, splitPDF, organizePDF, extract
    case resize, rotate, removeBackground, ocrImage, extractAudio, embedSubtitles, extractSubtitles
    case fade, removeSilence, joinAudio, protectPDF, watermarkPDF, ocrPDF
    case wordCount, compareDocuments, cleanFormatting, exportSheet
    case shiftSubtitles, speedSubtitles, joinSubtitles, listArchive, testArchive, encryptArchive
    static var available: [FileTool] { allCases.filter { $0 != .splitVideo } }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compress: return "Compress…"
        case .metadata: return "Edit Metadata…"
        case .editImage: return "Adjust Photo…"
        case .annotateImage: return "Annotate Photo…"
        case .background: return "Add Background…"
        case .cropImage, .cropVideo: return "Crop…"
        case .redactImage, .redactVideo: return "Redact…"
        case .createPDF: return "Create PDF"
        case .collage: return "Make Collage…"
        case .normalize: return "Normalize Volume"
        case .trimAudio, .trimVideo: return "Trim…"
        case .channels: return "Change Channels…"
        case .visualizer: return "Visualize Audio…"
        case .bleep: return "Bleep Audio…"
        case .splitVideo: return "Split Video…"
        case .speed: return "Change Speed…"
        case .mute: return "Remove Audio"
        case .snapshots: return "Save Frames…"
        case .joinVideos: return "Join Videos"
        case .mergePDF: return "Merge PDFs"
        case .splitPDF: return "Split PDF"
        case .organizePDF: return "Organize Pages…"
        case .extract: return "Extract Archive"
        case .resize: return "Resize…"
        case .rotate: return "Rotate and Flip…"
        case .removeBackground: return "Remove Background"
        case .ocrImage: return "Extract Text"
        case .extractAudio: return "Extract Audio"
        case .embedSubtitles: return "Add Subtitles…"
        case .extractSubtitles: return "Extract Subtitles"
        case .fade: return "Fade In and Out…"
        case .removeSilence: return "Remove Silence…"
        case .joinAudio: return "Join Audio"
        case .protectPDF: return "Protect PDF…"
        case .watermarkPDF: return "Add Watermark…"
        case .ocrPDF: return "Make Searchable PDF"
        case .wordCount: return "Count Words"
        case .compareDocuments: return "Compare Documents"
        case .cleanFormatting: return "Clear Formatting"
        case .exportSheet: return "Export Sheet…"
        case .shiftSubtitles: return "Shift Subtitle Timing…"
        case .speedSubtitles: return "Change Subtitle Speed…"
        case .joinSubtitles: return "Join Subtitles"
        case .listArchive: return "List Archive Contents"
        case .testArchive: return "Test Archive Integrity"
        case .encryptArchive: return "Create Encrypted ZIP…"
        }
    }
    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .metadata: return "tag"
        case .editImage: return "slider.horizontal.3"
        case .annotateImage: return "pencil.tip"
        case .background: return "photo.artframe"
        case .cropImage, .cropVideo: return "crop"
        case .redactImage, .redactVideo: return "eye.slash"
        case .createPDF: return "doc.badge.plus"
        case .collage: return "square.grid.2x2"
        case .normalize, .visualizer: return "waveform"
        case .trimAudio, .trimVideo: return "scissors"
        case .channels: return "hifispeaker.2"
        case .bleep: return "speaker.slash"
        case .splitVideo, .splitPDF: return "rectangle.split.2x1"
        case .speed: return "speedometer"
        case .mute: return "speaker.slash"
        case .snapshots: return "camera"
        case .joinVideos, .mergePDF: return "doc.on.doc"
        case .organizePDF: return "square.grid.3x3"
        case .extract: return "archivebox"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .rotate: return "rotate.right"
        case .removeBackground: return "person.crop.rectangle"
        case .ocrImage, .ocrPDF: return "text.viewfinder"
        case .extractAudio, .joinAudio: return "waveform"
        case .embedSubtitles, .extractSubtitles, .joinSubtitles: return "captions.bubble"
        case .fade, .removeSilence: return "waveform.path"
        case .protectPDF, .encryptArchive: return "lock"
        case .watermarkPDF: return "seal"
        case .wordCount: return "textformat.123"
        case .compareDocuments: return "doc.on.doc"
        case .cleanFormatting: return "textformat"
        case .exportSheet: return "tablecells"
        case .shiftSubtitles: return "clock.arrow.circlepath"
        case .speedSubtitles: return "speedometer"
        case .listArchive: return "list.bullet"
        case .testArchive: return "checkmark.shield"
        }
    }
    var grouped: Bool { [.createPDF, .collage, .mergePDF, .joinVideos, .joinAudio, .compareDocuments, .joinSubtitles].contains(self) }
    var needsOptions: Bool {
        ![.createPDF, .normalize, .mute, .joinVideos, .mergePDF, .splitPDF, .extract, .removeBackground, .ocrImage, .extractAudio, .extractSubtitles, .joinAudio, .ocrPDF, .wordCount, .compareDocuments, .cleanFormatting, .joinSubtitles, .listArchive, .testArchive].contains(self)
    }
}

enum FileAction: String, CaseIterable, Sendable {
    case airDrop, float, copy, move, copyPath, terminal
    case quickLook, reveal, rename, duplicate, checksum
    // keep the user's preferred floating-file slot stable as the action catalog grows
    static let radialOrder: [FileAction] = [.airDrop, .checksum, .copy, .move, .copyPath, .terminal, .quickLook, .reveal, .rename, .duplicate, .float]
    var title: String {
        switch self {
        case .airDrop: return "AirDrop…"
        case .float: return "Float Files"
        case .copy: return "Copy Files"
        case .move: return "Move to…"
        case .copyPath: return "Copy Path"
        case .terminal: return "Open in Terminal"
        case .quickLook: return "Quick Look"
        case .reveal: return "Show in Finder"
        case .rename: return "Rename Files…"
        case .duplicate: return "Duplicate Files"
        case .checksum: return "Calculate SHA-256"
        }
    }
    var symbol: String {
        switch self {
        case .airDrop: return "airplayaudio"
        case .float: return "pin"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyPath: return "link"
        case .terminal: return "terminal"
        case .quickLook: return "eye"
        case .reveal: return "magnifyingglass"
        case .rename: return "pencil"
        case .duplicate: return "plus.square.on.square"
        case .checksum: return "number"
        }
    }
}

enum MenuMode: String, CaseIterable, Identifiable {
    case convert = "Convert", tools = "Tools", actions = "Actions"
    var id: String { rawValue }
    var defaultKey: String { self == .convert ? "shift" : self == .tools ? "command" : "control" }
}

enum FileOperation: Hashable, Sendable {
    case convert(String), tool(FileTool), action(FileAction)
    // concise radial labels keep the complete operation name available in the hub
    var wheelTitle: String {
        switch self {
        case .convert(let format): return format.uppercased()
        case .tool(let tool):
            switch tool {
            case .metadata: return "Info"
            case .editImage: return "Adjust"
            case .removeBackground: return "Remove BG"
            case .embedSubtitles: return "Add Subs"
            case .extractSubtitles: return "Captions"
            case .extractAudio: return "Audio"
            case .mute: return "Mute"
            case .annotateImage: return "Annotate"
            case .background: return "Canvas"
            case .rotate: return "Rotate\nFlip"
            case .collage: return "Collage"
            case .normalize: return "Normalize"
            case .channels: return "Channels"
            case .visualizer: return "Waveform"
            case .bleep: return "Bleep"
            case .speed, .speedSubtitles: return "Speed"
            case .snapshots: return "Frames"
            case .organizePDF: return "Pages"
            case .wordCount: return "Word Count"
            case .compareDocuments: return "Compare"
            case .cleanFormatting: return "Clear Format"
            case .shiftSubtitles: return "Timing"
            case .listArchive: return "Contents"
            case .testArchive: return "Test Archive"
            case .encryptArchive: return "Encrypt ZIP"
            default: return tool.title.replacingOccurrences(of: "…", with: "")
            }
        case .action(let action):
            switch action {
            case .reveal: return "Finder"
            case .terminal: return "Terminal"
            case .checksum: return "SHA-256"
            case .duplicate: return "Duplicate"
            case .rename: return "Rename"
            default: return action.title.replacingOccurrences(of: "…", with: "")
            }
        }
    }
    var mode: MenuMode {
        switch self {
        case .convert: return .convert
        case .tool: return .tools
        case .action: return .actions
        }
    }
    var title: String {
        switch self {
        case .convert(let format): return "Convert to \(format.uppercased())"
        case .tool(let tool): return tool.title
        case .action(let action): return action.title
        }
    }
    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .tool(let tool): return tool.symbol
        case .action(let action): return action.symbol
        }
    }
}

// pass immutable snapshots to workers so changing settings cannot alter a running job
struct OperationOptions: Sendable, Equatable {
    // the original file is only a valid fallback when no metadata change was requested
    var changesMetadata: Bool {
        !preserveMetadata || stripMetadata || removeLocation ||
        [author, title, cameraMake, cameraModel, lensModel, latitude, longitude].contains { !$0.isEmpty }
    }

    var quality = 1.0
    var preserveMetadata = true
    var width = 0
    var height = 0
    var x = 0
    var y = 0
    var start = 0.0
    var end = 10.0
    var bleepRanges: [AudioRedactionRange] = []
    var usesBleepRanges = false
    var speed = 1.0
    var channels = 1
    var autoAdjust = false
    var brightness = 0.0
    var vibrance = 0.0
    var temperature = 6500.0
    var tint = 0.0
    var highlights = 1.0
    var shadows = 0.0
    var sharpness = 0.0
    var keepQuality = true
    var exposure = 0.0
    var saturation = 1.0
    var contrast = 1.0
    var padding = 40
    var columns = 2
    var text = ""
    var author = ""
    var title = ""
    var pageOrder = ""
    var pdfPages: [PDFPageEdit] = []
    var compressionReduction = 50.0
    var watermarkHex = "707070"
    var watermarkOpacity = 0.25
    var watermarkFontSize = 42.0
    var watermarkAngle = 35.0
    var watermarkPosition = "center"
    var rotation = 0
    var splitPoints = ""
    var backgroundHex = "FFFFFF"
    var stripMetadata = false
    var detectFaces = true
    var detectText = false
    var outputDirectory: URL?
    var flipHorizontal = false
    var password = ""
    var subtitlePath = ""
    var fadeIn = 1.0
    var fadeOut = 1.0
    var silenceThreshold = -40.0
    var offset = 0.0
    var sheetName = ""
    var delimiter = ","
    var encoding = "utf8"
    var renameTemplate = "{name}-{n}"
    var sheetOutput = "csv"
    var annotations: [ImageAnnotation] = []
    var backgroundStyle = "solid"
    var backgroundEndHex = "DCE6EF"
    var backgroundImage: URL?
    var cornerRadius = 0.0
    var cropAspect = "free"
    var cropAspectLocked = false
    var cropPortrait = false
    var cropCustomRatio = 1.0
    var cameraMake = ""
    var cameraModel = ""
    var lensModel = ""
    var latitude = ""
    var longitude = ""
    var removeLocation = false
    var redactionKind: ImageAnnotation.Kind = .cover
    var redactionHex = "16181C"
    var annotationKind: ImageAnnotation.Kind = .arrow
    var annotationHex = "EE4949"
    var annotationThickness = 0.006
    var annotationFontScale = 0.05
}

enum FileelError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// intersect the actual selections so mixed file types never offer an invalid operation
enum Catalog {
    static func operations(for urls: [URL], mode: MenuMode) -> [FileOperation] {
        guard !urls.isEmpty else { return [] }
        if mode == .actions { return FileAction.radialOrder.map(FileOperation.action) }
        if urls.contains(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false }) { return [] }
        let family = FileFamily.detect(urls[0])
        if mode == .convert {
            return family.outputs.filter { output in
                urls.allSatisfy {
                    let source = canonical($0.pathExtension)
                    // animated images have no audio stream to extract
                    return FileFamily.detect($0).outputs.contains(output) && source != output && !(source == "gif" && output == "mp3")
                }
            }.map(FileOperation.convert)
        }
        return family.tools.filter { tool in
            urls.allSatisfy { FileFamily.detect($0).tools.contains(tool) } && (!tool.grouped || urls.count > 1)
        }.map(FileOperation.tool)
    }

    static func canonical(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "aif": return "aiff"
        case "markdown": return "md"
        default: return ext.lowercased()
        }
    }
}
