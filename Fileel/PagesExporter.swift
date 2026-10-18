import Foundation

// keep apple's scripting runtime on the helper's main thread and never open a user's original document
enum PagesExporter {
    static func export(_ input: URL, output: URL, runner: ProcessRunner,
                       execute: (String, [String], ProcessRunner) throws -> Void = runScript) throws {
        try runner.checkCancellation()
        let workspace = output.deletingLastPathComponent().appendingPathComponent("pages-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("Source.docx")
        // follow a source symlink before copying so the owned document cannot point back to the original
        try FileManager.default.copyItem(at: input.resolvingSymlinksInPath(), to: source)
        // Pages resolves aliases, so use the same canonical paths for cancellation cleanup
        let arguments = [source.resolvingSymlinksInPath().path, output.resolvingSymlinksInPath().path]
        do {
            try execute(exportScript, arguments, runner)
            try runner.checkCancellation()
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw FileelError.message("Pages did not produce an output document.")
            }
        } catch is CancellationError {
            // a terminated worker can't run its own error handler, so close only this job's private document
            try? execute(cleanupScript, arguments, ProcessRunner())
            throw CancellationError()
        }
    }

    static func runScript(_ script: String, arguments: [String], runner: ProcessRunner) throws {
        // arguments stay separate from apple script source, including quotes and newlines in filenames
        try runner.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script, "--"] + arguments)
    }

    static let exportScript = """
    on run argv
        set inputFile to POSIX file (item 1 of argv)
        set outputFile to POSIX file (item 2 of argv)
        with timeout of 120 seconds
            tell application id "com.apple.iWork.Pages"
                set convertedDocument to open inputFile
                try
                    save convertedDocument in outputFile
                    close convertedDocument saving no
                on error errorText number errorNumber
                    try
                        with timeout of 5 seconds
                            close convertedDocument saving no
                        end timeout
                    end try
                    error errorText number errorNumber
                end try
            end tell
        end timeout
    end run
    """

    static let cleanupScript = """
    on run argv
        if application id "com.apple.iWork.Pages" is running then
            with timeout of 5 seconds
                tell application id "com.apple.iWork.Pages"
                    repeat with candidate in documents
                        try
                            set candidatePath to POSIX path of (file of candidate)
                            if candidatePath is in argv then close candidate saving no
                        end try
                    end repeat
                end tell
            end timeout
        end if
    end run
    """
}
