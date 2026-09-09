import Foundation
import CryptoKit

// Originals are the source of truth. Favorites and tags only change this sidecar.
struct ArchiveMetadata: Codable {
    var favorites: [String] = []
    var tags: [String: [String]] = [:]
}

struct ArchiveFile: Codable {
    var name: String
    var size: Int64
    var sha256: String
}

struct ArchiveRecord: Codable {
    var version: Int = 2
    var id: String
    var name: String
    // These legacy fields remain readable by older hosts; files is authoritative.
    var filename: String
    var size: Int64
    var sha256: String
    var createdAt: String
    var metadata: ArchiveMetadata
    var files: [ArchiveFile]
    var storage: String
    var sourceFolder: String?

    private enum CodingKeys: String, CodingKey {
        case version, id, name, filename, size, sha256, createdAt, metadata, files, storage, sourceFolder
    }

    init(id: String = UUID().uuidString.lowercased(), name: String, files: [ArchiveFile], storage: String, sourceFolder: String? = nil) {
        self.id = id
        self.name = name
        self.files = files
        self.filename = files.first?.name ?? ""
        self.sha256 = files.first?.sha256 ?? ""
        self.size = files.reduce(0) { $0 + $1.size }
        self.createdAt = ISO8601DateFormatter().string(from: Date())
        self.metadata = ArchiveMetadata()
        self.storage = storage
        self.sourceFolder = sourceFolder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        filename = try c.decode(String.self, forKey: .filename)
        size = try c.decode(Int64.self, forKey: .size)
        sha256 = try c.decode(String.self, forKey: .sha256)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        metadata = try c.decodeIfPresent(ArchiveMetadata.self, forKey: .metadata) ?? ArchiveMetadata()
        storage = try c.decode(String.self, forKey: .storage)
        sourceFolder = try c.decodeIfPresent(String.self, forKey: .sourceFolder)
        // Reading a v1 sidecar never relocates its ZIP or replaces its identity.
        files = try c.decodeIfPresent([ArchiveFile].self, forKey: .files)
            ?? [ArchiveFile(name: filename, size: size, sha256: sha256)]
    }

    func json() throws -> [String: Any] {
        var result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        result.removeValue(forKey: "storage")
        result.removeValue(forKey: "sourceFolder")
        result["kind"] = files.count == 1 && filename.lowercased().hasSuffix(".zip") ? "zip" : "folder"
        result["addedAt"] = createdAt
        result["url"] = "claude-archive://archive/\(id)/0"
        result["files"] = files.enumerated().map { index, file in
            ["name": file.name, "size": file.size, "sha256": file.sha256,
             "url": "claude-archive://archive/\(id)/\(index)"] as [String: Any]
        }
        return result
    }
}

enum ArchiveError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

