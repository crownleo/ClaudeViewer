import Foundation

@main
struct ArchiveStoreTests {
    static func main() throws {
        let fm = FileManager.default
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
        try droppedBytes.write(to: dropped)
        let restored = try store.list().first { $0.id == discovered.id }!
        check(restored.metadata.favorites == ["kept"])
        check(try store.recycleURLs(restored.id).count == 2)
        check(try store.recycleURLs(first.id).count == 1)

        let outside = workspace.appendingPathComponent("outside.zip")
        try (bytesB + Data("outside".utf8)).write(to: outside)
        try fm.createSymbolicLink(at: store.root.appendingPathComponent("link.zip"), withDestinationURL: outside)
        check(try !store.list().contains { $0.filename == "link.zip" })
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
        check(try Data(contentsOf: sourceA) == bytesA)
        print("ArchiveStore: preservation, deduplication, isolation, export collisions, refresh, restoration, and path boundaries passed.")
    }

    static func check(_ condition: Bool) { precondition(condition) }

    static func expectFailure(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejected operation") }
        catch { }
    }
}
