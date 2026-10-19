import XCTest
@testable import LauncherCore

final class TreemapTests: XCTestCase {
    private let bounds: Treemap.Rect = (10, 20, 600, 400)

    func testAreasAreProportionalAndFillTheBounds() {
        let sizes: [Double] = [500, 300, 120, 50, 20, 6, 3, 1]
        let rects = Treemap.squarify(sizes, in: bounds)
        XCTAssertEqual(rects.count, sizes.count)
        let total = sizes.reduce(0, +)
        for (size, r) in zip(sizes, rects) {
            XCTAssertEqual(r.w * r.h, size / total * bounds.w * bounds.h, accuracy: bounds.w * bounds.h * 0.0001)
            XCTAssertGreaterThanOrEqual(r.x, bounds.x - 1e-6)
            XCTAssertGreaterThanOrEqual(r.y, bounds.y - 1e-6)
            XCTAssertLessThanOrEqual(r.x + r.w, bounds.x + bounds.w + 1e-6)
            XCTAssertLessThanOrEqual(r.y + r.h, bounds.y + bounds.h + 1e-6)
        }
        XCTAssertEqual(rects.reduce(0) { $0 + $1.w * $1.h }, bounds.w * bounds.h, accuracy: 0.01)
    }

    func testRectanglesDoNotOverlap() {
        let rects = Treemap.squarify((1 ... 40).reversed().map(Double.init), in: bounds)
        for a in rects.indices {
            for b in rects.indices where b > a {
                let ox = min(rects[a].x + rects[a].w, rects[b].x + rects[b].w) - max(rects[a].x, rects[b].x)
                let oy = min(rects[a].y + rects[a].h, rects[b].y + rects[b].h) - max(rects[a].y, rects[b].y)
                XCTAssertFalse(ox > 1e-6 && oy > 1e-6, "\(a) and \(b) overlap")
            }
        }
    }

    func testEqualSizesAreNearSquare() {
        for r in Treemap.squarify([Double](repeating: 1, count: 6), in: (0, 0, 600, 400)) {
            XCTAssertLessThan(max(r.w / r.h, r.h / r.w), 1.6)
        }
    }

    func testOneItemAndNoItems() {
        let one = Treemap.squarify([7], in: bounds)
        XCTAssertEqual(one[0].w, bounds.w)
        XCTAssertEqual(one[0].h, bounds.h)
        XCTAssertTrue(Treemap.squarify([], in: bounds).isEmpty)
    }
}

