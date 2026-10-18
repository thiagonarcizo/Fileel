import AppKit
import SwiftUI
import UniformTypeIdentifiers

// provide a keyboard-accessible workspace alongside the global drag gesture
struct ContentView: View {
    @ObservedObject var model = AppModel.shared
    private var section: String { model.section }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $model.section) {
                Label("Files", systemImage: "doc.on.doc").tag("Files")
                Label("Activity", systemImage: "clock").tag("Activity")
                Label("Capabilities", systemImage: "square.grid.2x2").tag("Capabilities")
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Local to your Mac").font(.caption).fontWeight(.medium)
                    Text("Drag a file, press a shortcut, then drop.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding()
            }
            .frame(width: 180)
            .background(.regularMaterial)
            Divider()
            Group {
                if section == "Activity" { activity }
                else if section == "Capabilities" { capabilities }
                else if model.files.isEmpty { WelcomeView(chooseFiles: model.chooseFiles, receiveFiles: model.setFiles) }
                else { workspace }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(section == "Files" ? "Fileel" : section)
        .toolbar {
            ToolbarItem {
                Button { model.chooseFiles() } label: { Label("Choose Files…", systemImage: "plus") }
                    .help("Choose files or folders")
            }
        }
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .onAppear {
            model.showWorkspace = { WorkspaceWindowController.shared.show() }
            if model.selection == nil { model.options = model.defaults() }
        }
        .alert("Operation Couldn’t Finish", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var workspace: some View {
        HSplitView {
            VStack(spacing: 0) {
                if model.files.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: "doc.badge.arrow.up").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Files, ready for what’s next").font(.title2).fontWeight(.semibold)
                        Text("Drop files here or choose them to get started.").foregroundStyle(.secondary)
                        Button("Choose Files…") { model.chooseFiles() }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                } else {
                    List(selection: $model.previewFile) {
                        ForEach(model.files, id: \.self) { file in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.lastPathComponent).lineLimit(1)
                                    Text(FileFamily.detect(file).rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { model.removeFile(file) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove \(file.lastPathComponent) from selection")
                            }.padding(.vertical, 4).tag(file)
                        }
                    }.frame(height: CGFloat(min(3, model.files.count) * 56 + 18))
                    Divider()
                    if let file = model.previewFile, FileFamily.detect(file) == .image {
                        ImageEditorView(url: file, operation: model.selection, options: $model.options)
                    } else if let file = model.previewFile, [.audio, .video].contains(FileFamily.detect(file)) {
                        MediaPreviewView(url: file, operation: model.selection, options: $model.options)
                    } else {
                        FilePreviewView(url: model.previewFile)
                    }
                    Divider()
                    Text("\(model.files.count) selected · Originals are kept for conversions")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                }
            }
            .frame(minWidth: 280, maxWidth: .infinity)
            .dropDestination(for: URL.self) { urls, _ in model.setFiles(urls); return true }

            VStack(alignment: .leading, spacing: 14) {
                Picker("Operation Group", selection: $model.mode) {
                    ForEach(MenuMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented).labelsHidden().onChange(of: model.mode) { _, _ in
                    model.workspaceJobID = nil
                    if let selection = model.selection, !model.operations.contains(selection) { model.selection = nil }
                }
                if model.operations.isEmpty {
                    Text(model.files.isEmpty ? "Choose files to see available operations." : "No matching operations for this selection. File actions work with any file or folder.")
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                    Spacer()
                } else {
                    Picker("Operation", selection: Binding(get: { model.selection }, set: { model.selectOperation($0) })) {
                        Text("Choose an Operation").tag(nil as FileOperation?)
                        ForEach(model.operations, id: \.self) { operation in
                            Text(operation.title).tag(operation as FileOperation?)
                        }
                    }.disabled(model.busy)
                    HStack {
                        if model.busy {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { model.cancel() }.keyboardShortcut(".", modifiers: .command)
                        } else {
                            Button(model.selection?.title.replacingOccurrences(of: "…", with: "") ?? "Run") { model.run() }
                                .buttonStyle(.borderedProminent).disabled(model.requirement != nil)
                                .keyboardShortcut(.return, modifiers: .command)
                        }
                        Spacer()
                    }
                    if let selection = model.selection {
                        if let requirement = model.requirement {
                            Text(requirement).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if case .tool(let tool) = selection, tool.needsOptions {
                            Button("Open \(selection.title.replacingOccurrences(of: "…", with: ""))…") {
                                OperationWindowController.show(files: model.files, operation: selection)
                            }
                            Spacer()
                        } else {
                            OperationOptionsView(operation: selection, family: model.previewFile.map(FileFamily.detect), options: $model.options).disabled(model.busy)
                        }
                    } else { Spacer() }
                    if let current = model.workspaceJob { JobStatusView(job: current) }
                }
            }.padding(20).frame(minWidth: 330, idealWidth: 400, maxWidth: 500)
        }
    }

    private var activity: some View {
        Group {
            if model.jobs.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "clock", description: Text("Completed and running operations appear here for this session."))
            } else {
                List(model.jobs) { job in
                    HStack(alignment: .top, spacing: 12) {
                        if job.state == .running { ProgressView().controlSize(.small) }
                        else { Image(systemName: job.state == .completed ? "checkmark.circle" : job.state == .failed ? "exclamationmark.triangle" : "xmark.circle") }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.title).fontWeight(.medium)
                            Text(job.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if !job.outputs.isEmpty {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
                        }
                    }.padding(.vertical, 8)
                }
            }
        }
    }

    private var capabilities: some View {
        List {
            Section("Conversion Formats") {
                ForEach(FileFamily.allCases.filter { $0 != .other }, id: \.self) { family in
                    LabeledContent(family.rawValue.capitalized, value: family.outputs.map { $0.uppercased() }.joined(separator: ", "))
                }
            }
            Section("File Tools") {
                ForEach(FileTool.available) { tool in Label(tool.title, systemImage: tool.symbol) }
            }
            Section("Local Engines") {
                ForEach(["ffmpeg", "ffprobe", "pandoc", "soffice"], id: \.self) { engine in
                    LabeledContent(engine, value: Engines.locate(engine) == nil ? "Installation required" : "Available")
                }
                Text("Listed formats are implementation targets. Availability depends on local engines; conversion fidelity varies by format.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// show task-specific controls in context instead of sending people to global settings
struct OperationOptionsView: View {
    let operation: FileOperation
    var family: FileFamily?
    @Binding var options: OperationOptions

    var body: some View {
        Form {
            if operation == .action(.rename) {
                TextField("Filename Template", text: $options.renameTemplate)
                Text("Use {name} for the original name and {n} for its number. The extension is kept.").font(.caption).foregroundStyle(.secondary)
            } else if case .action = operation {
                Text("This action applies to every selected file.").foregroundStyle(.secondary)
            } else {
                if showsOutputOptions {
                    Section("Output") {
                        Toggle("Preserve metadata", isOn: $options.preserveMetadata)
                    }
                }
                if case .tool(let tool) = operation { controls(tool) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private var showsOutputOptions: Bool {
        guard family == .image || family == .audio || family == .video else { return false }
        if case .convert = operation { return true }
        if case .tool(let tool) = operation {
            return ![.metadata, .ocrImage, .extractSubtitles, .createPDF].contains(tool)
        }
        return false
    }

    @ViewBuilder private func controls(_ tool: FileTool) -> some View {
        if [.cropImage, .cropVideo, .redactImage, .redactVideo, .resize, .collage, .visualizer].contains(tool) {
            Section("Dimensions in Pixels") {
                TextField("Width", value: $options.width, format: .number)
                TextField("Height", value: $options.height, format: .number)
                if [.cropImage, .cropVideo, .redactImage, .redactVideo].contains(tool) {
                    TextField("X from Left", value: $options.x, format: .number)
                    TextField("Y from Top", value: $options.y, format: .number)
                } else { Text("A zero dimension keeps the original size.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        if [.trimAudio, .trimVideo, .redactVideo, .bleep, .snapshots].contains(tool) {
            Section("Time in Seconds") {
                TextField("Start", value: $options.start, format: .number)
                if tool != .snapshots { TextField("End", value: $options.end, format: .number) }
            }
        }
        if tool == .metadata {
            Section("Metadata") {
                Toggle("Remove existing metadata", isOn: $options.stripMetadata)
                TextField("Author / Artist", text: $options.author)
                TextField("Title", text: $options.title)
                Text("Empty fields keep their existing value unless you remove existing metadata.").font(.caption).foregroundStyle(.secondary)
            }
            if family == .image || family == .video {
                Section("Camera") {
                    TextField("Make", text: $options.cameraMake)
                    TextField("Model", text: $options.cameraModel)
                    if family == .image { TextField("Lens", text: $options.lensModel) }
                }
                Section("Location") {
                    Toggle("Remove existing location", isOn: $options.removeLocation)
                    TextField("Latitude", text: $options.latitude, prompt: Text("−22.9099"))
                    TextField("Longitude", text: $options.longitude, prompt: Text("−47.0626"))
                }
            }
        }
        if tool == .editImage {
            Section("Adjustments") {
                Text("Exposure")
                ResettableSlider(title: "Exposure", value: $options.exposure, range: -3...3, defaultValue: 0)
                Text("Saturation")
                ResettableSlider(title: "Saturation", value: $options.saturation, range: 0...2, defaultValue: 1)
                Text("Contrast")
                ResettableSlider(title: "Contrast", value: $options.contrast, range: 0.5...1.5, defaultValue: 1)
            }
        }
        if tool == .annotateImage {
            Section("Annotation") {
                TextField("Text for New Marks", text: $options.text)
                Text("Choose a drawing tool above the preview, then draw on the image. Text and numbered callouts use a single click.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if [.background, .collage].contains(tool) {
            Section("Layout") {
                Picker("Background", selection: $options.backgroundStyle) {
                    Text("Solid Color").tag("solid")
                    Text("Gradient").tag("gradient")
                    if tool == .background { Text("Image").tag("image") }
                }
                if options.backgroundStyle != "image" {
                    ColorPicker("Color", selection: Binding(get: { Color(nsColor: NSColor(cgColor: ImageEngine.color(options.backgroundHex)) ?? .white) }, set: { options.backgroundHex = $0.hexRGB }), supportsOpacity: false)
                    if options.backgroundStyle == "gradient" {
                        ColorPicker("End Color", selection: Binding(get: { Color(nsColor: NSColor(cgColor: ImageEngine.color(options.backgroundEndHex)) ?? .white) }, set: { options.backgroundEndHex = $0.hexRGB }), supportsOpacity: false)
                    }
                } else {
                    Button(options.backgroundImage?.lastPathComponent ?? "Choose Background Image…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK { options.backgroundImage = panel.url }
                    }
                }
                Stepper("Spacing: \(options.padding) px", value: $options.padding, in: 0...300)
                Text("Corner Radius: \(Int(options.cornerRadius)) px")
                ResettableSlider(title: "Corner Radius", value: $options.cornerRadius, range: 0...300, defaultValue: 0)
                if tool == .collage { Stepper("Columns: \(options.columns)", value: $options.columns, in: 1...12) }
            }
        }
        if tool == .redactImage {
            Section("Local Detection") {
                Toggle("Cover detected faces", isOn: $options.detectFaces)
                Toggle("Cover detected text", isOn: $options.detectText)
                Text("Review the saved result before sharing. Detection can miss sensitive content.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if tool == .speed {
            Text("Speed: \(options.speed, specifier: "%.2f")×")
            ResettableSlider(title: "Speed", value: $options.speed, range: 0.25...4, defaultValue: 1)
        }
        if tool == .rotate {
            Picker("Rotation", selection: $options.rotation) {
                ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
            }
            Toggle("Flip horizontally", isOn: $options.flipHorizontal)
        }
        if [.protectPDF, .encryptArchive].contains(tool) {
            SecureField("Password", text: $options.password)
            Text("This password is used for this operation only.").font(.caption).foregroundStyle(.secondary)
        }
        if tool == .watermarkPDF { TextField("Watermark Text", text: $options.text) }
        if tool == .fade {
            TextField("Fade In (Seconds)", value: $options.fadeIn, format: .number)
            TextField("Fade Out (Seconds)", value: $options.fadeOut, format: .number)
        }
        if tool == .removeSilence {
            Text("Silence Threshold: \(Int(options.silenceThreshold)) dB")
            ResettableSlider(title: "Silence Threshold", value: $options.silenceThreshold, range: -60 ... -15, defaultValue: -40)
        }
        if tool == .shiftSubtitles { TextField("Offset (Seconds)", value: $options.offset, format: .number) }
        if tool == .speedSubtitles { TextField("Speed Multiplier", value: $options.speed, format: .number) }
        if tool == .embedSubtitles {
            Text(options.subtitlePath.isEmpty ? "Choose SRT or VTT subtitles" : options.subtitlePath).font(.caption).foregroundStyle(.secondary)
            Button("Choose Subtitles…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.init(filenameExtension: "srt")!, .init(filenameExtension: "vtt")!]
                if panel.runModal() == .OK { options.subtitlePath = panel.url?.path ?? "" }
            }
        }
        if tool == .exportSheet {
            TextField("Sheet Name", text: $options.sheetName, prompt: Text("First sheet"))
            Picker("Delimiter", selection: $options.delimiter) { Text("Comma").tag(","); Text("Semicolon").tag(";"); Text("Tab").tag("\\t") }
            Picker("Encoding", selection: $options.encoding) { Text("UTF-8").tag("utf8"); Text("UTF-16").tag("utf16"); Text("Latin-1").tag("latin1") }
            Text("Exports stored cell values to CSV. Formulas use their last saved result.").font(.caption).foregroundStyle(.secondary)
        }
        if tool == .channels {
            Picker("Channels", selection: $options.channels) { Text("Mono").tag(1); Text("Stereo").tag(2) }
        }
        if tool == .splitVideo { TextField("Split Times (Seconds)", text: $options.splitPoints) }
        if tool == .organizePDF {
            Section("Pages") {
                TextField("Page Order", text: $options.pageOrder, prompt: Text("1,3,2,2"))
                Picker("Rotate", selection: $options.rotation) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                Text("Repeat a number to duplicate a page. Omit it to remove a page.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// keep completion feedback close to the action that produced the files
private struct JobStatusView: View {
    let job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label(job.state == .completed ? (job.outputs.isEmpty ? "Copied to Clipboard" : "Saved Successfully") : job.state == .running ? "Processing Files" : job.state == .cancelled ? "Cancelled" : "Couldn’t Finish",
                  systemImage: job.state == .completed ? "checkmark.circle" : job.state == .failed ? "exclamationmark.triangle" : "clock")
                .font(.caption).fontWeight(.medium)
            if let output = job.outputs.first {
                Text(output.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }.controlSize(.small)
            }
        }.accessibilityElement(children: .combine)
    }
}
