import Foundation

// reject paths and links before extraction, then work only inside an isolated staging folder
enum ArchiveEngine {
    static func extract(_ input: URL, folder: URL, runner: ProcessRunner) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if input.pathExtension.lowercased() == "gz", !input.lastPathComponent.lowercased().hasSuffix(".tar.gz") {
            let file = folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            try runner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-dc", input.path], output: file)
            return
        }
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let names = try runner.run(tar, ["-tf", input.path])
        let entries = names.split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty, entries.allSatisfy(safePath) else {
            throw FileelError.message("The archive contains an unsafe path or is empty.")
        }
        let details = try runner.run(tar, ["-tvf", input.path])
        guard details.split(whereSeparator: \.isNewline).allSatisfy({ line in
            line.first == "-" || line.first == "d"
        }) else { throw FileelError.message("This archive contains links or special files that Fileel cannot safely extract.") }
        try runner.run(tar, ["-xf", input.path, "-C", folder.path, "--no-same-owner", "--no-same-permissions"])
        // reject unexpected links even if an archive listing omitted their type
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw FileelError.message("The archive produced a symbolic link.")
                }
            }
        }
    }

    static func safePath(_ name: String) -> Bool {
        !name.hasPrefix("/") && !name.hasPrefix("\\") && !name.contains("\0") &&
        !name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").contains("..")
    }

    static func convert(_ input: URL, format: String, output: URL, runner: ProcessRunner) throws {
        let folder = output.deletingLastPathComponent().appendingPathComponent("archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try extract(input, folder: folder, runner: runner)
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        if format == "zip" {
            try runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--norsrc", "--noextattr", folder.path, output.path])
        } else {
            let flags = format == "gz" ? "-czf" : "-cf"
            try runner.run(URL(fileURLWithPath: "/usr/bin/tar"), [flags, output.path, "-C", folder.path, "--"] + entries)
        }
    }

    static func inspect(_ input: URL, tool: FileTool, output: URL, options: OperationOptions, runner: ProcessRunner) throws {
        if tool == .encryptArchive {
            guard !options.password.isEmpty, !options.password.contains("\n"), !options.password.contains("\r") else {
                throw FileelError.message("Enter a nonempty password without line breaks.")
            }
            let folder = output.deletingLastPathComponent().appendingPathComponent("encrypt-source")
            try extract(input, folder: folder, runner: runner)
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            // send the password to the prompt through stdin instead of exposing it in process arguments
            let password = Data((options.password + "\n" + options.password + "\n").utf8)
            try runner.run(Engines.require("7zz"), ["a", "-tzip", "-mem=AES256", "-p", output.path, "--"] + names,
                           directory: folder, input: password)
        } else {
            let result = try runner.run(Engines.require("7zz"), ["t", "--", input.path])
            try result.write(to: output, atomically: true, encoding: .utf8)
        }
    }
}

// parse cue boundaries so timestamp punctuation is changed without touching spoken text
enum SubtitleEngine {
    struct Cue: Equatable {
        var timing: String
        var lines: [String]
    }

    static func parse(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains(" --> ") }) else { continue }
            cues.append(Cue(timing: lines[index], lines: Array(lines.dropFirst(index + 1))))
        }
        return cues
    }

    static func convert(_ input: URL, format: String, output: URL) throws {
        let cues = parse(try String(contentsOf: input, encoding: .utf8))
        guard !cues.isEmpty else { throw FileelError.message("No subtitle cues were found.") }
        let result: String
        if format == "txt" {
            result = cues.map { $0.lines.joined(separator: "\n") }.joined(separator: "\n\n")
        } else {
            let blocks = cues.enumerated().map { index, cue in
                var timing = cue.timing
                if format == "srt" {
                    timing = timing.components(separatedBy: " --> ").map { side in
                        let stamp = String(side.split(separator: " ").first ?? "")
                        let full = stamp.filter { $0 == ":" }.count == 1 ? "00:" + stamp : stamp
                        return full.replacingOccurrences(of: ".", with: ",")
                    }.joined(separator: " --> ")
                } else {
                    timing = timing.replacingOccurrences(of: ",", with: ".")
                }
                return (format == "srt" ? "\(index + 1)\n" : "") + timing + "\n" + cue.lines.joined(separator: "\n")
            }
            result = (format == "vtt" ? "WEBVTT\n\n" : "") + blocks.joined(separator: "\n\n") + "\n"
        }
        try result.write(to: output, atomically: true, encoding: .utf8)
    }
}