final class DiskScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kea-diskscan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        chmod(root.appendingPathComponent("locked").path, 0o755)
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    private func node(_ tree: DiskTree, _ path: String) -> Int32? {
        (0 ..< Int32(tree.count)).first { tree.path(of: $0) == tree.rootPath + "/" + path }
    }

    private func scan() throws -> DiskTree {
        try XCTUnwrap(DiskScanner(root: root.path, workers: 4).run())
    }

    func testSizesAddUp() throws {
        try write("a/one.bin", bytes: 300_000)
        try write("a/deep/two.TXT", bytes: 100_000)
        try write("b/three.txt", bytes: 50_000)
        let tree = try scan()
        let a = try XCTUnwrap(node(tree, "a")), one = try XCTUnwrap(node(tree, "a/one.bin"))
        let deep = try XCTUnwrap(node(tree, "a/deep")), two = try XCTUnwrap(node(tree, "a/deep/two.TXT"))
        XCTAssertGreaterThanOrEqual(tree.size[Int(one)], 300_000)
        XCTAssertLessThan(tree.size[Int(one)], 400_000)
        XCTAssertEqual(tree.size[Int(deep)], tree.size[Int(two)])
        XCTAssertEqual(tree.size[Int(a)], tree.size[Int(one)] + tree.size[Int(two)])
        XCTAssertEqual(tree.size[0], tree.children(of: 0).reduce(0) { $0 + tree.size[Int($1)] })
        XCTAssertEqual(tree.fileCount, 3)
        XCTAssertTrue(tree.isDirectory(a))
        XCTAssertFalse(tree.isDirectory(one))
        XCTAssertTrue(tree.isAncestor(a, of: two))
        XCTAssertFalse(tree.isAncestor(deep, of: one))
        // Extensions are folded to lower case and shared.
        XCTAssertEqual(tree.extensions[Int(tree.ext[Int(two)])], "txt")
        XCTAssertEqual(tree.ext[Int(two)], tree.ext[Int(try XCTUnwrap(node(tree, "b/three.txt")))])
        XCTAssertEqual(tree.extensionTotals().first?.ext, tree.ext[Int(one)])
    }

    func testHardLinkCountsOneTime() throws {
        try write("big.bin", bytes: 200_000)
        try FileManager.default.linkItem(at: root.appendingPathComponent("big.bin"), to: root.appendingPathComponent("again.bin"))
        let tree = try scan()
        XCTAssertGreaterThanOrEqual(tree.size[0], 200_000)
        XCTAssertLessThan(tree.size[0], 300_000)
    }

    func testSymbolicLinkIsNotFollowed() throws {
        try write("real/big.bin", bytes: 200_000)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("real"))
        let tree = try scan()
        let link = try XCTUnwrap(node(tree, "link"))
        XCTAssertFalse(tree.isDirectory(link))
        XCTAssertLessThan(tree.size[Int(link)], 10_000)
        XCTAssertLessThan(tree.size[0], 300_000)
    }

    func testSparseFileCountsAllocatedBlocks() throws {
        let path = root.appendingPathComponent("sparse.img").path
        let fd = open(path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        ftruncate(fd, 500_000_000)
        close(fd)
        let tree = try scan()
        XCTAssertLessThan(tree.size[0], 1_000_000)
    }

    func testFolderWithoutPermissionIsDenied() throws {
        try write("locked/secret.bin", bytes: 50_000)
        try write("open/file.bin", bytes: 50_000)
        chmod(root.appendingPathComponent("locked").path, 0)
        let tree = try scan()
        let locked = try XCTUnwrap(node(tree, "locked"))
        XCTAssertTrue(tree.has(.denied, locked))
        XCTAssertEqual(tree.size[Int(locked)], 0)
        XCTAssertEqual(tree.deniedCount, 1)
        XCTAssertGreaterThanOrEqual(tree.size[0], 50_000)
    }

    func testRootThatIsNotAFolder() throws {
        XCTAssertNil(DiskScanner(root: root.path + "/missing").run())
        try write("file.bin", bytes: 10)
        XCTAssertNil(DiskScanner(root: root.path + "/file.bin").run())
    }

    func testCancelStopsTheWalk() throws {
        for i in 0 ..< 30 { try write("d\(i)/f.bin", bytes: 10) }
        let scanner = DiskScanner(root: root.path, workers: 2)
        scanner.cancel()
        let tree = try XCTUnwrap(scanner.run())
        XCTAssertTrue(scanner.isCancelled)
        XCTAssertEqual(tree.fileCount, 0)
    }

    func testRemoveTakesTheSizeFromEveryAncestor() throws {
        try write("a/deep/two.bin", bytes: 100_000)
        try write("a/one.bin", bytes: 300_000)
        let tree = try scan()
        let deep = try XCTUnwrap(node(tree, "a/deep")), one = try XCTUnwrap(node(tree, "a/one.bin"))
        tree.remove(deep)
        XCTAssertEqual(tree.size[Int(deep)], 0)
        XCTAssertTrue(tree.has(.removed, deep))
        XCTAssertEqual(tree.size[0], tree.size[Int(one)])
    }

    func testExtensionKey() {
        func ext(_ name: String) -> String {
            Array(name.utf8).withUnsafeBytes { DiskScanner.extensionName(DiskScanner.extensionKey($0)) }
        }
        XCTAssertEqual(ext("Photo.JPG"), "jpg")
        XCTAssertEqual(ext("archive.tar.gz"), "gz")
        XCTAssertEqual(ext(".bashrc"), "")
        XCTAssertEqual(ext("Makefile"), "")
        XCTAssertEqual(ext("name.with space"), "")
        XCTAssertEqual(ext("model.safetensors"), "safetensors")
        XCTAssertEqual(ext("a.zzzzzzzzzzzz"), "zzzzzzzzzzzz")
        XCTAssertEqual(ext("v.0a9"), "0a9")
        XCTAssertEqual(ext("x.verylongextension"), "")
        XCTAssertEqual(ext("trailing."), "")
    }

    // MARK: - Layout over a scanned tree

    func testLayoutCoversTheAreaWithoutOverlap() throws {
        // A file of 10 bytes uses one 4 KB block, so the large files must be much larger.
        try write("a/one.bin", bytes: 8_000_000)
        try write("a/two.bin", bytes: 6_000_000)
        try write("b/three.bin", bytes: 4_000_000)
        for i in 0 ..< 40 { try write("tiny/t\(i).bin", bytes: 10) }
        let tree = try scan()
        let layout = Treemap.layout(tree, root: 0, width: 100, height: 50)
        var hits = [UInt8](repeating: 0, count: 100 * 50)
        for c in layout.cells {
            let p = c.pixels
            for y in p.y0 ..< p.y1 { for x in p.x0 ..< p.x1 { hits[y * 100 + x] += 1 } }
        }
        XCTAssertTrue(hits.allSatisfy { $0 == 1 }, "every pixel belongs to exactly one block")
        // The 40 tiny files are too small to draw one by one.
        XCTAssertTrue(layout.cells.contains { $0.kind == .small || $0.kind == .folder })
        XCTAssertFalse(layout.cells.contains { $0.kind == .file && tree.name(of: tree.parent[Int($0.node)]) == "tiny" })

        let one = try XCTUnwrap(node(tree, "a/one.bin"))
        let rect = try XCTUnwrap(layout.rect(of: one))
        let hit = try XCTUnwrap(layout.cell(atX: Int(rect.x + rect.w / 2), y: Int(rect.y + rect.h / 2)))
        XCTAssertEqual(layout.cells[hit].node, one)
        XCTAssertNotNil(layout.rect(of: try XCTUnwrap(node(tree, "a"))))

        let pixels = Treemap.render(layout, colors: [UInt32](repeating: 0x4E79A7, count: layout.cells.count))
        XCTAssertEqual(pixels.count, 100 * 50 * 4)
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
    }

    func testFreeSpaceIsOneFlatHatchedBlock() throws {
        try write("a/one.bin", bytes: 3_000_000)
        try write("b/two.bin", bytes: 1_000_000)
        let tree = try scan()
        let layout = Treemap.layout(tree, root: 0, width: 200, height: 100, free: tree.size[0])
        let free = layout.cells.filter { $0.kind == .free }
        XCTAssertEqual(free.count, 1)
        XCTAssertEqual(free[0].node, -1)
        // Free space equals used space here, so it gets half of the area.
        XCTAssertEqual(free[0].w * free[0].h, 200 * 100 / 2, accuracy: 1)
        var hits = [UInt8](repeating: 0, count: 200 * 100)
        for c in layout.cells {
            let p = c.pixels
            for y in p.y0 ..< p.y1 { for x in p.x0 ..< p.x1 { hits[y * 200 + x] += 1 } }
        }
        XCTAssertTrue(hits.allSatisfy { $0 == 1 })

        let pixels = Treemap.render(layout, colors: layout.cells.map { $0.kind == .free ? 0xE0E0E0 : 0x4E79A7 })
        let p = free[0].pixels
        var shades = Set<UInt8>()
        for y in p.y0 ..< p.y1 { for x in p.x0 ..< p.x1 { shades.insert(pixels[(y * 200 + x) * 4]) } }
        XCTAssertEqual(shades, [0xE0, UInt8(Double(0xE0) * 0.84)], "flat color and one darker line color")
        // Without free space the files fill the whole area.
        XCTAssertFalse(Treemap.layout(tree, root: 0, width: 200, height: 100).cells.contains { $0.kind == .free })
    }

    func testLayoutOfAnEmptyFolder() throws {
        let tree = try scan()
        XCTAssertTrue(Treemap.layout(tree, root: 0, width: 100, height: 100).cells.isEmpty)
    }
}
