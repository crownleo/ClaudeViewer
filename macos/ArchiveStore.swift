import Foundation
import CryptoKit

// ZIP originals are the source of truth. Only this small JSON sidecar is edited.
struct ArchiveMetadata: Codable {
    var favorites: [String] = []
    var tags: [String: [String]] = [:]
}

struct ArchiveRecord: Codable {
    var id: String
    var name: String
    var filename: String
    var size: Int64
    var sha256: String
    var createdAt: String
    var metadata: ArchiveMetadata
    // Root ZIPs placed by hand stay in place; ordinary imports live in UUID folders.
    var storage: String

    func json() throws -> [String: Any] {
        var result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        result.removeValue(forKey: "storage")
        result["url"] = "claude-archive://archive/\(id)/original.zip"
        return result
    }
}

enum ArchiveError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

// All calls are serialized by the host's IO queue. Keeping the store independent
// of AppKit lets its preservation and path-boundary guarantees be tested directly.
final class ArchiveStore {
    let root: URL
    private let fm = FileManager.default

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
    }

    private func folder(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id.lowercased() else {
            throw ArchiveError.invalid("档案 ID 无效。")
        }
        let result = root.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: result.path) { try ensureDirectory(result) }
        return result
    }

    private func validateFilename(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), name == (name as NSString).lastPathComponent,
              (name as NSString).pathExtension.lowercased() == "zip" else {
            throw ArchiveError.invalid("请选择 ZIP 文件。")
        }
    }

    func originalURL(_ record: ArchiveRecord) throws -> URL {
        try ensureDirectory(root)
        try validateFilename(record.filename)
        let directory = try folder(record.id)
        guard record.storage == "root" || record.storage == "directory" else {
            throw ArchiveError.invalid("档案位置无效。")
        }
        let file = (record.storage == "root" ? root : directory).appendingPathComponent(record.filename)
        guard isPlainFile(file), file.resolvingSymlinksInPath().standardizedFileURL == file.standardizedFileURL else {
            throw ArchiveError.invalid("找不到档案原件，或文件是符号链接。请刷新档案列表。")
        }
        return file
    }

    private func fingerprint(_ url: URL) throws -> (Int64, String) {
        guard isPlainFile(url) else { throw ArchiveError.invalid("档案必须是普通 ZIP 文件。") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4) ?? Data()
        guard [Data([0x50, 0x4b, 0x03, 0x04]), Data([0x50, 0x4b, 0x05, 0x06]), Data([0x50, 0x4b, 0x07, 0x08])].contains(header) else {
            throw ArchiveError.invalid("文件没有有效的 ZIP 文件头。")
        }
        var hash = SHA256()
        hash.update(data: header)
        var size = Int64(header.count)
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            size += Int64(chunk.count)
            hash.update(data: chunk)
        }
        return (size, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func readRecord(_ id: String) throws -> ArchiveRecord {
        let sidecar = try folder(id).appendingPathComponent("record.json")
        guard isPlainFile(sidecar) else { throw ArchiveError.invalid("找不到档案记录。") }
        let attributes = try fm.attributesOfItem(atPath: sidecar.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 8 * 1024 * 1024 else {
            throw ArchiveError.invalid("档案记录过大。")
        }
        let record = try JSONDecoder().decode(ArchiveRecord.self, from: Data(contentsOf: sidecar))
        guard record.id == id else { throw ArchiveError.invalid("档案记录 ID 不匹配。") }
        _ = try originalURL(record)
        return record
    }

    private func save(_ record: ArchiveRecord) throws {
        let directory = try folder(record.id)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 8 * 1024 * 1024 else { throw ArchiveError.invalid("档案记录过大。") }
        try data.write(to: directory.appendingPathComponent("record.json"), options: .atomic)
    }

    func list() throws -> [ArchiveRecord] {
        try ensureDirectory(root)
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles])
        var records: [ArchiveRecord] = []
        for child in children where UUID(uuidString: child.lastPathComponent) != nil {
            // Missing originals and invalid/symlink sidecars stay untouched and are not exposed.
            guard var record = try? readRecord(child.lastPathComponent),
                  let url = try? originalURL(record), let (size, digest) = try? fingerprint(url) else { continue }
            if record.sha256 != digest || record.size != size {
                record.sha256 = digest
                record.size = size
                try save(record)
            }
            records.append(record)
        }
        let knownRootNames = Set(records.filter { $0.storage == "root" }.map(\.filename))
        for child in children where child.pathExtension.lowercased() == "zip" && !knownRootNames.contains(child.lastPathComponent) {
            guard isPlainFile(child), let (size, digest) = try? fingerprint(child),
                  !records.contains(where: { $0.sha256 == digest }) else { continue }
            let record = makeRecord(filename: child.lastPathComponent, size: size, sha256: digest, storage: "root")
            try save(record)
            records.append(record)
        }
        return records.sorted { $0.createdAt < $1.createdAt }
    }

    private func makeRecord(filename: String, size: Int64, sha256: String, storage: String) -> ArchiveRecord {
        ArchiveRecord(id: UUID().uuidString.lowercased(), name: (filename as NSString).deletingPathExtension,
                      filename: filename, size: size, sha256: sha256,
                      createdAt: ISO8601DateFormatter().string(from: Date()), metadata: ArchiveMetadata(), storage: storage)
    }

    func importZIP(_ source: URL) throws -> ArchiveRecord {
        try validateFilename(source.lastPathComponent)
        let (_, digest) = try fingerprint(source)
        if let existing = try list().first(where: { $0.sha256 == digest }) { return existing }
        let recordID = UUID().uuidString.lowercased()
        let staging = root.appendingPathComponent(".import-" + recordID, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: copy)
        let (size, copiedDigest) = try fingerprint(copy)
        guard digest == copiedDigest else { throw ArchiveError.invalid("复制校验失败；原文件可能正在改变。请重试。") }
        var record = makeRecord(filename: source.lastPathComponent, size: size, sha256: copiedDigest, storage: "directory")
        record.id = recordID
        try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("record.json"), options: .atomic)
        try fm.moveItem(at: staging, to: try folder(record.id))
        return record
    }

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
        return record.storage == "root" ? [try originalURL(record), try folder(id)] : [try folder(id)]
    }

    func exportZIP(_ id: String, to directory: URL) throws -> URL {
        let record = try readRecord(id)
        let source = try originalURL(record)
        var destination = directory.appendingPathComponent(record.filename)
        var suffix = 1
        while fm.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\((record.filename as NSString).deletingPathExtension) (\(suffix)).zip")
            suffix += 1
        }
        let staging = directory.appendingPathComponent(".claude-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        let (_, before) = try fingerprint(source)
        try fm.copyItem(at: source, to: staging)
        let (_, after) = try fingerprint(staging)
        guard before == after else { throw ArchiveError.invalid("导出副本校验失败。") }
        try fm.moveItem(at: staging, to: destination)
        return destination
    }
}
