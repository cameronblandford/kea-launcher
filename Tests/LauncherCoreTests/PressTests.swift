import XCTest
@testable import LauncherCore

final class PressTests: XCTestCase {
    private var dir = ""
    /// The tests make new files, so the rule about recent changes is off.
    private var now: Press.Options { var o = Press.Options(); o.minAge = 0; return o }
    private let text = Data(String(repeating: "The quick brown fox jumps over the lazy dog.\n", count: 4000).utf8)

    override func setUp() {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("kea-press-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    @discardableResult
    private func write(_ name: String, _ data: Data, mode: Int = 0o644, attribute: String? = nil, modified: Date? = nil) -> String {
        let path = (dir as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data)
        chmod(path, mode_t(mode))
        if let attribute { _ = Array(attribute.utf8).withUnsafeBufferPointer { setxattr(path, "directory.kea.test", $0.baseAddress, $0.count, 0, 0) } }
        if let modified { try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
        return path
    }

    private func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }
    private func attribute(_ path: String) -> String? {
        var value = [UInt8](repeating: 0, count: 256)
        let size = getxattr(path, "directory.kea.test", &value, value.count, 0, 0)
        return size < 0 ? nil : String(decoding: value[..<size], as: UTF8.self)
    }
    private func leftovers() -> [String] {
        (FileManager.default.subpaths(atPath: dir) ?? []).filter { ($0 as NSString).lastPathComponent.hasPrefix(".kea-press-") }
    }

    // MARK: - Rules

    func testSkipRules() {
        let old = Date().addingTimeInterval(-10 * 86400).timeIntervalSince1970
        let file = Press.Facts(path: "/Users/me/doc/notes.txt", size: 50_000, allocated: 53_248, modified: old)
        XCTAssertNil(Press.skip(file))
        var f = file; f.modified = Date().addingTimeInterval(-3600).timeIntervalSince1970
        XCTAssertEqual(Press.skip(f), .recent)
        f = file; f.links = 2
        XCTAssertEqual(Press.skip(f), .hardLink)
        f = file; f.owner = getuid() + 1
        XCTAssertEqual(Press.skip(f), .notOwner)
        f = file; f.flags = UInt32(UF_IMMUTABLE)
        XCTAssertEqual(Press.skip(f), .locked)
        f = file; f.flags = UInt32(bitPattern: Int32(SF_DATALESS))
        XCTAssertEqual(Press.skip(f), .dataless, "a cloud-only file must not be read")
        f = file; f.size = 100
        XCTAssertEqual(Press.skip(f), .small)
        for name in ["app.sqlite", "data.db", "store.sqlite-wal", "History-journal", "disk.vmdk", "movie.mp4.part", "server.log", "Installer.dmg"] {
            f = file; f.path = "/Users/me/doc/\(name)"
            XCTAssertEqual(Press.skip(f), .liveData, name)
        }
        f = file; f.flags = UInt32(UF_COMPRESSED) | UInt32(UF_HIDDEN)
        XCTAssertNil(Press.skip(f), "a compressed or hidden file can still be shared")
    }

    func testWhatCanBeCompressedAndShared() {
        let file = Press.Facts(path: "/a/notes.txt", size: 50_000, allocated: 53_248, modified: 0)
        XCTAssertTrue(Press.canCompress(file))
        XCTAssertTrue(Press.canShare(file))
        var f = file; f.flags = UInt32(UF_COMPRESSED)
        XCTAssertFalse(Press.canCompress(f))
        for name in ["photo.JPG", "clip.mp4", "archive.zip", "paper.pdf", "song.m4a"] {
            f = file; f.path = "/a/\(name)"
            XCTAssertFalse(Press.canCompress(f), name)
            XCTAssertTrue(Press.canShare(f), "a duplicate of \(name) can share its data")
        }
        f = file; f.size = 3_000_000_000
        XCTAssertFalse(Press.canCompress(f))
        f = file; f.size = 2000
        XCTAssertFalse(Press.canCompress(f))
    }

    func testFoldersThatAreRefusedOrNotEntered() {
        let home = "/Users/me"
        XCTAssertNil(Press.refusal(root: "/Users/me/Downloads", home: home))
        XCTAssertNil(Press.refusal(root: "/Users/me/Projects/app/node_modules", home: home))
        XCTAssertNil(Press.refusal(root: "/Applications/Xcode.app", home: home))
        XCTAssertNotNil(Press.refusal(root: "/Users/me", home: home))
        XCTAssertNotNil(Press.refusal(root: "/Users/me/Library/Application Support", home: home))
        XCTAssertNotNil(Press.refusal(root: "/Users/me/Downloads/../Library", home: home))
        XCTAssertNotNil(Press.refusal(root: "/Users/me/.Trash", home: home))
        XCTAssertNotNil(Press.refusal(root: "/", home: home))
        XCTAssertNotNil(Press.refusal(root: "/System/Library", home: home))
        XCTAssertNotNil(Press.refusal(root: "/Users/other/Documents", home: home))
        XCTAssertNotNil(Press.refusal(root: "/Users/mexico", home: home))
        for name in [".git", ".Trash", "Photos Library.photoslibrary", "Windows.vmwarevm", "Backups.sparsebundle"] { XCTAssertTrue(Press.skipsFolder(named: name), name) }
        for name in ["node_modules", "src", "Documents", "git"] { XCTAssertFalse(Press.skipsFolder(named: name), name) }
    }

    // MARK: - Compress

    func testCompressKeepsTheContentAndTheMetadata() throws {
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        let path = write("notes.txt", text, mode: 0o640, attribute: "mine", modified: then)
        let before = try XCTUnwrap(Press.facts(path))
        let outcome = Press.compress(before, options: now)
        guard case .saved(let bytes) = outcome else { return XCTFail("\(outcome)") }
        let after = try XCTUnwrap(Press.facts(path))
        XCTAssertTrue(after.isCompressed)
        XCTAssertEqual(bytes, before.allocated - after.allocated)
        XCTAssertGreaterThan(bytes, 100_000)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), text)
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.mode, 0o640)
        XCTAssertEqual(after.modified, then.timeIntervalSince1970)
        XCTAssertEqual(attribute(path), "mine")
        XCTAssertEqual(leftovers(), [])
        // A second run finds nothing to do.
        XCTAssertEqual(Press.compress(after, options: now), .noGain)
    }

    func testAFileThatDoesNotGetSmallerStaysAsItWas() throws {
        let data = random(300_000)
        let path = write("noise.bin", data)
        let before = try XCTUnwrap(Press.facts(path))
        XCTAssertEqual(Press.compress(before, options: now), .noGain)
        let after = try XCTUnwrap(Press.facts(path))
        XCTAssertEqual(after.inode, before.inode, "the file was not replaced")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
        XCTAssertEqual(leftovers(), [])
    }

    func testCompressLeavesAFileThatIsInUseOrChanged() throws {
        let path = write("notes.txt", text)
        let planned = try XCTUnwrap(Press.facts(path))
        XCTAssertEqual(Press.compress(planned), .skipped(.recent), "the default rule leaves a file that changed in the last day")
        XCTAssertEqual(Press.compress(planned, options: now, open: [path]), .skipped(.inUse))
        // The file changes after the plan.
        try (text + Data("more".utf8)).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(Press.compress(planned, options: now), .skipped(.changed))
        XCTAssertFalse(try XCTUnwrap(Press.facts(path)).isCompressed)
        XCTAssertEqual(leftovers(), [])
    }

    // MARK: - Share

    func testShareMakesACloneAndKeepsTheMetadataOfTheCopy() throws {
        let data = random(200_000)
        let keeper = write("a/photo.jpg", data, mode: 0o644, attribute: "keeper", modified: Date(timeIntervalSince1970: 1_600_000_000))
        let copy = write("b/photo copy.jpg", data, mode: 0o600, attribute: "copy", modified: Date(timeIntervalSince1970: 1_650_000_000))
        let plain = write("b/plain.jpg", data, modified: Date(timeIntervalSince1970: 1_660_000_000))
        let created = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: copy)[.creationDate] as? Date)
        let k = try XCTUnwrap(Press.facts(keeper)), c = try XCTUnwrap(Press.facts(copy)), p = try XCTUnwrap(Press.facts(plain))
        XCTAssertNotEqual(Press.contentIdentifier(keeper), Press.contentIdentifier(copy))

        XCTAssertEqual(Press.share(copy: c, keeper: k, options: now), .saved(c.allocated))
        let after = try XCTUnwrap(Press.facts(copy))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy)), data)
        XCTAssertEqual(Press.contentIdentifier(keeper), Press.contentIdentifier(copy), "the two files share their data")
        XCTAssertEqual(after.mode, 0o600)
        XCTAssertEqual(after.modified, 1_650_000_000)
        XCTAssertEqual(attribute(copy), "copy")
        XCTAssertEqual(try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: copy)[.creationDate] as? Date).timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 0.001)
        // The keeper is not changed.
        XCTAssertEqual(try XCTUnwrap(Press.facts(keeper)), k)
        XCTAssertEqual(attribute(keeper), "keeper")

        // A copy with no attribute does not get the attribute of the keeper.
        XCTAssertEqual(Press.share(copy: p, keeper: k, options: now), .saved(p.allocated))
        XCTAssertNil(attribute(plain))

        // A change to the copy does not change the keeper.
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: copy))
        try handle.write(contentsOf: Data("changed".utf8))
        try handle.close()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: keeper)), data)
        XCTAssertEqual(leftovers(), [])
    }

    func testShareLeavesFilesThatAreNotTheSame() throws {
        let data = random(100_000)
        let keeper = write("one.bin", data), copy = write("two.bin", data)
        let k = try XCTUnwrap(Press.facts(keeper)), c = try XCTUnwrap(Press.facts(copy))
        XCTAssertEqual(Press.share(copy: c, keeper: k, options: now, open: [copy]), .skipped(.inUse))
        // The same size and the same dates, but one byte is different.
        var other = data
        other[500] ^= 0xff
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: copy))
        try handle.seek(toOffset: 500)
        try handle.write(contentsOf: other[500..<501])
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: c.modified + Double(c.modifiedNanos) / 1e9)], ofItemAtPath: copy)
        let outcome = Press.share(copy: try XCTUnwrap(Press.facts(copy)), keeper: k, options: now)
        XCTAssertEqual(outcome, .skipped(.changed))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy)), other)
        XCTAssertEqual(leftovers(), [])
    }

    // MARK: - Scan and apply

    func testScanAndApplyOnAFolder() throws {
        let photo = random(150_000)
        write("docs/a.txt", text)
        write("docs/b.txt", text, attribute: "b")
        write("docs/c.txt", text + Data("!".utf8))
        write("pics/one.jpg", photo)
        write("pics/two.jpg", photo)
        write("pics/three.jpg", random(150_000))
        write("app/data.sqlite", text)
        write(".git/objects/pack", text)
        write("tiny.txt", Data("hi".utf8))
        let linked = write("linked.txt", text + Data("linked".utf8))
        XCTAssertEqual(link(linked, (dir as NSString).appendingPathComponent("linked2.txt")), 0)
        XCTAssertEqual(symlink(linked, (dir as NSString).appendingPathComponent("alias.txt")), 0)

        let plan = Press.scan(root: dir, options: now)
        XCTAssertEqual(plan.files, 10, "the .git folder and the symbolic link are not counted")
        XCTAssertEqual(plan.skipped, [.liveData: 1, .small: 1, .hardLink: 2])
        XCTAssertEqual(plan.groups.count, 2)
        XCTAssertEqual(plan.shareCount, 2)
        // a.txt keeps the data and is compressed; b.txt becomes its clone; c.txt is compressed.
        XCTAssertEqual(Set(plan.compress.map { ($0.path as NSString).lastPathComponent }), ["a.txt", "c.txt"])
        XCTAssertGreaterThan(plan.compressSaving, 200_000)
        XCTAssertEqual(plan.shareSaving, plan.groups.reduce(0) { $0 + $1.saving })
        XCTAssertTrue(Press.describe(plan).contains("Compress 2 files"))

        var changes: [Press.Change] = []
        let report = Press.apply(plan, options: now, open: { [] }, onChange: { changes.append($0) })
        XCTAssertEqual(report.compressed, 2)
        XCTAssertEqual(report.shared, 2)
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertEqual(changes.count, 4)
        XCTAssertGreaterThan(report.saved, 400_000)

        // The content of each file is as it was.
        let read = { (name: String) in try Data(contentsOf: URL(fileURLWithPath: (self.dir as NSString).appendingPathComponent(name))) }
        XCTAssertEqual(try read("docs/a.txt"), text)
        XCTAssertEqual(try read("docs/b.txt"), text)
        XCTAssertEqual(try read("docs/c.txt"), text + Data("!".utf8))
        XCTAssertEqual(try read("pics/one.jpg"), photo)
        XCTAssertEqual(try read("pics/two.jpg"), photo)
        XCTAssertEqual(try read("app/data.sqlite"), text)
        XCTAssertEqual(try read(".git/objects/pack"), text)
        let b = (dir as NSString).appendingPathComponent("docs/b.txt")
        XCTAssertEqual(attribute(b), "b")
        XCTAssertTrue(try XCTUnwrap(Press.facts(b)).isCompressed, "the clone of a compressed keeper is compressed")
        XCTAssertFalse(try XCTUnwrap(Press.facts((dir as NSString).appendingPathComponent("app/data.sqlite"))).isCompressed)
        XCTAssertEqual(leftovers(), [])

        // A second scan finds nothing to do.
        let again = Press.scan(root: dir, options: now)
        XCTAssertTrue(again.isEmpty, Press.describe(again))
        XCTAssertEqual(again.alreadyShared, 2)
        XCTAssertEqual(again.alreadyCompressed, 3)
    }

    func testALargeFileWithTextOnlyAtTheStartIsNotInThePlan() throws {
        // The start compresses well, but the file as a whole does not.
        write("model.safetensors", Data(String(repeating: "{\"layer\": 1}", count: 8000).utf8) + random(6_000_000))
        write("big.txt", Data(String(repeating: "All work and no play makes Jack a dull boy.\n", count: 140_000).utf8))
        let plan = Press.scan(root: dir, options: now)
        XCTAssertEqual(plan.compress.map { ($0.path as NSString).lastPathComponent }, ["big.txt"])
        XCTAssertEqual(plan.noGain, 1)
        XCTAssertGreaterThan(plan.compressSaving, 5_000_000)
        XCTAssertLessThan(plan.compressSaving, 6_200_000)
        XCTAssertTrue(Press.describe(plan).contains("1 large files that compression does not make smaller"))
    }

    func testApplyStopsWhenCancelled() {
        write("a.txt", text)
        write("b.txt", text + Data("b".utf8))
        let plan = Press.scan(root: dir, options: now)
        XCTAssertEqual(plan.compress.count, 2)
        var done = 0
        let report = Press.apply(plan, options: now, open: { [] }, isCancelled: { done >= 1 }, onChange: { _ in done += 1 })
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.compressed, 1)
    }

    func testOpenFilesHasAFileThatThisProcessHoldsOpen() throws {
        let path = write("held.txt", text)
        let real = try XCTUnwrap(realpath(path, nil)).withMemoryRebound(to: CChar.self, capacity: 1) { pointer -> String in defer { free(pointer) }; return String(cString: pointer) }
        let handle = try XCTUnwrap(FileHandle(forReadingAtPath: path))
        XCTAssertTrue(Press.openFiles().contains(real))
        try handle.close()
        XCTAssertFalse(Press.openFiles().contains(real))
    }
}
