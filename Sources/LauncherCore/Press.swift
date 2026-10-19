import CryptoKit
import Darwin
import Foundation

/// The engine behind `press`: it frees disk space in a folder and deletes nothing.
///
/// Two changes, both invisible to the apps that read the files:
/// - **Compress**: a file gets APFS transparent compression. Apple's `ditto` writes a
///   compressed copy next to the file, Kea compares the copy with the file byte for byte,
///   and the copy then takes the place of the file in one atomic rename.
/// - **Share**: a file that has the same content as a different file becomes an APFS clone
///   of it. The two paths stay, each with its own name, dates, mode, and attributes, but
///   the data is on the disk one time. A later change to one file does not change the other.
///
/// A file is left alone when a change could lose data or cost more than it saves: see `Skip`.
public enum Press {
    // MARK: - Rules

    /// Why a file is not changed. The raw value is the text for a person.
    public enum Skip: String, CaseIterable, Sendable {
        case small = "too small"
        case recent = "changed in the last day"
        case hardLink = "has more than one hard link"
        case notOwner = "owned by a different user"
        case locked = "locked or has special flags"
        case dataless = "not downloaded (cloud only)"
        case liveData = "a database, disk image, or other file that an app can write at any time"
        case resourceFork = "has a resource fork"
        case inUse = "open in an app"
        case changed = "changed during the work"
    }

    public struct Options: Sendable {
        /// A smaller file does not use less space after compression.
        public var minCompressBytes: Int64 = 4096
        /// A smaller file is one block, and a clone saves only that block.
        public var minShareBytes: Int64 = 4096
        /// A file that changed this short a time ago can be in use.
        public var minAge: TimeInterval = 86400
        /// The files whose first bytes give the estimate of the compression.
        public var sampleFiles = 1500
        public init() {}
    }

    /// The facts of one file that the rules use. A test can make one with no file.
    public struct Facts: Sendable, Equatable {
        public var path: String
        public var size: Int64
        /// The space on the disk, in bytes.
        public var allocated: Int64
        public var modified: TimeInterval
        public var modifiedNanos: Int
        public var inode: UInt64
        public var device: Int32
        public var links: Int
        public var flags: UInt32
        public var owner: UInt32
        public var mode: UInt16

        public init(path: String, size: Int64, allocated: Int64, modified: TimeInterval, modifiedNanos: Int = 0, inode: UInt64 = 0, device: Int32 = 0,
                    links: Int = 1, flags: UInt32 = 0, owner: UInt32 = getuid(), mode: UInt16 = 0o644) {
            self.path = path; self.size = size; self.allocated = allocated; self.modified = modified; self.modifiedNanos = modifiedNanos
            self.inode = inode; self.device = device; self.links = links; self.flags = flags; self.owner = owner; self.mode = mode
        }

        public var isCompressed: Bool { flags & Press.compressedFlag != 0 }
        var ext: String { (path as NSString).pathExtension.lowercased() }
    }

    static let compressedFlag = UInt32(UF_COMPRESSED)
    static let datalessFlag = UInt32(bitPattern: Int32(SF_DATALESS))
    /// Flags that a pressed file can have. A file with a different flag (locked, append only, …) is left alone.
    static let plainFlags = UInt32(UF_COMPRESSED) | UInt32(UF_HIDDEN) | UInt32(UF_TRACKED)

