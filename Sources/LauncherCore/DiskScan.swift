import Foundation

/// The result of a disk scan: one node for each file and folder, in flat arrays indexed
/// by node id. Node 0 is the root. The children of a folder have consecutive ids, and a
/// child always has a larger id than its parent.
public final class DiskTree {
    public struct Flags: OptionSet {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let directory = Flags(rawValue: 1)
        /// The folder could not be opened, so its size is not known.
        public static let denied = Flags(rawValue: 2)
        /// The folder is on another volume and was not scanned.
        public static let mount = Flags(rawValue: 4)
        /// An iCloud folder that is not on this Mac. Reading it would download it.
        public static let dataless = Flags(rawValue: 8)
        /// Moved to the Trash after the scan.
        public static let removed = Flags(rawValue: 16)
    }

    public let rootPath: String
    public fileprivate(set) var parent: [Int32] = []
    public fileprivate(set) var childStart: [Int32] = []
    public fileprivate(set) var childCount: [Int32] = []
    /// Allocated bytes. For a folder: the sum of everything below it.
    public fileprivate(set) var size: [UInt64] = []
    public fileprivate(set) var flags: [UInt8] = []
    /// Index into `extensions`; 0 is "no extension".
    public fileprivate(set) var ext: [UInt16] = []
    public fileprivate(set) var extensions: [String] = [""]
    public fileprivate(set) var fileCount = 0
    public fileprivate(set) var deniedCount = 0
    fileprivate var nameOffset: [UInt32] = []
    fileprivate var nameLength: [UInt16] = []
    fileprivate var names: [UInt8] = []

    init(rootPath: String) { self.rootPath = rootPath }

    public var count: Int { parent.count }

    public func isDirectory(_ node: Int32) -> Bool { flags[Int(node)] & Flags.directory.rawValue != 0 }
    public func has(_ flag: Flags, _ node: Int32) -> Bool { flags[Int(node)] & flag.rawValue != 0 }

    public func children(of node: Int32) -> Range<Int32> {
        let start = childStart[Int(node)]
        return start ..< start + childCount[Int(node)]
    }

    public func name(of node: Int32) -> String {
        if node == 0 { return (rootPath as NSString).lastPathComponent }
        let start = Int(nameOffset[Int(node)])
        return String(decoding: names[start ..< start + Int(nameLength[Int(node)])], as: UTF8.self)
    }

    public func path(of node: Int32) -> String {
        var parts: [String] = []
        var n = node
        while n > 0 {
            parts.append(name(of: n))
            n = parent[Int(n)]
        }
        if parts.isEmpty { return rootPath }
        return (rootPath == "/" ? "" : rootPath) + "/" + parts.reversed().joined(separator: "/")
    }

    /// True when `ancestor` is `node` or a folder above it.
    public func isAncestor(_ ancestor: Int32, of node: Int32) -> Bool {
        var n = node
        while n >= 0 {
            if n == ancestor { return true }
            n = parent[Int(n)]
        }
        return false
    }

