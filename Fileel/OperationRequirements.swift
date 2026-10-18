import Foundation

// catch incomplete controls before launching a converter or creating output files
enum OperationRequirements {
    static func issue(for operation: FileOperation?, inputs: [URL], options: OperationOptions) -> String? {
        guard let operation else { return "Choose an operation to continue." }
        guard !inputs.isEmpty else { return "Choose at least one file." }
        guard options.quality.isFinite, (0.01...1).contains(options.quality) else { return "Choose an output quality between 1% and 100%." }
        guard case .tool(let tool) = operation else { return nil }
        if tool == .compress, !options.compressionReduction.isFinite || !(0...95).contains(options.compressionReduction) {
            return "Choose a reduction from 0% to 95%."
        }
        if tool == .metadata, !options.latitude.isEmpty || !options.longitude.isEmpty {
            guard let latitude = Double(options.latitude), let longitude = Double(options.longitude),
                  latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                return "Enter latitude from −90 to 90 and longitude from −180 to 180."
            }
        }
        if tool.grouped, inputs.count < 2 { return "Choose at least two files for this operation." }
        if tool == .compareDocuments, inputs.count != 2 { return "Choose exactly two documents to compare." }
        if [.cropImage, .cropVideo, .redactVideo].contains(tool), options.width <= 0 || options.height <= 0 || options.x < 0 || options.y < 0 {
            return "Select an area in the preview or enter its dimensions."
        }
        if tool == .resize, options.width <= 0 && options.height <= 0 { return "Enter a width or height for the resized file." }
        if [.trimAudio, .trimVideo, .bleep, .redactVideo].contains(tool), !options.start.isFinite || !options.end.isFinite || options.start < 0 || options.end <= options.start {
            return "The end time must be after the start time."
        }
        if tool == .bleep, options.usesBleepRanges || !options.bleepRanges.isEmpty {
            guard !options.bleepRanges.isEmpty, options.bleepRanges.count <= BleepEngine.maximumRanges,
                  options.bleepRanges.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else {
                return "Add valid bleep ranges before saving."
            }
        }
        if tool == .splitVideo, options.splitPoints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add a cut at the playhead to split the video." }
        if tool == .annotateImage, options.annotations.isEmpty { return "Choose a drawing tool and add a mark on the preview." }
        if tool == .redactImage, !options.detectFaces && !options.detectText && options.annotations.isEmpty && (options.width <= 0 || options.height <= 0) {
            return "Draw an area to cover or enable local detection."
        }
        if tool == .background, options.backgroundStyle == "image", options.backgroundImage == nil { return "Choose an image for the background." }
        if tool == .background, !options.backgroundSpacingPercent.isFinite || !(0...30).contains(options.backgroundSpacingPercent) {
            return "Choose background spacing from 0% to 30%."
        }
        if [.protectPDF, .encryptArchive].contains(tool), options.password.isEmpty { return "Enter a password for the saved file." }
        if tool == .watermarkPDF, options.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the watermark text." }
        if tool == .organizePDF, options.pdfPages.isEmpty, options.pageOrder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Keep at least one page to save." }
        if tool == .embedSubtitles, options.subtitlePath.isEmpty { return "Choose the subtitles to add." }
        if [.speed, .speedSubtitles].contains(tool), !options.speed.isFinite || options.speed <= 0 { return "Choose a speed greater than zero." }
        return nil
    }
}
