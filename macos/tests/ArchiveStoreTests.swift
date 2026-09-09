import Foundation

@main
struct ArchiveStoreTests {
    static let fm = FileManager.default
    static func main() throws {
        let workspace = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let sourceA = workspace.appendingPathComponent("account-a.zip")
        let sourceB = workspace.appendingPathComponent("account-b.zip")
        let bytesA = try Data(contentsOf: sourceA)
        let bytesB = try Data(contentsOf: sourceB)
        let store = try ArchiveStore(root: workspace.appendingPathComponent("Archives"))
        let first = try store.importZIP(sourceA)
        let second = try store.importZIP(sourceB)
        check(first.id != second.id)
        check(try store.list().count == 2)
        check(try Data(contentsOf: store.originalURL(first)) == bytesA)
        check(try Data(contentsOf: sourceA) == bytesA)
        check(try Data(contentsOf: sourceB) == bytesB)

        let renamedCopy = workspace.appendingPathComponent("same-bytes-different-name.zip")
        try fm.copyItem(at: sourceA, to: renamedCopy)
        check(try store.importZIP(renamedCopy).id == first.id)
        _ = try store.updateMetadata(first.id, metadata: ArchiveMetadata(favorites: ["shared-conversation-id"], tags: ["shared-conversation-id": ["A-only"]]))
        check(try store.record(second.id).metadata.favorites.isEmpty)
        let renamed = try store.rename(first.id, name: "Account A — 私人")
        check(renamed.filename == first.filename && renamed.name == "Account A — 私人")
        check(try Data(contentsOf: store.originalURL(renamed)) == bytesA)
        let publicRecord = try renamed.json()
        let publicFiles = publicRecord["files"] as! [[String: Any]]
        check(publicFiles[0]["url"] as? String == "claude-archive://archive/\(renamed.id)/0")
        check(publicRecord["storage"] == nil && publicRecord["sourceFolder"] == nil)

        let exportFolder = workspace.appendingPathComponent("exports")
        try fm.createDirectory(at: exportFolder, withIntermediateDirectories: false)
        let exported = try store.exportZIP(first.id, to: exportFolder)
        let exportedAgain = try store.exportZIP(first.id, to: exportFolder)
        check(exported != exportedAgain)
        check(try Data(contentsOf: exported) == bytesA)
        check(try Data(contentsOf: exportedAgain) == bytesA)

        // Simulate Finder dropping a ZIP: keep its name, bytes and location intact.
        let dropped = store.root.appendingPathComponent("dropped.zip")
        let droppedBytes = bytesA + Data("unique ZIP comment".utf8)
        try droppedBytes.write(to: dropped)
        let discovered = try store.list().first { $0.filename == "dropped.zip" }!
        check(try store.originalURL(discovered) == dropped)
        check(try Data(contentsOf: dropped) == droppedBytes)
        _ = try store.updateMetadata(discovered.id, metadata: ArchiveMetadata(favorites: ["kept"], tags: [:]))
        try fm.removeItem(at: dropped)
        check(try !store.list().contains { $0.id == discovered.id })
        check(!store.warnings.isEmpty)
        try droppedBytes.write(to: dropped)
        let restored = try store.list().first { $0.id == discovered.id }!
        check(restored.metadata.favorites == ["kept"])
        check(try store.recycleURLs(restored.id).count == 2)
        check(try store.recycleURLs(first.id).count == 1)

        // Upgrade a real v1 record: its UUID, sidecar metadata and ZIP stay in place.
        let legacyID = UUID().uuidString.lowercased()
        let legacyFolder = store.root.appendingPathComponent(legacyID)
        try fm.createDirectory(at: legacyFolder, withIntermediateDirectories: false)
        let legacyZIP = legacyFolder.appendingPathComponent("legacy-original.zip")
        try bytesA.write(to: legacyZIP)
        let v1: [String: Any] = ["id": legacyID, "name": "Old account", "filename": "legacy-original.zip",
            "size": first.size, "sha256": first.sha256, "createdAt": "2026-01-02T00:00:00Z",
            "metadata": ["favorites": ["old-favorite"], "tags": ["old-favorite": ["旧标签"]]], "storage": "directory"]
        try JSONSerialization.data(withJSONObject: v1).write(to: legacyFolder.appendingPathComponent("record.json"))
        let migrated = try store.record(legacyID)
        check(migrated.id == legacyID && migrated.files.count == 1)
        check(migrated.metadata.favorites == ["old-favorite"])
        check(migrated.metadata.tags["old-favorite"] == ["旧标签"])
        check(try store.originalURL(migrated) == legacyZIP)
        _ = try store.rename(legacyID, name: "仍是旧账号")
        let reopened = try ArchiveStore(root: store.root).record(legacyID)
        check(reopened.metadata.favorites == ["old-favorite"])
        check(try Data(contentsOf: legacyZIP) == bytesA)
        check(!fm.fileExists(atPath: legacyFolder.appendingPathComponent("originals").path))

        // One export may have many category ZIPs, conversations shards and loose
        // project JSON. Every filename, subpath and original byte must round-trip.
        let setA = workspace.appendingPathComponent("account-A-export")
        let setB = workspace.appendingPathComponent("account-B-export")
        let zipNames = ["conversations-000.zip", "conversations-001.zip", "projects-000.zip", "memories-000.zip", "feedback-000.zip", "light_metadata-000.zip"]
        let originalSet = try makeExport(setA, zipNames: zipNames, zipBytes: bytesA)
        try fm.copyItem(at: setA, to: setB) // Identical bytes still have distinct folder identities.
        let batch = try store.importSources([setA, setB])
        check(batch.count == 2 && batch[0].id != batch[1].id)
        check(batch[0].files.count == originalSet.count)
        check(batch[0].files.map(\.name).contains("projects/project-original.json"))
        for record in batch {
            for index in record.files.indices {
                check(try Data(contentsOf: store.originalURL(record, index: index)) == originalSet[record.files[index].name])
                check(try Data(contentsOf: setA.appendingPathComponent(record.files[index].name)) == originalSet[record.files[index].name])
            }
        }
        _ = try store.updateMetadata(batch[0].id, metadata: ArchiveMetadata(favorites: ["same-id"], tags: ["same-id": ["A only"]]))
        check(try store.record(batch[1].id).metadata.favorites.isEmpty)
        let extractedSet = try store.exportSet(batch[0].id, to: exportFolder)
        let extractedAgain = try store.exportSet(batch[0].id, to: exportFolder)
        check(extractedSet != extractedAgain)
        for (name, bytes) in originalSet {
            check(try Data(contentsOf: extractedSet.appendingPathComponent(name)) == bytes)
            check(try Data(contentsOf: extractedAgain.appendingPathComponent(name)) == bytes)
        }
        check(try Data(contentsOf: extractedSet.appendingPathComponent("record.json")) == originalSet["record.json"])
        let jsonIndex = batch[0].files.firstIndex { $0.name == "projects/project-original.json" }!
        let singleJSON = try store.exportFile(batch[0].id, index: jsonIndex, to: exportFolder)
        check(try Data(contentsOf: singleJSON) == originalSet["projects/project-original.json"])
        expectFailure { _ = try store.originalURL(batch[0], index: -1) }
        expectFailure { _ = try store.exportFile(batch[0].id, index: 1000, to: exportFolder) }

        // A user-owned folder placed in Archives is registered without moving it
        // or writing a sidecar into that folder. Removal/reinsertion retains metadata.
        let droppedFolder = store.root.appendingPathComponent("Finder account C")
        try fm.copyItem(at: setA, to: droppedFolder)
        let inPlace = try store.list().first { $0.sourceFolder == "Finder account C" }!
        check(inPlace.storage == "externalDirectory")
        check(try store.originalURL(inPlace, index: 0).deletingLastPathComponent().path == droppedFolder.path)
        check(try Data(contentsOf: droppedFolder.appendingPathComponent("record.json")) == originalSet["record.json"])
        check(try store.importSources([droppedFolder])[0].id == inPlace.id)
        _ = try store.updateMetadata(inPlace.id, metadata: ArchiveMetadata(favorites: ["in place"], tags: [:]))
        let temporarilyRemoved = workspace.appendingPathComponent("temporarily removed")
        try fm.moveItem(at: droppedFolder, to: temporarilyRemoved)
        check(try !store.list().contains { $0.id == inPlace.id })
        try fm.moveItem(at: temporarilyRemoved, to: droppedFolder)
        let inPlaceRestored = try store.list().first { $0.id == inPlace.id }!
        check(inPlaceRestored.metadata.favorites == ["in place"])
        check(try store.recycleURLs(inPlaceRestored.id).map(\.path) == [droppedFolder.path, store.root.appendingPathComponent(inPlace.id).path])

        // Ambiguous cross-account selections and incomplete manifests fail before
        // any managed import is committed. Their source files remain untouched.
        let beforeRejected = try store.list().count
        expectFailure { _ = try store.importSources([setA.appendingPathComponent("conversations-000.zip"), setB.appendingPathComponent("projects-000.zip")]) }
        expectFailure { _ = try store.importSources([store.root]) }
        let mixedParent = workspace.appendingPathComponent("mixed accounts")
        try fm.createDirectory(at: mixedParent, withIntermediateDirectories: false)
        try fm.copyItem(at: setA, to: mixedParent.appendingPathComponent("A"))
        try fm.copyItem(at: setB, to: mixedParent.appendingPathComponent("B"))
        expectFailure { _ = try store.importSources([mixedParent]) }
        let incomplete = workspace.appendingPathComponent("incomplete export")
        try fm.copyItem(at: setA, to: incomplete)
        try fm.removeItem(at: incomplete.appendingPathComponent("memories-000.zip"))
        expectFailure { _ = try store.importSources([setA, incomplete]) }
        try bytesA.write(to: incomplete.appendingPathComponent("memories-000.zip"))
        try bytesB.write(to: incomplete.appendingPathComponent("another-account.zip"))
        expectFailure { _ = try store.importSources([incomplete]) }
        try fm.removeItem(at: incomplete.appendingPathComponent("another-account.zip"))
        try fm.copyItem(at: incomplete.appendingPathComponent("manifest-synthetic.json"), to: incomplete.appendingPathComponent("manifest-second.json"))
        expectFailure { _ = try store.importSources([incomplete]) }
        check(try store.list().count == beforeRejected)
        check(try Data(contentsOf: setA.appendingPathComponent("conversations-000.zip")) == originalSet["conversations-000.zip"])

        let invalidSet = store.root.appendingPathComponent("unfinished account")
        try fm.copyItem(at: incomplete, to: invalidSet)
        check(try !store.list().contains { $0.sourceFolder == invalidSet.lastPathComponent })
        check(store.warnings.contains { $0.contains("unfinished account") })
        check(fm.fileExists(atPath: invalidSet.appendingPathComponent("manifest-second.json").path))

        // Mutated managed originals must not silently acquire a new checksum.
        let corruptedOriginal = try store.originalURL(batch[1], index: 0)
        try (Data(contentsOf: corruptedOriginal) + Data("modified after import".utf8)).write(to: corruptedOriginal)
        expectFailure { _ = try store.exportSet(batch[1].id, to: exportFolder) }
        check(try !store.list().contains { $0.id == batch[1].id })
        check(store.warnings.contains { $0.contains(batch[1].id) && $0.contains("校验") })
        check(!(try fm.contentsOfDirectory(atPath: exportFolder.path)).contains { $0.hasPrefix(".claude-export-") })

        // Reject symlinks at every boundary, including ancestor directories,
        // malformed sidecars and unsupported source data, without touching targets.
        let outside = workspace.appendingPathComponent("outside.zip")
        try (bytesB + Data("outside".utf8)).write(to: outside)
        try fm.createSymbolicLink(at: store.root.appendingPathComponent("link.zip"), withDestinationURL: outside)
        check(try !store.list().contains { $0.filename == "link.zip" })
        let linkedFolder = workspace.appendingPathComponent("linked export")
        try fm.createSymbolicLink(at: linkedFolder, withDestinationURL: setA)
        expectFailure { _ = try store.importSources([linkedFolder]) }
        expectFailure { _ = try store.importZIP(linkedFolder.appendingPathComponent("conversations-000.zip")) }
        let secondOriginal = try store.originalURL(second)
        try fm.removeItem(at: secondOriginal)
        try fm.createSymbolicLink(at: secondOriginal, withDestinationURL: outside)
        check(try !store.list().contains { $0.id == second.id })
        expectFailure { _ = try store.record("../../outside") }
        expectFailure { _ = try store.record(second.id) }
        expectFailure { _ = try store.rename(first.id, name: "  ") }
        let invalidZIP = workspace.appendingPathComponent("invalid.zip")
        try Data("not a zip".utf8).write(to: invalidZIP)
        expectFailure { _ = try store.importZIP(invalidZIP) }
        var badRecord = batch[0]
        badRecord.files[0].name = "../../outside.zip"
        expectFailure { _ = try store.originalURL(badRecord) }
        badRecord.files[0].name = "/outside.zip"
        expectFailure { _ = try store.originalURL(badRecord) }
        let linkedOutput = workspace.appendingPathComponent("linked output")
        try fm.createSymbolicLink(at: linkedOutput, withDestinationURL: exportFolder)
        expectFailure { _ = try store.exportSet(batch[0].id, to: linkedOutput) }
        check(try Data(contentsOf: sourceA) == bytesA)
        check(try Data(contentsOf: sourceB) == bytesB)
        check(!(try fm.contentsOfDirectory(atPath: store.root.path)).contains { $0.hasPrefix(".import-") })
        print("ArchiveStore: v1 migration, multi-file byte preservation, explicit folder isolation, indexed URLs, safe extraction, in-place discovery/restoration, incomplete/mixed rejection, corruption detection and path boundaries passed.")
    }

    static func makeExport(_ directory: URL, zipNames: [String], zipBytes: Data) throws -> [String: Data] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        var files: [String: Data] = [:]
        for name in zipNames { files[name] = zipBytes + Data(("ZIP comment for " + name).utf8) }
        let manifest: [String: Any] = ["created_at": "2026-09-08T00:00:00Z", "data_files": zipNames.enumerated().map { ["filename": $0.element, "part": $0.offset] as [String: Any] }]
        files["manifest-synthetic.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        files["projects/project-original.json"] = Data("{ \"uuid\": \"project\", \"name\": \"原始空白保留\" }\n".utf8)
        files["notes.md"] = Data("# Original notes\n\nNo rewriting.\n".utf8)
        files["record.json"] = Data("{\"user_file\":\"must not collide with the app sidecar\"}\n".utf8)
        for (name, bytes) in files {
            let file = directory.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        return files
    }

    static func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) { precondition(condition, "Check failed", file: file, line: line) }
    static func expectFailure(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejected operation") }
        catch { }
    }
}