    /// The bytes of the files of each extension, largest first.
    public func extensionTotals() -> [(ext: UInt16, bytes: UInt64)] {
        var totals = [UInt64](repeating: 0, count: extensions.count)
        for i in 0 ..< count where flags[i] & Flags.directory.rawValue == 0 {
            totals[Int(ext[i])] += size[i]
        }
        return totals.enumerated().filter { $0.element > 0 }
            .map { (ext: UInt16($0.offset), bytes: $0.element) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// Takes a node out of the totals (after it went to the Trash). The node stays in the
    /// arrays with size 0, so the ids of the other nodes do not change.
    public func remove(_ node: Int32) {
        guard node > 0 else { return }
        let bytes = size[Int(node)]
        var n = node
        while n >= 0 {
            size[Int(n)] -= min(bytes, size[Int(n)])
            n = parent[Int(n)]
        }
        flags[Int(node)] |= Flags.removed.rawValue
    }

    fileprivate func append(parent p: Int32, name: UnsafeRawBufferPointer, size s: UInt64, flags f: UInt8, ext e: UInt16) -> Int32 {
        let id = Int32(parent.count)
        parent.append(p)
        childStart.append(0)
        childCount.append(0)
        size.append(s)
        flags.append(f)
        ext.append(e)
        nameOffset.append(UInt32(names.count))
        nameLength.append(UInt16(min(name.count, Int(UInt16.max))))
        names.append(contentsOf: name)
        return id
    }
}

/// Walks one volume below `root` with `getattrlistbulk` and builds a `DiskTree`.
///
/// - Sizes are allocated bytes, so a sparse file or an iCloud file that is not downloaded
///   counts as what it uses on this disk. Only attributes are read; nothing downloads.
/// - A file with several hard links counts one time.
/// - Symbolic links are not followed, and a folder on another volume is not entered.
public final class DiskScanner {
    public struct Progress {
        public var files = 0
        public var bytes: UInt64 = 0
        public var path = ""
    }

    public let root: String
    private let workers: Int
    private let cond = NSCondition()
    private var queue: [(node: Int32, path: String)] = []
    private var active = 0
    private var cancelled = false
    private var tree: DiskTree
    private var seenLinks = Set<UInt64>()
    private var extensionIds: [UInt64: UInt16] = [:]
    private var current = Progress()
    private var rootDevice: dev_t = 0

    public init(root: String, workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        var path = root
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        self.root = path
        self.workers = max(1, workers)
        tree = DiskTree(rootPath: path)
    }

    public var progress: Progress {
        cond.lock()
        defer { cond.unlock() }
        return current
    }

    public var isCancelled: Bool {
        cond.lock()
        defer { cond.unlock() }
        return cancelled
    }

    public func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    /// Blocks until the walk is complete or cancelled. Returns nil when the root is not a
    /// folder that can be read. Call it one time.
    public func run() -> DiskTree? {
        var st = stat()
        guard stat(root, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        let fd = open(root, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return nil }
        close(fd)
        rootDevice = st.st_dev

        _ = [UInt8]().withUnsafeBytes { tree.append(parent: -1, name: $0, size: 0, flags: DiskTree.Flags.directory.rawValue, ext: 0) }
        queue = [(0, root)]
        DispatchQueue.concurrentPerform(iterations: workers) { _ in work() }

        // A child has a larger id than its parent, so one pass from the end sums every folder.
        var i = tree.count - 1
        while i > 0 {
            tree.size[Int(tree.parent[i])] += tree.size[i]
            i -= 1
        }
        return tree
    }

    // MARK: - Workers

    private enum Status { case ok, denied, mount, gone }

    /// What one worker read from one folder, before it goes into the tree.
    private struct Batch {
        var names: [UInt8] = []
        var nameLengths: [Int] = []
        var sizes: [UInt64] = []
        var flags: [UInt8] = []
        var extKeys: [UInt64] = []
        /// The file id of a file with more than one hard link; 0 for the others.
        var linkIds: [UInt64] = []
        var folders: [(index: Int, path: String)] = []

        mutating func removeAll() {
            names.removeAll(keepingCapacity: true)
            nameLengths.removeAll(keepingCapacity: true)
            sizes.removeAll(keepingCapacity: true)
            flags.removeAll(keepingCapacity: true)
            extKeys.removeAll(keepingCapacity: true)
            linkIds.removeAll(keepingCapacity: true)
            folders.removeAll(keepingCapacity: true)
        }
    }

    private static let bufferSize = 256 * 1024

    private func work() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var batch = Batch()
        while true {
            cond.lock()
            while queue.isEmpty, active > 0, !cancelled { cond.wait() }
            if queue.isEmpty || cancelled {
                cond.broadcast()
                cond.unlock()
                return
            }
            let item = queue.removeLast()
            active += 1
            cond.unlock()

            batch.removeAll()
            let status = read(item.path, into: &batch, buffer: buffer)

            cond.lock()
            commit(batch, to: item.node, path: item.path, status: status)
            active -= 1
            cond.broadcast()
            cond.unlock()
        }
    }

    /// Called with the lock held.
    private func commit(_ batch: Batch, to node: Int32, path: String, status: Status) {
        switch status {
        case .denied:
            tree.flags[Int(node)] |= DiskTree.Flags.denied.rawValue
            tree.deniedCount += 1
        case .mount:
            tree.flags[Int(node)] |= DiskTree.Flags.mount.rawValue
        case .ok, .gone:
            break
        }
        let n = batch.sizes.count
        guard n > 0 else { return }
        tree.childStart[Int(node)] = Int32(tree.count)
        tree.childCount[Int(node)] = Int32(n)
        var folder = 0
        var offset = 0
        batch.names.withUnsafeBytes { names in
            for i in 0 ..< n {
                var bytes = batch.sizes[i]
                let link = batch.linkIds[i]
                if link != 0, !seenLinks.insert(link).inserted { bytes = 0 }
                var extId: UInt16 = 0
                let key = batch.extKeys[i]
                if key != 0 {
                    if let known = extensionIds[key] {
                        extId = known
                    } else if tree.extensions.count < Int(UInt16.max) {
                        extId = UInt16(tree.extensions.count)
                        extensionIds[key] = extId
                        tree.extensions.append(Self.extensionName(key))
                    }
                }
                let length = batch.nameLengths[i]
                let id = tree.append(parent: node, name: UnsafeRawBufferPointer(rebasing: names[offset ..< offset + length]),
                                     size: bytes, flags: batch.flags[i], ext: extId)
                offset += length
                if batch.flags[i] & DiskTree.Flags.directory.rawValue != 0 {
                    if batch.flags[i] & DiskTree.Flags.dataless.rawValue == 0 {
                        queue.append((id, batch.folders[folder].path))
                    }
                    folder += 1
                } else {
                    current.files += 1
                    current.bytes += bytes
                }
            }
        }
        tree.fileCount = current.files
        current.path = path
    }

    // Attribute bits, as plain numbers: the SDK imports them with mixed integer types.
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnFileId: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let typeDirectory: UInt32 = 2
    private static let datalessFlag: UInt32 = 0x4000_0000

    private func read(_ path: String, into batch: inout Batch, buffer: UnsafeMutableRawPointer) -> Status {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return errno == EACCES || errno == EPERM ? .denied : .gone }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) == 0, st.st_dev != rootDevice { return .mount }

        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = Self.cmnReturnedAttrs | Self.cmnName | Self.cmnError | Self.cmnObjType | Self.cmnFlags | Self.cmnFileId
        list.fileattr = Self.fileLinkCount | Self.fileAllocSize
        let prefix = path == "/" ? "/" : path + "/"

        while true {
            let count = getattrlistbulk(fd, &list, buffer, Self.bufferSize, 0)
            if count <= 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0 ..< count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                entry += length

                var error: UInt32 = 0
                if returned.commonattr & Self.cmnError != 0 {
                    error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                guard returned.commonattr & Self.cmnName != 0 else { continue }
                let ref = field.loadUnaligned(as: attrreference_t.self)
                let name = UnsafeRawBufferPointer(start: field + Int(ref.attr_dataoffset), count: max(0, Int(ref.attr_length) - 1))
                field += MemoryLayout<attrreference_t>.size
                var type: UInt32 = 0
                if returned.commonattr & Self.cmnObjType != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var bsdFlags: UInt32 = 0
                if returned.commonattr & Self.cmnFlags != 0 {
                    bsdFlags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var fileId: UInt64 = 0
                if returned.commonattr & Self.cmnFileId != 0 {
                    fileId = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                var links: UInt32 = 1
                if returned.fileattr & Self.fileLinkCount != 0 {
                    links = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var allocated: Int64 = 0
                if returned.fileattr & Self.fileAllocSize != 0 {
                    allocated = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                if error != 0, type == 0 { continue }

                batch.names.append(contentsOf: name)
                batch.nameLengths.append(name.count)
                if type == Self.typeDirectory {
                    var flags = DiskTree.Flags.directory.rawValue
                    if bsdFlags & Self.datalessFlag != 0 { flags |= DiskTree.Flags.dataless.rawValue }
                    batch.flags.append(flags)
                    batch.sizes.append(0)
                    batch.extKeys.append(0)
                    batch.linkIds.append(0)
                    batch.folders.append((batch.sizes.count - 1, prefix + String(decoding: name, as: UTF8.self)))
                } else {
                    batch.flags.append(0)
                    batch.sizes.append(UInt64(max(0, allocated)))
                    batch.extKeys.append(Self.extensionKey(name))
                    batch.linkIds.append(links > 1 ? fileId : 0)
                }
            }
        }
        return .ok
    }

    // MARK: - Extensions

    /// The extension of a file name packed into a number: up to 12 ASCII letters and
    /// digits after the last dot, in lower case, as base-37 digits (37¹² fits in 64 bits).
    /// 0 when the name has no such extension.
    static func extensionKey(_ name: UnsafeRawBufferPointer) -> UInt64 {
        var i = name.count - 1
        var key: UInt64 = 0
        var place: UInt64 = 1
        var length = 0
        while i > 0 {
            var c = name[i]
            if c == UInt8(ascii: ".") { return length > 0 ? key : 0 }
            if c >= UInt8(ascii: "A"), c <= UInt8(ascii: "Z") { c += 32 }
            let digit: UInt64
            if c >= UInt8(ascii: "a"), c <= UInt8(ascii: "z") {
                digit = UInt64(c - UInt8(ascii: "a")) + 1
            } else if c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") {
                digit = UInt64(c - UInt8(ascii: "0")) + 27
            } else {
                return 0
            }
            guard length < 12 else { return 0 }
            // The last character of the extension is the lowest digit.
            key += digit * place
            if length < 11 { place *= 37 }
            length += 1
            i -= 1
        }
        return 0
    }

    static func extensionName(_ key: UInt64) -> String {
        var bytes: [UInt8] = []
        var k = key
        while k != 0 {
            let digit = UInt8(k % 37)
            bytes.append(digit <= 26 ? UInt8(ascii: "a") + digit - 1 : UInt8(ascii: "0") + digit - 27)
            k /= 37
        }
        return String(decoding: bytes.reversed(), as: UTF8.self)
    }
}
