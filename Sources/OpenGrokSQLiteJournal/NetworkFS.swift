// NetworkFS.swift
//
// Port of network-filesystem detection from `xai-sqlite-journal`.
// WAL's mmap'd `-shm` is unsafe on network mounts; callers switch to
// TRUNCATE journal mode when `isNetworkFS` returns true.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Best-effort: whether `path` lives on a network/remote filesystem.
///
/// Detection failure returns `false` (treat as local) so unclassifiable
/// filesystems keep historical WAL behavior.
public func isNetworkFS(_ path: URL) -> Bool {
    NetworkFS.classify(path)
}

enum NetworkFS {
    static func classify(_ path: URL) -> Bool {
        #if os(macOS)
        return classifyMac(path)
        #elseif os(Linux)
        return classifyLinux(path)
        #elseif os(Windows)
        return classifyWindows(path)
        #else
        _ = path
        return false
        #endif
    }

    // MARK: - Pure classifiers (testable)

    /// Linux `statfs` f_type magic values (low 32 bits).
    ///
    /// Retained as the canonical definition of the network set even though the
    /// live Linux probe classifies by mount-table *name*: Swift's Glibc overlay
    /// does not export `statfs`, so the magic is unreadable without a C shim.
    /// `isNetworkFSTypeLinux` mirrors this list entry for entry.
    static func isNetworkFSMagic(_ fType: UInt64) -> Bool {
        let NFS_SUPER_MAGIC: UInt64 = 0x6969
        let SMB_SUPER_MAGIC: UInt64 = 0x517B
        let SMB2_SUPER_MAGIC: UInt64 = 0xFE53_4D42
        let CIFS_SUPER_MAGIC: UInt64 = 0xFF53_4D42
        let V9FS_MAGIC: UInt64 = 0x0102_1997
        let CODA_SUPER_MAGIC: UInt64 = 0x7375_7245
        let AFS_SUPER_MAGIC: UInt64 = 0x5346_414F
        let AFS_FS_MAGIC: UInt64 = 0x6B41_4653
        let CEPH_SUPER_MAGIC: UInt64 = 0x00C3_6400
        let LUSTRE_SUPER_MAGIC: UInt64 = 0x0BD0_0BD0
        let GFS2_MAGIC: UInt64 = 0x0116_1970
        let GPFS_SUPER_MAGIC: UInt64 = 0x4750_4653
        let OCFS2_SUPER_MAGIC: UInt64 = 0x7461_636F
        let WEKAFS_SUPER_MAGIC: UInt64 = 0x1803_1977
        let FUSE_SUPER_MAGIC: UInt64 = 0x6573_5546
        let magic = fType & 0xFFFF_FFFF
        switch magic {
        case NFS_SUPER_MAGIC, SMB_SUPER_MAGIC, SMB2_SUPER_MAGIC, CIFS_SUPER_MAGIC,
             V9FS_MAGIC, CODA_SUPER_MAGIC, AFS_SUPER_MAGIC, AFS_FS_MAGIC,
             CEPH_SUPER_MAGIC, LUSTRE_SUPER_MAGIC, GFS2_MAGIC, GPFS_SUPER_MAGIC,
             OCFS2_SUPER_MAGIC, WEKAFS_SUPER_MAGIC, FUSE_SUPER_MAGIC:
            return true
        default:
            return false
        }
    }

    /// macOS MNT_LOCAL bit (matches libc).
    static let mntLocal: UInt32 = 0x0000_1000

    static func isNetworkFSMac(fFlags: UInt32, fstype: String) -> Bool {
        (fFlags & mntLocal) == 0 || isNetworkFSName(fstype)
    }

    static func isNetworkFSName(_ fstype: String) -> Bool {
        let n = fstype.lowercased()
        return n == "nfs" || n == "smbfs" || n == "cifs" || n == "afpfs"
            || n == "webdav" || n == "macfuse" || n == "osxfuse"
    }