// The host serializes access on its IO queue. Native code preserves file sets;
// the unchanged viewer remains responsible for interpreting their chat contents.
final class ArchiveStore {
    let root: URL
    private let fm = FileManager.default
    private(set) var warnings: [String] = []
    private let unpackedDirectories: Set<String> = ["projects", "memories", "reflections", "feedback", "light_metadata", "conversations"]

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
        try ensureDirectory(self.root)
    }

    private func ensureDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
            throw ArchiveError.invalid("档案目录不能是符号链接。")
        }
    }

    private func isPlainFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
            && url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path
    }

    private func folder(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id.lowercased() else {
            throw ArchiveError.invalid("档案 ID 无效。")
        }
        let result = root.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: result.path) { try ensureDirectory(result) }
        return result
    }

    private func validatePath(_ name: String, singleComponent: Bool = false) throws {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, !name.contains("\\"), !name.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              (!singleComponent || parts.count == 1) else {
            throw ArchiveError.invalid("档案文件路径无效。")
        }
    }

    private func isSupported(_ name: String) -> Bool {
        ["zip", "json", "md", "markdown"].contains((name as NSString).pathExtension.lowercased())
    }

    private func isManifest(_ name: String) -> Bool {
        let base = (name as NSString).lastPathComponent.lowercased()
        return base == "manifest.json" || (base.hasPrefix("manifest-") && base.hasSuffix(".json"))
    }

    private func isCategoryZIP(_ name: String) -> Bool {
        let base = (name as NSString).lastPathComponent.lowercased()
        return base.range(of: "^(conversations|projects|memories|feedback|light_metadata)-[0-9]+(?: \\([0-9]+\\))?\\.zip$", options: .regularExpression) != nil
    }

    private func sourceBase(_ record: ArchiveRecord) throws -> URL {
        try ensureDirectory(root)
        let metadataFolder = try folder(record.id)
        switch record.storage {
        case "root":
            guard record.files.count == 1 else { throw ArchiveError.invalid("旧档案记录无效。") }
            try validatePath(record.files[0].name, singleComponent: true)
            return root
        case "directory":
            guard record.files.count == 1 else { throw ArchiveError.invalid("旧档案记录无效。") }
            try validatePath(record.files[0].name, singleComponent: true)
            return metadataFolder
        case "bundle":
            let originals = metadataFolder.appendingPathComponent("originals", isDirectory: true)
            try ensureDirectory(originals)
            return originals
        case "externalDirectory":
            guard let name = record.sourceFolder, !name.hasPrefix("."), UUID(uuidString: name) == nil else {
                throw ArchiveError.invalid("档案来源文件夹无效。")
            }
            try validatePath(name, singleComponent: true)
            let source = root.appendingPathComponent(name, isDirectory: true)
            try ensureDirectory(source)
            return source
        default: throw ArchiveError.invalid("档案位置无效。")
        }
    }

    func originalURL(_ record: ArchiveRecord, index: Int = 0) throws -> URL {
        guard record.files.indices.contains(index) else { throw ArchiveError.invalid("档案文件序号无效。") }
        let file = record.files[index]
        try validatePath(file.name)
        guard isSupported(file.name) else { throw ArchiveError.invalid("档案文件类型无效。") }
        let url = try sourceBase(record).appendingPathComponent(file.name).standardizedFileURL
        guard isPlainFile(url) else {
            throw ArchiveError.invalid("找不到档案原件，或文件是符号链接。请刷新档案列表。")
        }
        return url
    }

    // Hash every byte, including ZIP comments and JSON whitespace. Extensions
    // are passed separately so the same check works for extensionless staging files.
    private func fingerprint(_ url: URL, name: String? = nil) throws -> ArchiveFile {
        let filename = name ?? url.lastPathComponent
        guard isPlainFile(url), isSupported(filename) else { throw ArchiveError.invalid("档案必须是普通 ZIP、JSON 或 Markdown 文件。") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4) ?? Data()
        if (filename as NSString).pathExtension.lowercased() == "zip" {
            guard [Data([0x50, 0x4b, 0x03, 0x04]), Data([0x50, 0x4b, 0x05, 0x06]), Data([0x50, 0x4b, 0x07, 0x08])].contains(header) else {
                throw ArchiveError.invalid("\(filename)：文件没有有效的 ZIP 文件头。")
            }
        }
        var hash = SHA256()
        hash.update(data: header)
        var size = Int64(header.count)
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            size += Int64(chunk.count)
            hash.update(data: chunk)
        }
        return ArchiveFile(name: filename, size: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func readSidecar(_ id: String) throws -> ArchiveRecord {
        let sidecar = try folder(id).appendingPathComponent("record.json")
        guard isPlainFile(sidecar) else { throw ArchiveError.invalid("找不到档案记录。") }
        let attributes = try fm.attributesOfItem(atPath: sidecar.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 8 * 1024 * 1024 else { throw ArchiveError.invalid("档案记录过大。") }
        let record = try JSONDecoder().decode(ArchiveRecord.self, from: Data(contentsOf: sidecar))
        guard record.id == id, [1, 2].contains(record.version), !record.files.isEmpty,
              record.files.count <= 100_000 else { throw ArchiveError.invalid("档案记录无效。") }
        var names = Set<String>()
        for file in record.files {
            try validatePath(file.name)
            guard file.size >= 0, file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  names.insert(file.name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ArchiveError.invalid("档案文件记录无效或重名。")
            }
        }
        return record
    }

    private func readRecord(_ id: String) throws -> ArchiveRecord {
        let record = try readSidecar(id)
        for index in record.files.indices { _ = try originalURL(record, index: index) }
        return record
    }

    private func save(_ record: ArchiveRecord) throws {
        let directory = try folder(record.id)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try ensureDirectory(directory)
        let sidecar = directory.appendingPathComponent("record.json")
        if fm.fileExists(atPath: sidecar.path), !isPlainFile(sidecar) { throw ArchiveError.invalid("档案记录不能是符号链接。") }
        let data = try JSONEncoder().encode(record)
        guard data.count <= 8 * 1024 * 1024 else { throw ArchiveError.invalid("档案记录过大。") }
        try data.write(to: sidecar, options: .atomic)
    }

    private struct SourceSet {
        var name: String
        var files: [(url: URL, file: ArchiveFile)]
        var folder: URL?
    }

    // Only an explicitly selected folder defines one export. Known unpacked
    // category folders are permitted; arbitrary nested account folders are not merged.
    private func inspectFolder(_ directory: URL) throws -> SourceSet {
        try ensureDirectory(directory)
        guard directory.standardizedFileURL.path != root.path else {
            throw ArchiveError.invalid("请选择某个账号的一次导出文件夹，不要选择整个 Archives 档案库。")
        }
        var entries: [(url: URL, file: ArchiveFile)] = []
        func walk(_ current: URL, prefix: String) throws {
            let children = try fm.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = prefix + child.lastPathComponent
                try validatePath(name)
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw ArchiveError.invalid("导出文件夹包含符号链接：\(name)。") }
                if values.isDirectory == true {
                    guard prefix.isEmpty && unpackedDirectories.contains(child.lastPathComponent.lowercased()) else {
                        throw ArchiveError.invalid("\(directory.lastPathComponent) 包含独立子文件夹 \(name)。请分别选择每个账号的一次导出文件夹。")
                    }
                    try ensureDirectory(child)
                    try walk(child, prefix: name + "/")
                } else if isSupported(name) {
                    entries.append((child, try fingerprint(child, name: name)))
                }
            }
        }
        try walk(directory, prefix: "")
        guard !entries.isEmpty else { throw ArchiveError.invalid("\(directory.lastPathComponent) 中没有 ZIP、JSON 或 Markdown 原件。") }
        guard Set(entries.map { $0.file.name.precomposedStringWithCanonicalMapping.lowercased() }).count == entries.count else {
            throw ArchiveError.invalid("导出文件夹包含名称冲突的文件。")
        }
        let manifests = entries.filter { isManifest($0.file.name) }
        guard manifests.count <= 1 else { throw ArchiveError.invalid("同一文件夹包含多份 manifest。请把不同账号或不同次导出分别放入文件夹。") }
        let zips = entries.filter { $0.file.name.lowercased().hasSuffix(".zip") }
        if let manifest = manifests.first {
            guard manifest.file.size <= 8 * 1024 * 1024,
                  let data = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest.url)) as? [String: Any],
                  let descriptors = data["data_files"] as? [[String: Any]], !descriptors.isEmpty else {
                throw ArchiveError.invalid("manifest 不是有效的 Claude 导出清单。")
            }
            var wanted = Set<String>()
            for descriptor in descriptors {
                guard let filename = descriptor["filename"] as? String else { throw ArchiveError.invalid("manifest 缺少文件名。") }
                try validatePath(filename, singleComponent: true)
                guard filename.lowercased().hasSuffix(".zip"), wanted.insert(filename.lowercased()).inserted else {
                    throw ArchiveError.invalid("manifest 中存在无效或重复的文件名。")
                }
            }
            let actual = Set(zips.map { ($0.file.name as NSString).lastPathComponent.lowercased() })
            let missing = wanted.subtracting(actual).sorted()
            let extra = actual.subtracting(wanted).sorted()
            guard missing.isEmpty else { throw ArchiveError.invalid("这次导出缺少清单中的文件：\(missing.joined(separator: "、"))。请补齐后重试。") }
            guard extra.isEmpty else { throw ArchiveError.invalid("文件夹中有清单未包含的 ZIP：\(extra.joined(separator: "、"))。请将其他账号或导出移到独立文件夹。") }
        } else if zips.count > 1 {
            guard zips.allSatisfy({ isCategoryZIP($0.file.name) }) else {
                throw ArchiveError.invalid("文件夹包含多个旧版 ZIP，无法确认它们属于同一次导出。请分别导入这些 ZIP，或把新版清单和分片放入一个文件夹。")
            }
            throw ArchiveError.invalid("多个分类 ZIP 需要对应 manifest，才能确认它们属于同一次导出。请把清单一并放入文件夹。")
        }
        return SourceSet(name: directory.lastPathComponent, files: entries, folder: directory)
    }

    func list() throws -> [ArchiveRecord] {
        try ensureDirectory(root)
        warnings = []
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles])
        var records: [ArchiveRecord] = []
        var knownRootNames = Set<String>()
        var knownFolders = Set<String>()
        for child in children where UUID(uuidString: child.lastPathComponent) != nil {
            do {
                var record = try readSidecar(child.lastPathComponent)
                if record.storage == "root" { knownRootNames.insert(record.filename) }
                if record.storage == "externalDirectory", let name = record.sourceFolder { knownFolders.insert(name) }
                if record.storage == "externalDirectory" {
                    let set = try inspectFolder(sourceBase(record))
                    record.files = set.files.map(\.file)
                    record.filename = record.files[0].name
                    record.sha256 = record.files[0].sha256
                    record.size = record.files.reduce(0) { $0 + $1.size }
                    try save(record)
                } else {
                    for index in record.files.indices {
                        let file = try fingerprint(originalURL(record, index: index), name: record.files[index].name)
                        if record.storage == "root" {
                            record.files[index] = file
                            record.size = file.size
                            record.sha256 = file.sha256
                            try save(record)
                        } else if file.sha256 != record.files[index].sha256 || file.size != record.files[index].size {
                            throw ArchiveError.invalid("原件与导入时的校验值不符；文件可能已损坏或被修改。")
                        }
                    }
                }
                records.append(record)
            } catch {
                warnings.append("\(child.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        for child in children where UUID(uuidString: child.lastPathComponent) == nil {
            do {
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isDirectory == true {
                    if knownFolders.contains(child.lastPathComponent) { continue }
                    let set = try inspectFolder(child)
                    let record = ArchiveRecord(name: set.name, files: set.files.map(\.file), storage: "externalDirectory", sourceFolder: child.lastPathComponent)
                    try save(record)
                    records.append(record)
                } else if child.pathExtension.lowercased() == "zip" && !knownRootNames.contains(child.lastPathComponent) {
                    if isCategoryZIP(child.lastPathComponent) {
                        throw ArchiveError.invalid("分类 ZIP 请和 manifest 放进一个独立导出文件夹；不会将 Archives 顶层的文件自动合并。")
                    }
                    let file = try fingerprint(child)
                    let record = ArchiveRecord(name: child.deletingPathExtension().lastPathComponent, files: [file], storage: "root")
                    try save(record)
                    records.append(record)
                }
            } catch { warnings.append("\(child.lastPathComponent)：\(error.localizedDescription)") }
        }
        return records.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    func importSources(_ sources: [URL]) throws -> [ArchiveRecord] {
        guard !sources.isEmpty else { return [] }
        try ensureDirectory(root)
        var sets: [SourceSet] = []
        for source in sources {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ArchiveError.invalid("不能导入符号链接。") }
            if values.isDirectory == true {
                sets.append(try inspectFolder(source.standardizedFileURL))
            } else {
                try validatePath(source.lastPathComponent, singleComponent: true)
                guard source.pathExtension.lowercased() == "zip", !isCategoryZIP(source.lastPathComponent) else {
                    throw ArchiveError.invalid("新版导出请先把 manifest 和全部分类 ZIP 放进同一个文件夹，再选择该文件夹。旧版完整 ZIP 可直接选择。")
                }
                sets.append(SourceSet(name: source.deletingPathExtension().lastPathComponent,
                                      files: [(source, try fingerprint(source))], folder: nil))
            }
        }
        // Duplicate legacy single-ZIP imports retain the historical behavior.
        // Explicit folders are separate archives even if their bytes happen to match.
        var existing = try list()
        var imported: [ArchiveRecord] = []
        var committed: [URL] = []
        do {
            for set in sets {
                if let sourceFolder = set.folder, sourceFolder.deletingLastPathComponent().standardizedFileURL.path == root.path,
                   let found = existing.first(where: { $0.storage == "externalDirectory" && $0.sourceFolder == sourceFolder.lastPathComponent }) {
                    imported.append(found)
                    continue
                }
                if set.folder == nil, let found = existing.first(where: { $0.files.count == 1 && $0.files[0].sha256 == set.files[0].file.sha256 }) {
                    imported.append(found)
                    continue
                }
                let record = ArchiveRecord(name: set.name, files: set.files.map(\.file), storage: "bundle")
                let staging = root.appendingPathComponent(".import-" + record.id, isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? fm.removeItem(at: staging) }
                let originals = staging.appendingPathComponent("originals", isDirectory: true)
                try fm.createDirectory(at: originals, withIntermediateDirectories: false)
                for item in set.files {
                    let copy = originals.appendingPathComponent(item.file.name)
                    try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: item.url, to: copy)
                    let copied = try fingerprint(copy, name: item.file.name)
                    guard copied.sha256 == item.file.sha256 && copied.size == item.file.size else {
                        throw ArchiveError.invalid("复制校验失败；原文件可能正在改变。请重试。")
                    }
                }
                try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("record.json"), options: .atomic)
                let destination = try folder(record.id)
                try fm.moveItem(at: staging, to: destination)
                committed.append(destination)
                imported.append(record)
                existing.append(record)
            }
        } catch {
            // A failed batch leaves no newly committed managed copies behind.
            for destination in committed { try? fm.removeItem(at: destination) }
            throw error
        }
        return imported
    }

    func importZIP(_ source: URL) throws -> ArchiveRecord { try importSources([source])[0] }
    func record(_ id: String) throws -> ArchiveRecord { try readRecord(id) }

    func updateMetadata(_ id: String, metadata: ArchiveMetadata) throws -> ArchiveRecord {
        var record = try readRecord(id)
        record.metadata = metadata
        try save(record)
        return record
    }

    func rename(_ id: String, name: String) throws -> ArchiveRecord {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 200 else { throw ArchiveError.invalid("档案名称须为 1–200 个字符。") }
        var record = try readRecord(id)
        record.name = label
        try save(record)
        return record
    }

    func recycleURLs(_ id: String) throws -> [URL] {
        let record = try readRecord(id)
        if record.storage == "root" { return [try originalURL(record), try folder(id)] }
        if record.storage == "externalDirectory" { return [try sourceBase(record), try folder(id)] }
        return [try folder(id)]
    }

    private func collisionFree(_ directory: URL, name: String, isDirectory: Bool = false) -> URL {
        var result = directory.appendingPathComponent(name, isDirectory: isDirectory)
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var suffix = 1
        while fm.fileExists(atPath: result.path) {
            result = directory.appendingPathComponent("\(stem) (\(suffix))" + (ext.isEmpty ? "" : "." + ext), isDirectory: isDirectory)
            suffix += 1
        }
        return result
    }

    private func copyChecked(_ source: URL, expected: ArchiveFile, to copy: URL) throws {
        let before = try fingerprint(source, name: expected.name)
        guard before.sha256 == expected.sha256 && before.size == expected.size else {
            throw ArchiveError.invalid("原件与档案校验值不符。请刷新列表后检查原始文件。")
        }
        try fm.copyItem(at: source, to: copy)
        let after = try fingerprint(copy, name: expected.name)
        guard after.sha256 == before.sha256 && after.size == before.size else { throw ArchiveError.invalid("导出副本校验失败。") }
    }

    func exportFile(_ id: String, index: Int, to directory: URL) throws -> URL {
        try ensureDirectory(directory)
        let record = try readRecord(id)
        let source = try originalURL(record, index: index)
        let file = record.files[index]
        let destination = collisionFree(directory, name: (file.name as NSString).lastPathComponent)
        let staging = directory.appendingPathComponent(".claude-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try copyChecked(source, expected: file, to: staging)
        try fm.moveItem(at: staging, to: destination)
        return destination
    }

    func exportSet(_ id: String, to directory: URL) throws -> URL {
        try ensureDirectory(directory)
        let record = try readRecord(id)
        // A legacy single ZIP stays a ZIP. A folder is exported with its original
        // relative paths and bytes, never recompressed into a different ZIP.
        if record.files.count == 1 && record.files[0].name.lowercased().hasSuffix(".zip") {
            return try exportFile(id, index: 0, to: directory)
        }
        let label = record.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
        let name = label.isEmpty || label == "." || label == ".." ? "Claude Export" : label
        let destination = collisionFree(directory, name: name, isDirectory: true)
        let staging = directory.appendingPathComponent(".claude-export-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for index in record.files.indices {
            let file = record.files[index]
            let source = try originalURL(record, index: index)
            let copy = staging.appendingPathComponent(file.name)
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copyChecked(source, expected: file, to: copy)
        }
        try fm.moveItem(at: staging, to: destination)
        return destination
    }

    func exportZIP(_ id: String, to directory: URL) throws -> URL { try exportSet(id, to: directory) }
}