    /// Formats that already are compressed: compression gains nothing. They can still be shared.
    public static let compressedFormats: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "jxl", "mp3", "m4a", "aac", "flac", "ogg", "opus",
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "zip", "gz", "tgz", "bz2", "xz", "zst", "lz4", "br", "7z", "rar", "jar", "war",
        "apk", "ipa", "pkg", "docx", "xlsx", "pptx", "epub", "pdf", "woff", "woff2", "whl", "nupkg", "crx", "xpi",
    ]

    /// Files that an app can write at any time, with no change of the date first. A replaced
    /// file here can lose what the app writes next, so neither change is made.
    public static let liveFormats: Set<String> = [
        "sqlite", "sqlite3", "db", "db3", "wal", "shm", "sqlite-wal", "sqlite-shm", "db-wal", "db-shm", "sqlitedb", "realm", "mdb", "ldb", "lock", "pid",
        "sock", "log", "dmg", "sparseimage", "img", "iso", "vmdk", "vdi", "vhd", "vhdx", "qcow2", "hdd", "raw",
        "part", "crdownload", "download", "partial", "tmp", "swp", "journal",
    ]

    /// Folders that the scan does not enter: version control data, the Trash, and
    /// packages that hold a live library or a virtual machine.
    public static func skipsFolder(named name: String) -> Bool {
        if [".git", ".hg", ".svn", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems"].contains(name) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["photoslibrary", "musiclibrary", "tvlibrary", "aplibrary", "sparsebundle", "vmwarevm", "pvm", "utm", "parallels", "backupbundle", "noindex"].contains(ext)
    }

    /// The reason that neither change is made to a file, or nil.
    public static func skip(_ f: Facts, options: Options = Options(), now: Date = Date(), user: UInt32 = getuid()) -> Skip? {
        if f.flags & datalessFlag != 0 { return .dataless }
        if f.owner != user { return .notOwner }
        if f.flags & ~(plainFlags | datalessFlag) != 0 { return .locked }
        if f.links > 1 { return .hardLink }
        if liveFormats.contains(f.ext) || f.path.hasSuffix("-wal") || f.path.hasSuffix("-shm") || f.path.hasSuffix("-journal") { return .liveData }
        if now.timeIntervalSince1970 - f.modified < options.minAge { return .recent }
        if f.size < min(options.minCompressBytes, options.minShareBytes) { return .small }
        return nil
    }

    /// True if compression can gain space for the file. Call it only when `skip` gave nil.
    public static func canCompress(_ f: Facts, options: Options = Options()) -> Bool {
        // The file system keeps the size of a compressed file in 32 bits.
        !f.isCompressed && f.size >= options.minCompressBytes && f.size < 2_000_000_000 && !compressedFormats.contains(f.ext)
    }

    public static func canShare(_ f: Facts, options: Options = Options()) -> Bool { f.size >= options.minShareBytes }

    /// The reason that Kea does not press a folder, or nil. Only folders of the user and
    /// installed apps are permitted, and never the Library, where apps keep live data.
    public static func refusal(root: String, home: String) -> String? {
        let path = URL(fileURLWithPath: root).standardizedFileURL.path
        let inside = { (dir: String) in path == dir || path.hasPrefix(dir + "/") }
        if path == home { return "Select a folder inside your home folder, not the home folder itself" }
        if inside(home + "/Library") { return "Kea does not press the Library folder: apps keep live data there" }
        if inside(home + "/.Trash") { return "Kea does not press the Trash" }
        // The temporary folders are here for tests. Foundation gives them with and without "/private".
        let temporary = ["/private/tmp", "/tmp", "/private/var/folders", "/var/folders"]
        if inside(home) || inside("/Applications") || temporary.contains(where: inside) { return nil }
        return "Kea presses only folders inside your home folder and /Applications"
    }

    // MARK: - Plan

    public struct Group: Sendable {
        /// The file that keeps the data.
        public var keeper: Facts
        /// Files with the same content. Each becomes a clone of the keeper.
        public var copies: [Facts]
        public var saving: Int64 { copies.reduce(0) { $0 + $1.allocated } }
    }

    public struct Plan: Sendable {
        public var root: String
        public var files = 0
        public var bytes: Int64 = 0
        public var compress: [Facts] = []
        /// The estimate of the space that compression frees, from the first bytes of a sample of the files.
        public var compressSaving: Int64 = 0
        public var groups: [Group] = []
        /// Large files that compression does not make smaller. They are not in `compress`.
        public var noGain = 0
        public var alreadyCompressed = 0
        /// Copies that already share their data with a different file.
        public var alreadyShared = 0
        public var skipped: [Skip: Int] = [:]
        public var cloudFolders = 0

        public var shareCount: Int { groups.reduce(0) { $0 + $1.copies.count } }
        public var shareSaving: Int64 { groups.reduce(0) { $0 + $1.saving } }
        public var saving: Int64 { compressSaving + shareSaving }
        public var isEmpty: Bool { compress.isEmpty && groups.isEmpty }
    }

    public static func facts(_ path: String) -> Facts? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return Facts(path: path, size: Int64(st.st_size), allocated: Int64(st.st_blocks) * 512, modified: TimeInterval(st.st_mtimespec.tv_sec),
                     modifiedNanos: st.st_mtimespec.tv_nsec, inode: UInt64(st.st_ino), device: st.st_dev, links: Int(st.st_nlink), flags: st.st_flags,
                     owner: st.st_uid, mode: UInt16(st.st_mode & 0o7777))
    }

    /// Reads the folder and decides what to change. It changes nothing. It reads the full
    /// content only of files that have the same size as a different file.
    public static func scan(root: String, options: Options = Options(), now: Date = Date(), isCancelled: () -> Bool = { false }) -> Plan {
        var plan = Plan(root: root)
        var shareable: [Int64: [Facts]] = [:]
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { return plan }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return plan }
        for case let url as URL in walker {
            if isCancelled() { return plan }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                var st = stat()
                // A folder in a cloud service: a changed file there goes up to the service again, with no compression.
                let cloud = values?.isUbiquitousItem == true
                if cloud { plan.cloudFolders += 1 }
                if cloud || skipsFolder(named: url.lastPathComponent) || lstat(url.path, &st) != 0 || st.st_dev != rootStat.st_dev { walker.skipDescendants() }
                continue
            }
            if url.lastPathComponent.hasPrefix(tempPrefix) { continue }
            guard let f = facts(url.path) else { continue }
            plan.files += 1
            plan.bytes += f.allocated
            if let reason = skip(f, options: options, now: now) { plan.skipped[reason, default: 0] += 1; continue }
            if f.isCompressed { plan.alreadyCompressed += 1 }
            if canCompress(f, options: options) { plan.compress.append(f) }
            if canShare(f, options: options) { shareable[f.size, default: []].append(f) }
        }
        // Duplicates: the same size, then the same first block, then the same content.
        var copies = Set<String>()
        for (_, sameSize) in shareable where sameSize.count > 1 {
            if isCancelled() { return plan }
            for (_, sameHead) in Dictionary(grouping: sameSize, by: { hash($0.path, limit: 65536) ?? $0.path }) where sameHead.count > 1 {
                for (_, same) in Dictionary(grouping: sameHead, by: { $0.size <= 65536 ? "" : (hash($0.path, limit: nil) ?? $0.path) }) where same.count > 1 {
                    let sorted = same.sorted { $0.path < $1.path }
                    // Files that already are clones of one another have the same content identifier.
                    let ids = sorted.map { contentIdentifier($0.path) }
                    let keeper = sorted[0]
                    var group = Group(keeper: keeper, copies: [])
                    for (i, copy) in sorted.enumerated().dropFirst() {
                        if let id = ids[i], id == ids[0] { plan.alreadyShared += 1; continue }
                        if hasResourceFork(copy.path) || hasResourceFork(keeper.path) { plan.skipped[.resourceFork, default: 0] += 1; continue }
                        group.copies.append(copy)
                    }
                    if !group.copies.isEmpty { plan.groups.append(group); copies.formUnion(group.copies.map(\.path)) }
                }
            }
        }
        // A copy gets the data of its keeper, so compression of the copy is lost work.
        plan.compress.removeAll { copies.contains($0.path) }
        let measured = estimate(plan.compress, sample: options.sampleFiles, isCancelled: isCancelled)
        plan.compress = measured.keep.sorted { $0.allocated > $1.allocated }
        plan.compressSaving = measured.saving
        plan.noGain = measured.noGain
        plan.groups.sort { $0.saving > $1.saving }
        return plan
    }

    /// The part of its size that a file keeps after compression, from zlib on pieces of
    /// 64 KB at even distances in the file (32 or 128 pieces for a large file). 1 means no gain. The start alone is not
    /// sufficient: a large model or media file can have text at the start and noise after it.
    static func sampleRatio(_ path: String, size: Int64) -> Double? {
        guard size > 0, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let piece: Int64 = 65536
        let pieces = size <= piece ? 1 : (size >= 16 * largeFile ? 128 : size >= largeFile ? 32 : 4)
        var read = 0, packed = 0
        for i in 0..<pieces {
            let offset = pieces == 1 ? 0 : (size - piece) * Int64(i) / Int64(pieces - 1)
            guard (try? handle.seek(toOffset: UInt64(max(0, offset)))) != nil, let data = try? handle.read(upToCount: Int(piece)), !data.isEmpty,
                  let small = try? (data as NSData).compressed(using: .zlib) else { continue }
            read += data.count
            packed += small.length
        }
        return read > 0 ? min(1, Double(packed) / Double(read)) : nil
    }

    /// The space that compression frees for a file with this ratio. A compressed file uses whole blocks.
    static func saving(_ f: Facts, ratio: Double) -> Int64 {
        ratio > worthRatio ? 0 : max(0, f.allocated - (Int64(Double(f.size) * ratio) + 4095) / 4096 * 4096)
    }
    /// `ditto` keeps the compression of a file only when it gains about a fifth or more
    /// (measured: a file that keeps 75% is compressed, files that keep 78% and 90% are not).
    static let worthRatio = 0.76

    /// Takes the large files that do not get smaller out of the list, and gives the list
    /// with the estimate of the space that compression frees. Each large file is measured;
    /// of the small files a sample is measured, and the result is scaled to all of them.
    static func estimate(_ files: [Facts], sample: Int, isCancelled: () -> Bool) -> (keep: [Facts], saving: Int64, noGain: Int) {
        var keep: [Facts] = [], total: Int64 = 0, noGain = 0
        let large = files.filter { $0.allocated >= largeFile }
        for f in large {
            if isCancelled() { break }
            let ratio = sampleRatio(f.path, size: f.size) ?? 1
            // A press of a large file that gains almost nothing costs minutes and a full copy for a moment.
            if ratio > worthRatio { noGain += 1; continue }
            keep.append(f)
            total += saving(f, ratio: ratio)
        }
        let small = files.filter { $0.allocated < largeFile }
        keep += small
        guard !small.isEmpty, sample > 0 else { return (keep, total, noGain) }
        var sampled: Int64 = 0, saved: Int64 = 0
        for i in stride(from: 0, to: small.count, by: max(1, small.count / sample)) {
            if isCancelled() { break }
            guard let ratio = sampleRatio(small[i].path, size: small[i].size) else { continue }
            sampled += small[i].allocated
            saved += saving(small[i], ratio: ratio)
        }
        if sampled > 0 { total += Int64(Double(saved) / Double(sampled) * Double(small.reduce(Int64(0)) { $0 + $1.allocated })) }
        return (keep, total, noGain)
    }
    static let largeFile: Int64 = 4 << 20

    // MARK: - Changes

    public enum Outcome: Equatable, Sendable {
        /// The change is made. The value is the space that it freed, in bytes.
        case saved(Int64)
        /// Compression did not make the file smaller. The file is as it was.
        case noGain
        case skipped(Skip)
        case failed(String)
    }

    static let tempPrefix = ".kea-press-"

    private static func tempPath(for path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(tempPrefix + UUID().uuidString)
    }

    /// True if the file is the one that the plan saw: the same size and the same change date.
    private static func unchanged(_ now: Facts, _ then: Facts) -> Bool {
        now.size == then.size && now.modified == then.modified && now.modifiedNanos == then.modifiedNanos
    }

    /// Gives a file transparent compression. The content, the name, the dates, the mode,
    /// and the attributes stay. `open` holds the paths that a process has open.
    public static func compress(_ planned: Facts, options: Options = Options(), now: Date = Date(), open: Set<String> = []) -> Outcome {
        let path = planned.path
        guard let before = facts(path), unchanged(before, planned) else { return .skipped(.changed) }
        if let reason = skip(before, options: options, now: now) { return .skipped(reason) }
        guard canCompress(before, options: options) else { return .noGain }
        if open.contains(path) { return .skipped(.inUse) }
        let temp = tempPath(for: path)
        defer { unlink(temp) }
        // Apple's tool writes the compressed copy, with the dates, the mode, the attributes, and the access list of the file.
        let status = run("/usr/bin/ditto", ["--hfsCompression", path, temp])
        guard status == 0, let after = facts(temp) else { return .failed("ditto failed with status \(status)") }
        guard after.isCompressed, after.allocated < before.allocated else { return .noGain }
        guard after.size == before.size, sameContent(path, temp) else { return .failed("the compressed copy is not the same as the file") }
        guard let last = facts(path), unchanged(last, before), last.inode == before.inode else { return .skipped(.changed) }
        guard rename(temp, path) == 0 else { return .failed("rename: \(String(cString: strerror(errno)))") }
        return .saved(before.allocated - after.allocated)
    }

    /// Makes `copy` a clone of `keeper`: the same data on the disk one time. The name, the
    /// dates, the mode, the attributes, and the access list of the copy stay.
    public static func share(copy planned: Facts, keeper plannedKeeper: Facts, options: Options = Options(), now: Date = Date(), open: Set<String> = []) -> Outcome {
        guard let copy = facts(planned.path), unchanged(copy, planned), let keeper = facts(plannedKeeper.path), unchanged(keeper, plannedKeeper) else { return .skipped(.changed) }
        guard copy.device == keeper.device, copy.inode != keeper.inode, copy.size == keeper.size else { return .skipped(.changed) }
        for f in [copy, keeper] { if let reason = skip(f, options: options, now: now) { return .skipped(reason) } }
        if open.contains(copy.path) { return .skipped(.inUse) }
        if hasResourceFork(copy.path) || hasResourceFork(keeper.path) { return .skipped(.resourceFork) }
        guard sameContent(copy.path, keeper.path) else { return .skipped(.changed) }
        let temp = tempPath(for: copy.path)
        defer { unlink(temp) }
        guard clonefile(keeper.path, temp, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else { return .failed("clonefile: \(String(cString: strerror(errno)))") }
        if let problem = copyMetadata(from: copy.path, to: temp) { return .failed(problem) }
        guard let made = facts(temp), made.size == copy.size, made.mode == copy.mode, made.modified == copy.modified,
              let last = facts(copy.path), unchanged(last, copy), last.inode == copy.inode,
              let lastKeeper = facts(keeper.path), unchanged(lastKeeper, keeper) else { return .skipped(.changed) }
        guard rename(temp, copy.path) == 0 else { return .failed("rename: \(String(cString: strerror(errno)))") }
        return .saved(copy.allocated)
    }

    /// Gives `to` (a new clone of a different file) the mode, the hidden flag, the
    /// attributes, the access list, and the dates of `from`. Returns the problem, or nil.
    static func copyMetadata(from: String, to: String) -> String? {
        var st = stat()
        guard lstat(from, &st) == 0 else { return "the file is gone" }
        // The attributes of the keeper came with the clone. The compression data of a
        // compressed file is not in this list: the system hides it.
        for name in attributeNames(to) where removexattr(to, name, XATTR_NOFOLLOW) != 0 { return "could not remove the attribute \(name)" }
        for name in attributeNames(from) {
            let size = getxattr(from, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return "could not read the attribute \(name)" }
            var value = [UInt8](repeating: 0, count: size)
            guard getxattr(from, name, &value, size, 0, XATTR_NOFOLLOW) == size, setxattr(to, name, value, size, 0, XATTR_NOFOLLOW) == 0 else { return "could not copy the attribute \(name)" }
        }
        // The access list: the one of `from`, or none.
        if let acl = acl_get_link_np(from, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl_set_link_np(to, ACL_TYPE_EXTENDED, acl) == 0 else { return "could not copy the access list" }
        } else if let had = acl_get_link_np(to, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(had))
            guard let empty = acl_init(0) else { return "could not clear the access list" }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            guard acl_set_link_np(to, ACL_TYPE_EXTENDED, empty) == 0 else { return "could not clear the access list" }
        }
        guard chmod(to, st.st_mode & 0o7777) == 0 else { return "could not set the mode" }
        var made = stat()
        guard lstat(to, &made) == 0 else { return "the clone is gone" }
        let hidden = UInt32(UF_HIDDEN)
        if made.st_flags & hidden != st.st_flags & hidden, lchflags(to, (made.st_flags & ~hidden) | (st.st_flags & hidden)) != 0 { return "could not set the hidden flag" }
        // The dates last: the calls above change the date of the last status change only, which no call can set.
        var list = attrlist(bitmapcount: UInt16(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_CRTIME), volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var created = st.st_birthtimespec
        guard setattrlist(to, &list, &created, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0 else { return "could not set the creation date" }
        var times = [st.st_atimespec, st.st_mtimespec]
        guard utimensat(AT_FDCWD, to, &times, AT_SYMLINK_NOFOLLOW) == 0 else { return "could not set the dates" }
        return nil
    }

    // MARK: - Files

    /// Runs a program with no input and no output, and gives its exit status (-1 if it did not start).
    /// `posix_spawn` and not `Process`: a press starts the program one time for each file.
    static func run(_ program: String, _ arguments: [String]) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) }
        var argv = ([program] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, program, &actions, nil, &argv, environ) == 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 { if errno != EINTR { return -1 } }
        // The exit code, or -1 for a program that a signal stopped.
        return status & 0x7f == 0 ? (status >> 8) & 0xff : -1
    }

    static func attributeNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let got = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard got > 0 else { return [] }
        return buffer[..<got].split(separator: 0).map { String(cString: Array($0) + [0]) }
    }

    /// A real resource fork: a second stream of data, which the comparison of content does not read.
    static func hasResourceFork(_ path: String) -> Bool { attributeNames(path).contains("com.apple.ResourceFork") }

    /// The identifier that APFS gives the data of a file. Clones of one another have the same one.
    static func contentIdentifier(_ path: String) -> Int64? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileContentIdentifierKey]))?.fileContentIdentifier
    }

    static func hash(_ path: String, limit: Int?) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var left = limit ?? Int.max
        while left > 0, let chunk = try? handle.read(upToCount: min(left, 1 << 20)), !chunk.isEmpty {
            hasher.update(data: chunk)
            left -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True if the two files have the same bytes.
    public static func sameContent(_ a: String, _ b: String) -> Bool {
        guard let one = FileHandle(forReadingAtPath: a), let two = FileHandle(forReadingAtPath: b) else { return false }
        defer { try? one.close(); try? two.close() }
        while true {
            let x = (try? one.read(upToCount: 1 << 20)) ?? Data(), y = (try? two.read(upToCount: 1 << 20)) ?? Data()
            if x != y { return false }
            if x.isEmpty { return true }
        }
    }

    /// The paths of the files that a process of this user has open now.
    public static func openFiles() -> Set<String> {
        var out = Set<String>()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return out }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(0, got))) where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 16)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            for fd in fds.prefix(Int(max(0, used)) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
                let path = withUnsafePointer(to: &info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                if !path.isEmpty { out.insert(path) }
            }
        }
        return out
    }

    // MARK: - Run

    public struct Report: Sendable {
        public var compressed = 0
        public var compressSaved: Int64 = 0
        public var shared = 0
        public var shareSaved: Int64 = 0
        public var noGain = 0
        public var skipped: [Skip: Int] = [:]
        /// The path and the problem of each change that failed. The file is as it was.
        public var failed: [(path: String, problem: String)] = []
        public var cancelled = false
        public var saved: Int64 { compressSaved + shareSaved }
    }

    public struct Change: Sendable {
        public var path: String
        /// "compress" or "share".
        public var action: String
        public var outcome: Outcome
    }

    /// Makes the changes of a plan. `onChange` gets each result, and `open` gives the
    /// files that are in use; the run asks for a new list every few seconds.
    public static func apply(_ plan: Plan, options: Options = Options(), open: () -> Set<String> = openFiles, isCancelled: () -> Bool = { false },
                             onChange: (Change) -> Void = { _ in }) -> Report {
        var report = Report()
        var inUse = open()
        var asked = Date()
        func refresh() {
            guard Date().timeIntervalSince(asked) > 5 else { return }
            inUse = open()
            asked = Date()
        }
        func record(_ change: Change, compress: Bool) {
            switch change.outcome {
            case .saved(let bytes):
                if compress { report.compressed += 1; report.compressSaved += bytes } else { report.shared += 1; report.shareSaved += bytes }
            case .noGain: report.noGain += 1
            case .skipped(let reason): report.skipped[reason, default: 0] += 1
            case .failed(let problem): report.failed.append((change.path, problem))
            }
            onChange(change)
        }
        // Compression first: a keeper that gets smaller gives its copies the smaller data.
        var keepers: [String: Facts] = [:]
        for file in plan.compress {
            if isCancelled() { report.cancelled = true; return report }
            refresh()
            let outcome = compress(file, options: options, open: inUse)
            if case .saved = outcome, let now = facts(file.path) { keepers[file.path] = now }
            record(Change(path: file.path, action: "compress", outcome: outcome), compress: true)
        }
        for group in plan.groups {
            // The compression gave the keeper a new file with the same content and dates.
            let keeper = keepers[group.keeper.path] ?? group.keeper
            for copy in group.copies {
                if isCancelled() { report.cancelled = true; return report }
                refresh()
                record(Change(path: copy.path, action: "share", outcome: share(copy: copy, keeper: keeper, options: options, open: inUse)), compress: false)
            }
        }
        return report
    }

    // MARK: - Text

    /// The lines that tell a person what a plan changes.
    public static func describe(_ plan: Plan, home: String = NSHomeDirectory()) -> String {
        var lines = ["\(plan.files) files, \(Tidy.size(plan.bytes)) on the disk, in \(plan.root.replacingOccurrences(of: home, with: "~"))"]
        lines.append(plan.compress.isEmpty ? "Compress: nothing to do" : "Compress \(plan.compress.count) files: frees about \(Tidy.size(plan.compressSaving)) (an estimate)")
        lines.append(plan.groups.isEmpty ? "Share: no duplicate files" : "Share the data of \(plan.shareCount) duplicate files (\(plan.groups.count) groups): frees \(Tidy.size(plan.shareSaving))")
        if plan.alreadyCompressed > 0 || plan.alreadyShared > 0 { lines.append("Already done: \(plan.alreadyCompressed) compressed, \(plan.alreadyShared) shared") }
        let skipped = Skip.allCases.compactMap { reason in plan.skipped[reason].map { "\($0) \(reason.rawValue)" } }
        if !skipped.isEmpty { lines.append("Left alone: " + skipped.joined(separator: "; ")) }
        if plan.noGain > 0 { lines.append("Left alone: \(plan.noGain) large files that compression does not make smaller") }
        if plan.cloudFolders > 0 { lines.append("Left alone: \(plan.cloudFolders) folders that a cloud service keeps") }
        return lines.joined(separator: "\n")
    }

    public static func describe(_ report: Report) -> String {
        var lines = ["Freed \(Tidy.size(report.saved))\(report.cancelled ? " (stopped before the end)" : "")",
                     "Compressed \(report.compressed) files (\(Tidy.size(report.compressSaved))); shared \(report.shared) duplicate files (\(Tidy.size(report.shareSaved)))"]
        if report.noGain > 0 { lines.append("\(report.noGain) files did not get smaller and stay as they were") }
        let skipped = Skip.allCases.compactMap { reason in report.skipped[reason].map { "\($0) \(reason.rawValue)" } }
        if !skipped.isEmpty { lines.append("Left alone: " + skipped.joined(separator: "; ")) }
        if !report.failed.isEmpty { lines.append("\(report.failed.count) changes failed, and those files are as they were. First: \(report.failed[0].path): \(report.failed[0].problem)") }
        return lines.joined(separator: "\n")
    }
}
