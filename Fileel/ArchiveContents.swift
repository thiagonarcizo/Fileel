import Foundation

// keep archive browsing read-only and synthesize folders that zip writers often omit
struct ArchiveEntry: Identifiable, Sendable, Equatable {
    let path: String
    let isDirectory: Bool
    var size: Int64
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var parent: String {
        let value = (path as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }
}

struct ArchiveContents: Sendable {
    let entries: [ArchiveEntry]
    var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    var folderCount: Int { entries.filter(\.isDirectory).count }
    var expandedSize: Int64 { entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size } }

    func children(of folder: String, matching query: String = "") -> [ArchiveEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { query.isEmpty ? $0.parent == folder : $0.path.localizedStandardContains(query) }
    }

    static func read(_ input: URL, runner: ProcessRunner) throws -> Self {
        let listing = try runner.run(Engines.require("7zz"), ["l", "-slt", "-ba", "-sccUTF-8", "--", input.path])
        return try parse(listing)
    }

    // technical listings separate records with blank lines and retain spaces in filenames
    static func parse(_ listing: String) throws -> Self {
        var records: [[String: String]] = []
        var record: [String: String] = [:]
        for line in listing.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty {
                if !record.isEmpty { records.append(record); record = [:] }
            } else if let separator = line.range(of: " = ") {
                record[String(line[..<separator.lowerBound])] = String(line[separator.upperBound...])
            }
        }
        if !record.isEmpty { records.append(record) }
        var items: [String: ArchiveEntry] = [:]
        var total: Int64 = 0
        for record in records {
            guard let raw = record["Path"] else { continue }
            guard ArchiveEngine.safePath(raw) else { throw FileelError.message("The archive contains an unsafe path.") }
            let path = raw.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
            guard !path.isEmpty else { continue }
            let directory = record["Folder"] == "+" || record["Attributes"]?.hasPrefix("D") == true || raw.hasSuffix("/")
            let size = max(0, Int64(record["Size"] ?? "") ?? 0)
            // reject overflowing totals before summing nested folder sizes
            let sum = total.addingReportingOverflow(directory ? 0 : size)
            guard !sum.overflow else { throw FileelError.message("The archive reports an unsupported file size.") }
            total = sum.partialValue
            items[path] = ArchiveEntry(path: path, isDirectory: directory, size: directory ? 0 : size)
        }
        let explicit = Array(items.values)
        for entry in explicit {
            var parent = entry.parent
            while !parent.isEmpty {
                if let existing = items[parent], !existing.isDirectory {
                    throw FileelError.message("The archive has conflicting file and folder names.")
                }
                if items[parent] == nil { items[parent] = ArchiveEntry(path: parent, isDirectory: true, size: 0) }
                if !entry.isDirectory { items[parent]!.size += entry.size }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return Self(entries: items.values.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        })
    }
}
