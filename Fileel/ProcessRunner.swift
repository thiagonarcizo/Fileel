import Foundation

// use argument arrays only, keeping filenames and metadata out of shell syntax
final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let process = active
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }

    @discardableResult
    func run(_ executable: URL, _ arguments: [String], directory: URL? = nil, output: URL? = nil, input: Data? = nil) throws -> String {
        try checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        if executable.lastPathComponent == "soffice" {
            // python caches inside the office bundle would invalidate its signature after the first conversion
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
        }
        if executable.lastPathComponent == "gs",
           let resources = Bundle.main.resourceURL?.appendingPathComponent("Ghostscript"),
           FileManager.default.fileExists(atPath: resources.path) {
            // the bundled pdf engine must find its data after the app moves between folders
            environment["GS_LIB"] = ["Resource/Init", "Resource/Font", "lib"].map { resources.appendingPathComponent($0).path }.joined(separator: ":")
            environment["GS_ICC_PROFILES"] = resources.appendingPathComponent("iccprofiles").path
        }
        process.environment = environment
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-log-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        var outputHandle: FileHandle?
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            outputHandle = try FileHandle(forWritingTo: output)
        }
        defer {
            try? logHandle.close()
            try? outputHandle?.close()
            try? FileManager.default.removeItem(at: log)
        }
        process.standardOutput = outputHandle ?? logHandle
        process.standardError = logHandle
        let inputPipe = input == nil ? nil : Pipe()
        process.standardInput = inputPipe?.fileHandleForReading ?? FileHandle.nullDevice
        // a file-backed log avoids deadlocks when a converter fills a pipe buffer
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw error }
        active = process
        lock.unlock()
        if let input { try? inputPipe?.fileHandleForWriting.write(contentsOf: input); try? inputPipe?.fileHandleForWriting.close() }
        process.waitUntilExit()
        lock.lock()
        active = nil
        lock.unlock()
        try checkCancellation()
        let data = (try? Data(contentsOf: log)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw FileelError.message("\(executable.lastPathComponent) failed (\(process.terminationStatus))\n\(text.suffix(2200))")
        }
        return text
    }
}

// prefer shipped engines, then explicit overrides, then standard local installs
enum Engines {
    static var areBundled: Bool {
        Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Engines/manifest.json").path) } ?? false
    }

    static func isBundled(_ name: String) -> Bool {
        guard let url = locate(name) else { return false }
        return url.resolvingSymlinksInPath().path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/")
    }

    static func locate(_ name: String) -> URL? {
        let override = ProcessInfo.processInfo.environment["FILEEL_\(name.uppercased())"]
        let paths = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name).path,
            name == "soffice" ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibreOffice.app/Contents/MacOS/soffice").path : nil,
            Bundle.main.resourceURL?.appendingPathComponent("Engines/\(name)").path,
            override,
            name == "soffice" ? "/Applications/LibreOffice.app/Contents/MacOS/soffice" : nil,
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"
        ].compactMap { $0 }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func require(_ name: String) throws -> URL {
        guard let url = locate(name) else {
            throw FileelError.message("\(name) is required for this operation. Open Settings → Engines to check the local installation.")
        }
        return url
    }
}

// stage each job privately and publish only complete output without replacing an existing file
struct OutputTransaction {
    let workspace: URL
    let destination: URL

    init(inputs: [URL], options: OperationOptions) throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("fileel-\(UUID().uuidString)", isDirectory: true)
        destination = options.outputDirectory ?? inputs[0].deletingLastPathComponent()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func publish(_ outputs: [URL]) throws -> [URL] {
        var published: [URL] = []
        do {
            for output in outputs {
                let target = Self.uniqueURL(in: destination, name: output.lastPathComponent)
                // copy across volumes first, then use a same-directory rename for the commit
                let pending = destination.appendingPathComponent(".fileel-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: pending) }
                try FileManager.default.copyItem(at: output, to: pending)
                try FileManager.default.moveItem(at: pending, to: target)
                published.append(target)
            }
            return published
        } catch {
            // only roll back files created by this transaction
            for output in published { try? FileManager.default.removeItem(at: output) }
            throw error
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: workspace) }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        let original = folder.appendingPathComponent(name)
        var candidate = original
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = original.deletingPathExtension().lastPathComponent
            let ext = original.pathExtension
            candidate = folder.appendingPathComponent("\(base) \(index)" + (ext.isEmpty ? "" : ".\(ext)"))
            index += 1
        }
        return candidate
    }
}