    /// Linux mount-table fstype names, mirroring `isNetworkFSMagic`'s set.
    static func isNetworkFSTypeLinux(_ fstype: String) -> Bool {
        let n = fstype.lowercased()
        // FUSE_SUPER_MAGIC covers every `fuse.*` transport (sshfs, s3fs, ...);
        // NFS reports nfs/nfs3/nfs4 under one magic.
        if n.hasPrefix("fuse") || n.hasPrefix("nfs") { return true }
        switch n {
        case "smbfs", "smb2", "smb3", "cifs", "9p", "coda", "afs", "ceph",
             "lustre", "gfs2", "gpfs", "ocfs2", "wekafs", "glusterfs", "beegfs":
            return true
        default:
            return false
        }
    }

    /// Decode `/proc/self/mounts` octal escapes (`\040` space, `\011` tab,
    /// `\012` newline, `\134` backslash). Unrecognized sequences pass through.
    static func unescapeMountField(_ field: String) -> String {
        guard field.contains("\\") else { return field }
        var out = ""
        var chars = Array(field)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 3 < chars.count,
               let value = UInt8(String(chars[(i + 1)...(i + 3)]), radix: 8) {
                out.append(Character(UnicodeScalar(value)))
                i += 4
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// fstype of the mount containing `path`, from a `/proc/self/mounts`-format
    /// table. Longest matching mount point wins, so a bind mount nested inside
    /// another mount is classified by its own entry rather than its parent's.
    static func mountFSType(forPath path: String, mounts: String) -> String? {
        var best: (length: Int, fstype: String)?
        for line in mounts.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3 else { continue }
            let mountPoint = unescapeMountField(String(fields[1]))
            guard !mountPoint.isEmpty else { continue }
            let matches = mountPoint == "/"
                || path == mountPoint
                || path.hasPrefix(mountPoint + "/")
            guard matches else { continue }
            if best == nil || mountPoint.count > best!.length {
                best = (mountPoint.count, unescapeMountField(String(fields[2])))
            }
        }
        return best?.fstype
    }

    /// Windows UNC path classification.
    static func isWindowsUNC(_ path: String) -> Bool {
        guard path.hasPrefix("\\\\") else { return false }
        let rest = String(path.dropFirst(2))
        if rest.hasPrefix("?\\") {
            let verbatim = String(rest.dropFirst(2))
            return verbatim.count >= 4
                && verbatim.prefix(4).uppercased() == "UNC\\"
        }
        return !rest.hasPrefix(".\\")
    }

    // MARK: - Platform probes

    #if os(macOS)
    private static func classifyMac(_ path: URL) -> Bool {
        var st = statfs()
        let rc = path.path.withCString { statfs($0, &st) }
        guard rc == 0 else { return false }
        // f_fstypename is a fixed CChar array.
        var bytes: [CChar] = []
        withUnsafeBytes(of: st.f_fstypename) { raw in
            for b in raw {
                let c = CChar(bitPattern: b)
                if c == 0 { break }
                bytes.append(c)
            }
        }
        let name = bytes.withUnsafeBufferPointer { buf in
            String(cString: buf.baseAddress!)
        }
        return isNetworkFSMac(fFlags: st.f_flags, fstype: name)
    }
    #endif

    #if os(Linux)
    private static func classifyLinux(_ path: URL) -> Bool {
        let resolved = path.resolvingSymlinksInPath().path
        guard let mounts = try? String(contentsOfFile: "/proc/self/mounts", encoding: .utf8),
              let fstype = mountFSType(forPath: resolved, mounts: mounts)
        else {
            return false
        }
        return isNetworkFSTypeLinux(fstype)
    }
    #endif

    #if os(Windows)
    private static func classifyWindows(_ path: URL) -> Bool {
        let p = path.path
        if isWindowsUNC(p) { return true }
        // Mapped drives: without Win32 GetDriveTypeW linkage in SwiftPM,
        // treat non-UNC as local. Adapter can be strengthened later.
        return false
    }
    #endif
}
