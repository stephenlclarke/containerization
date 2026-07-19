//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ArgumentParser
import Cgroup
import ContainerizationOCI
import ContainerizationOS
import FoundationEssentials
import LCShim
import SystemPackage

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a container"
    )

    @Option(name: .long, help: "path to an OCI bundle")
    var bundlePath: String

    mutating func run() throws {
        do {
            let spec: ContainerizationOCI.Spec
            do {
                let bundle = try ContainerizationOCI.Bundle.load(path: URL(filePath: bundlePath))
                spec = try bundle.loadConfig()
            } catch {
                throw App.Failure(message: "failed to load OCI bundle at \(bundlePath): \(error)")
            }
            try execInNamespace(spec: spec)
        } catch {
            App.writeError(error)
            throw error
        }
    }

    private func childRootSetup(
        rootfs: ContainerizationOCI.Root,
        mounts: [ContainerizationOCI.Mount]
    ) throws {
        // setup rootfs
        try prepareRoot(rootfs: rootfs.path)
        try mountRootfs(rootfs: rootfs.path, mounts: mounts)
        try setDevSymlinks(rootfs: rootfs.path)

        try pivotRoot(rootfs: rootfs.path)

        // Remount ro if requested.
        if rootfs.readonly {
            try self.remountRootfsReadOnly()
        }

        try reOpenDevNull()
    }

    /// Mask paths per OCI `linux.maskedPaths`. Files (and any non-directory)
    /// get `/dev/null` bind-mounted on top; directories get an empty read-only
    /// tmpfs. Missing paths are skipped silently — matches runc's `maskPath`.
    private func applyMaskedPaths(_ paths: [String]) throws {
        for path in paths {
            var st = stat()
            if stat(path, &st) != 0 {
                if errno == ENOENT {
                    continue
                }
                throw App.Errno(stage: "stat(\(path)) for mask")
            }

            if (st.st_mode & S_IFMT) == S_IFDIR {
                // Match runc: mask directories with a read-only tmpfs. MS_RDONLY
                // is what actually prevents writes into the masked dir; a
                // `size=0k` option would be a no-op (the kernel treats tmpfs
                // size=0 as "no limit", not an empty filesystem).
                guard mount("tmpfs", path, "tmpfs", UInt(MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC), nil) == 0 else {
                    throw App.Errno(stage: "mount(tmpfs mask \(path))")
                }
            } else {
                guard mount("/dev/null", path, "bind", UInt(MS_BIND), nil) == 0 else {
                    throw App.Errno(stage: "mount(bind /dev/null -> \(path))")
                }
            }
        }
    }

    /// Make paths read-only per OCI `linux.readonlyPaths` by bind-mounting
    /// each onto itself and remounting with `MS_RDONLY`. Missing paths are
    /// skipped silently — matches runc's `readonlyPath`. The statfs fallback
    /// mirrors `remountRootfsReadOnly()` for filesystems whose existing flags
    /// (e.g. nosuid, nodev) must be preserved on the remount.
    private func applyReadonlyPaths(_ paths: [String]) throws {
        for path in paths {
            var st = stat()
            if stat(path, &st) != 0 {
                if errno == ENOENT {
                    continue
                }
                throw App.Errno(stage: "stat(\(path)) for readonly")
            }

            guard mount(path, path, "", UInt(MS_BIND | MS_REC), nil) == 0 else {
                throw App.Errno(stage: "mount(bind \(path))")
            }

            var flags = UInt(MS_BIND | MS_REMOUNT | MS_RDONLY)
            if mount("", path, "", flags, "") == 0 {
                continue
            }

            var s = statfs()
            guard statfs(path, &s) == 0 else {
                throw App.Errno(stage: "statfs(\(path))")
            }
            flags |= UInt(s.f_flags)

            guard mount("", path, "", flags, "") == 0 else {
                throw App.Errno(stage: "mount remount-ro \(path)")
            }
        }
    }

    private func remountRootfsReadOnly() throws {
        var flags = UInt(MS_BIND | MS_REMOUNT | MS_RDONLY)

        let ret = mount("", "/", "", flags, "")
        if ret == 0 {
            return
        }

        var s = statfs()
        guard statfs("/", &s) == 0 else {
            throw App.Errno(stage: "statfs(/)")
        }
        flags |= UInt(s.f_flags)

        guard mount("", "/", "", flags, "") == 0 else {
            throw App.Errno(stage: "mount rootfs ro")
        }
    }

    private func childSetup(
        spec: ContainerizationOCI.Spec,
        ackPipe: FileDescriptor,
        syncPipe: FileDescriptor,
        userNamespaceReadyDescriptor: Int32? = nil,
        userNamespaceMappedDescriptor: Int32? = nil
    ) throws {
        guard let process = spec.process else {
            throw App.Failure(message: "no process configuration found in runtime spec")
        }
        guard let root = spec.root else {
            throw App.Failure(message: "no root found in runtime spec")
        }

        // Wait for the grandparent to tell us that they acked our pid.
        var pidAckBuffer = [UInt8](repeating: 0, count: App.ackPid.count)
        let pidAckBytesRead: Int
        do {
            pidAckBytesRead = try pidAckBuffer.withUnsafeMutableBytes { buffer in
                try ackPipe.read(into: buffer)
            }
        } catch {
            throw App.Failure(message: "read process acknowledgement: \(error)")
        }
        guard pidAckBytesRead > 0 else {
            throw App.Failure(message: "read ack pipe")
        }
        let pidAckStr = String(decoding: pidAckBuffer[..<pidAckBytesRead], as: UTF8.self)

        guard pidAckStr == App.ackPid else {
            throw App.Failure(message: "received invalid acknowledgement string: \(pidAckStr)")
        }

        guard unshare(CLONE_NEWCGROUP) == 0 else {
            throw App.Failure(message: "create cgroup namespace: \(App.Errno(stage: "unshare(cgroup)"))")
        }

        guard setsid() != -1 else {
            throw App.Failure(message: "create session: \(App.Errno(stage: "setsid()"))")
        }

        do {
            try childRootSetup(rootfs: root, mounts: spec.mounts)
        } catch {
            throw App.Failure(message: "configure container rootfs: \(error)")
        }

        if process.terminal {
            let pty = try Console()
            try pty.configureStdIO()
            var masterFD = pty.master

            try withUnsafeBytes(of: &masterFD) { bytes in
                _ = try syncPipe.write(bytes)
            }

            // Wait for the grandparent to tell us that they acked our console.
            var consoleAckBuffer = [UInt8](repeating: 0, count: App.ackConsole.count)
            let consoleAckBytesRead = try consoleAckBuffer.withUnsafeMutableBytes { buffer in
                try ackPipe.read(into: buffer)
            }
            guard consoleAckBytesRead > 0 else {
                throw App.Failure(message: "read ack pipe")
            }
            let consoleAckStr = String(decoding: consoleAckBuffer[..<consoleAckBytesRead], as: UTF8.self)

            guard consoleAckStr == App.ackConsole else {
                throw App.Failure(message: "received invalid acknowledgement string: \(consoleAckStr)")
            }

            guard ioctl(0, UInt(TIOCSCTTY), 0) != -1 else {
                throw App.Errno(stage: "setctty(0)")
            }

            try mountConsole(path: pty.slavePath)
            try pty.close()
        }

        if !spec.hostname.isEmpty {
            let errCode = spec.hostname.withCString { ptr in
                sethostname(ptr, spec.hostname.count)
            }
            guard errCode == 0 else {
                throw App.Errno(stage: "sethostname()")
            }
        }

        // Apply sysctls from the OCI spec.
        if let sysctls = spec.linux?.sysctl {
            for (key, value) in sysctls {
                let path = "/proc/sys/" + key.replacingOccurrences(of: ".", with: "/")
                let fd = open(path, O_WRONLY)
                guard fd >= 0 else {
                    throw App.Errno(stage: "sysctl open(\(path))")
                }
                defer { close(fd) }
                let bytes = Array(value.utf8)
                let written = write(fd, bytes, bytes.count)
                guard written == bytes.count else {
                    throw App.Errno(stage: "sysctl write(\(key)=\(value))")
                }
            }
        }

        // Apply OCI maskedPaths/readonlyPaths AFTER sysctls (writes to
        // /proc/sys/* would otherwise fail once /proc/sys is remounted ro)
        // and BEFORE the user/capability change (mount() requires
        // CAP_SYS_ADMIN, which we still have here as root). Mask runs first
        // so a path appearing in both lists is hidden, not just locked.
        do {
            try self.applyMaskedPaths(spec.linux?.maskedPaths ?? [])
            try self.applyReadonlyPaths(spec.linux?.readonlyPaths ?? [])
        } catch {
            throw App.Failure(message: "apply container mount protections: \(error)")
        }

        // Apply O_CLOEXEC before entering a private user namespace. The
        // procfs file-descriptor view is owned by the initial namespace in
        // this guest, while the descriptors themselves remain usable for the
        // mapping handshake below.
        do {
            try App.applyCloseExecOnFDs()
        } catch {
            throw App.Failure(message: "enumerate process file descriptors: \(error)")
        }

        if let userNamespaceReadyDescriptor, let userNamespaceMappedDescriptor {
            // Mounts and other privileged guest setup must occur while this
            // process still has capabilities in the sandbox VM's initial user
            // namespace. The parent maps this new namespace before any
            // workload credentials or capabilities are applied.
            guard unshare(CLONE_NEWUSER) == 0 else {
                throw App.Failure(message: "create user namespace: \(App.Errno(stage: "unshare(user)"))")
            }
            do {
                try sendUserNamespaceMappingSignal(1, to: userNamespaceReadyDescriptor)
                try waitForUserNamespaceMappingSignal(from: userNamespaceMappedDescriptor, expected: 1)
            } catch {
                throw App.Failure(message: "synchronize user namespace mapping: \(error)")
            }
        }

        do {
            try App.setRLimits(rlimits: process.rlimits)
        } catch {
            throw App.Failure(message: "apply process resource limits: \(error)")
        }

        let preparedCaps: ContainerizationOS.LinuxCapabilities?
        do {
            // Prepare capabilities (before user change)
            preparedCaps = try App.prepareCapabilities(capabilities: process.capabilities ?? ContainerizationOCI.LinuxCapabilities())
        } catch {
            throw App.Failure(message: "prepare process capabilities: \(error)")
        }

        do {
            // Change stdio to be owned by the requested user.
            try App.fixStdioPerms(user: process.user)
        } catch {
            throw App.Failure(message: "set process standard-stream ownership: \(error)")
        }

        do {
            // Set uid, gid, and supplementary groups.
            try App.setPermissions(user: process.user)
        } catch {
            throw App.Failure(message: "set process credentials: \(error)")
        }

        do {
            // Finish capabilities (after user change)
            try App.finishCapabilities(preparedCaps)
        } catch {
            throw App.Failure(message: "finish process capabilities: \(error)")
        }

        do {
            // Set no_new_privs if requested by the OCI spec.
            try App.setNoNewPrivileges(process: process)
        } catch {
            throw App.Failure(message: "set no-new-privileges: \(error)")
        }

        do {
            // Finally execve the container process.
            try App.exec(process: process, currentEnv: process.env)
        } catch {
            throw App.Failure(message: "exec container process: \(error)")
        }
    }

    private func setupNamespaces(namespaces: [ContainerizationOCI.LinuxNamespace]?) throws -> Int32 {
        var unshareFlags: Int32 = 0

        // Map namespace types to their corresponding CLONE flags
        let nsTypeToFlag: [ContainerizationOCI.LinuxNamespaceType: Int32] = [
            .pid: CLONE_NEWPID,
            .mount: CLONE_NEWNS,
            .uts: CLONE_NEWUTS,
            .ipc: CLONE_NEWIPC,
            .user: CLONE_NEWUSER,
            .cgroup: CLONE_NEWCGROUP,
        ]

        guard let namespaces = namespaces else {
            return CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUTS
        }

        for ns in namespaces {
            guard let flag = nsTypeToFlag[ns.type] else {
                continue
            }

            if ns.path.isEmpty {
                unshareFlags |= flag
            } else {
                let fd = open(ns.path, O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else {
                    throw App.Errno(stage: "open(\(ns.path))")
                }
                defer { close(fd) }

                guard setns(fd, flag) == 0 else {
                    throw App.Errno(stage: "setns(\(ns.path))")
                }
            }
        }

        return unshareFlags
    }

    private func writeUserNamespaceFile(path: String, contents: String) throws {
        let fd = open(path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw App.Errno(stage: "open(\(path))")
        }
        defer { close(fd) }

        let bytes = Array(contents.utf8)
        let bytesWritten = write(fd, bytes, bytes.count)
        guard bytesWritten == bytes.count else {
            throw App.Errno(stage: "write(\(path))")
        }
    }

    private func writeUserNamespaceMappings(
        _ mappings: [ContainerizationOCI.LinuxIDMapping],
        to path: String
    ) throws {
        let contents = mappings
            .map { "\($0.containerID) \($0.hostID) \($0.size)" }
            .joined(separator: "\n")
        try writeUserNamespaceFile(path: path, contents: "\(contents)\n")
    }

    private func configureUserNamespaceMappings(
        for processID: Int32,
        linux: ContainerizationOCI.Linux
    ) throws {
        let processPath = "/proc/\(processID)"

        if !linux.gidMappings.isEmpty {
            // A mapper with CAP_SETGID in the parent namespace may write the
            // GID map without disabling setgroups. Preserve that capability
            // so the OCI process can apply its supplementary groups. An
            // unprivileged mapper must instead deny setgroups before writing
            // gid_map, so retry through that kernel-required fallback.
            do {
                try writeUserNamespaceMappings(linux.gidMappings, to: "\(processPath)/gid_map")
            } catch {
                do {
                    try writeUserNamespaceFile(path: "\(processPath)/setgroups", contents: "deny\n")
                    try writeUserNamespaceMappings(linux.gidMappings, to: "\(processPath)/gid_map")
                } catch {
                    throw App.Failure(message: "configure user namespace gid map: \(error)")
                }
            }
        }
        if !linux.uidMappings.isEmpty {
            do {
                try writeUserNamespaceMappings(linux.uidMappings, to: "\(processPath)/uid_map")
            } catch {
                throw App.Failure(message: "configure user namespace uid map: \(error)")
            }
        }
    }

    private func sendUserNamespaceMappingSignal(_ signal: UInt8, to descriptor: Int32) throws {
        var signal = signal
        let count = withUnsafeBytes(of: &signal) { bytes in
            write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard count == 1 else {
            throw App.Errno(stage: "write(user namespace mapping signal)")
        }
    }

    private func waitForUserNamespaceMappingSignal(from descriptor: Int32, expected: UInt8) throws {
        var signal: UInt8 = 0
        let count = withUnsafeMutableBytes(of: &signal) { bytes in
            read(descriptor, bytes.baseAddress, bytes.count)
        }
        guard count >= 0 else {
            throw App.Errno(stage: "read(user namespace mapping signal)")
        }
        guard count == 1, signal == expected else {
            throw App.Failure(message: "invalid user namespace mapping synchronization")
        }
    }

    private func startContainerProcess(
        spec: ContainerizationOCI.Spec,
        syncPipe: FileDescriptor,
        ackPipe: FileDescriptor
    ) throws {
        let processID = fork()
        guard processID != -1 else {
            try? syncPipe.close()
            try? ackPipe.close()
            throw App.Errno(stage: "fork")
        }

        if processID == 0 {  // child
            try childSetup(
                spec: spec,
                ackPipe: ackPipe,
                syncPipe: syncPipe
            )
        } else {  // parent process
            // Setup cgroup before child enters cgroup namespace
            if let linux = spec.linux {
                let cgroupPath = linux.cgroupsPath
                if !cgroupPath.isEmpty {
                    let cgroupManager = try Cgroup2Manager.load(group: URL(filePath: cgroupPath))

                    if let resources = linux.resources {
                        try cgroupManager.applyResources(resources: resources)
                    }

                    try cgroupManager.addProcess(pid: processID)
                }
            }

            // Send our child's pid before we exit.
            var childPid = processID
            try withUnsafeBytes(of: &childPid) { bytes in
                _ = try syncPipe.write(bytes)
            }
        }
    }

    private func startContainerProcessInNamespaceRunner(
        spec: ContainerizationOCI.Spec,
        syncPipe: FileDescriptor,
        ackPipe: FileDescriptor,
        userNamespaceReadyDescriptor: Int32,
        userNamespaceMappedDescriptor: Int32,
        mappingProcessDescriptor: Int32
    ) throws {
        let processID = fork()
        guard processID != -1 else {
            throw App.Errno(stage: "fork(user namespace container)")
        }

        if processID == 0 {
            close(mappingProcessDescriptor)
            do {
                try childSetup(
                    spec: spec,
                    ackPipe: ackPipe,
                    syncPipe: syncPipe,
                    userNamespaceReadyDescriptor: userNamespaceReadyDescriptor,
                    userNamespaceMappedDescriptor: userNamespaceMappedDescriptor
                )
            } catch {
                throw App.Failure(message: "private user namespace child setup: \(error)")
            }
            return
        }

        var childPID = processID
        let count = withUnsafeBytes(of: &childPID) { bytes in
            write(mappingProcessDescriptor, bytes.baseAddress, bytes.count)
        }
        guard count == MemoryLayout<Int32>.size else {
            throw App.Errno(stage: "write(user namespace container process ID)")
        }
    }

    private func startContainerWithPrivateUserNamespace(
        spec: ContainerizationOCI.Spec,
        unshareFlags: Int32,
        syncPipe: FileDescriptor,
        ackPipe: FileDescriptor,
        linux: ContainerizationOCI.Linux
    ) throws {
        var readyDescriptors: [Int32] = [0, 0]
        guard pipe(&readyDescriptors) == 0 else {
            throw App.Errno(stage: "pipe(user namespace ready)")
        }

        var mappedDescriptors: [Int32] = [0, 0]
        guard pipe(&mappedDescriptors) == 0 else {
            close(readyDescriptors[0])
            close(readyDescriptors[1])
            throw App.Errno(stage: "pipe(user namespace mapped)")
        }

        var processDescriptors: [Int32] = [0, 0]
        guard pipe(&processDescriptors) == 0 else {
            close(readyDescriptors[0])
            close(readyDescriptors[1])
            close(mappedDescriptors[0])
            close(mappedDescriptors[1])
            throw App.Errno(stage: "pipe(user namespace process)")
        }

        let runnerPID = fork()
        guard runnerPID != -1 else {
            close(readyDescriptors[0])
            close(readyDescriptors[1])
            close(mappedDescriptors[0])
            close(mappedDescriptors[1])
            close(processDescriptors[0])
            close(processDescriptors[1])
            throw App.Errno(stage: "fork(user namespace runner)")
        }

        if runnerPID == 0 {
            close(readyDescriptors[0])
            close(mappedDescriptors[1])
            close(processDescriptors[0])
            defer {
                close(readyDescriptors[1])
                close(mappedDescriptors[0])
                close(processDescriptors[1])
            }

            let runnerFlags = unshareFlags & ~(CLONE_NEWUSER | CLONE_NEWCGROUP)
            guard unshare(runnerFlags) == 0 else {
                throw App.Errno(stage: "unshare(\(runnerFlags))")
            }
            try startContainerProcessInNamespaceRunner(
                spec: spec,
                syncPipe: syncPipe,
                ackPipe: ackPipe,
                userNamespaceReadyDescriptor: readyDescriptors[1],
                userNamespaceMappedDescriptor: mappedDescriptors[0],
                mappingProcessDescriptor: processDescriptors[1]
            )
            return
        }

        close(readyDescriptors[1])
        close(mappedDescriptors[0])
        close(processDescriptors[1])
        defer {
            close(readyDescriptors[0])
            close(mappedDescriptors[1])
            close(processDescriptors[0])
        }

        var containerProcessID: Int32 = 0
        let count = withUnsafeMutableBytes(of: &containerProcessID) { bytes in
            read(processDescriptors[0], bytes.baseAddress, bytes.count)
        }
        guard count == MemoryLayout<Int32>.size else {
            _ = kill(runnerPID, SIGKILL)
            throw App.Failure(message: "read user namespace container process ID")
        }

        do {
            let cgroupPath = linux.cgroupsPath
            if !cgroupPath.isEmpty {
                do {
                    let cgroupManager = try Cgroup2Manager.load(group: URL(filePath: cgroupPath))
                    if let resources = linux.resources {
                        try cgroupManager.applyResources(resources: resources)
                    }
                    try cgroupManager.addProcess(pid: containerProcessID)
                } catch {
                    throw App.Failure(message: "configure private user namespace cgroup: \(error)")
                }
            }

            var childPID = containerProcessID
            do {
                try withUnsafeBytes(of: &childPID) { bytes in
                    _ = try syncPipe.write(bytes)
                }
            } catch {
                throw App.Failure(message: "signal private user namespace container PID: \(error)")
            }
            try waitForUserNamespaceMappingSignal(from: readyDescriptors[0], expected: 1)
            try configureUserNamespaceMappings(for: containerProcessID, linux: linux)
            try sendUserNamespaceMappingSignal(1, to: mappedDescriptors[1])
        } catch {
            _ = kill(runnerPID, SIGKILL)
            _ = kill(containerProcessID, SIGKILL)
            throw error
        }
    }

    private func execInNamespace(spec: ContainerizationOCI.Spec) throws {
        let syncPipe = FileDescriptor(rawValue: 3)
        let ackPipe = FileDescriptor(rawValue: 4)

        let unshareFlags = try setupNamespaces(namespaces: spec.linux?.namespaces)

        let linux = spec.linux
        let hasMappings = !(linux?.uidMappings.isEmpty ?? true) || !(linux?.gidMappings.isEmpty ?? true)
        let createsPrivateUserNamespace = unshareFlags & CLONE_NEWUSER != 0
        guard !hasMappings || createsPrivateUserNamespace else {
            throw App.Failure(message: "OCI UID/GID mappings require a private user namespace")
        }

        if createsPrivateUserNamespace, hasMappings, let linux {
            try startContainerWithPrivateUserNamespace(
                spec: spec,
                unshareFlags: unshareFlags,
                syncPipe: syncPipe,
                ackPipe: ackPipe,
                linux: linux
            )
            return
        }

        guard unshare(unshareFlags) == 0 else {
            throw App.Errno(stage: "unshare(\(unshareFlags))")
        }
        try startContainerProcess(
            spec: spec,
            syncPipe: syncPipe,
            ackPipe: ackPipe
        )
    }

    private func mountRootfs(rootfs: String, mounts: [ContainerizationOCI.Mount]) throws {
        let containerMount = ContainerMount(rootfs: rootfs, mounts: mounts)
        try containerMount.mountToRootfs()
        try containerMount.configureConsole()
    }

    private func prepareRoot(rootfs: String) throws {
        guard mount("", "/", "", UInt(MS_SLAVE | MS_REC), nil) == 0 else {
            throw App.Errno(stage: "mount(slave|rec)")
        }

        guard mount(rootfs, rootfs, "bind", UInt(MS_BIND | MS_REC), nil) == 0 else {
            throw App.Errno(stage: "mount(bind|rec)")
        }
    }

    private func setDevSymlinks(rootfs: String) throws {
        let links: [(src: String, dst: String)] = [
            ("/proc/self/fd", "/dev/fd"),
            ("/proc/self/fd/0", "/dev/stdin"),
            ("/proc/self/fd/1", "/dev/stdout"),
            ("/proc/self/fd/2", "/dev/stderr"),
            ("/dev/rtc0", "/dev/rtc"),
        ]

        let rootfsURL = URL(fileURLWithPath: rootfs)
        for (src, dst) in links {
            let dest = rootfsURL.appendingPathComponent(dst)
            guard symlink(src, dest.path) == 0 else {
                if errno == EEXIST {
                    continue
                }
                throw App.Errno(stage: "symlink(\(src) -> \(dest.path))")
            }
        }
    }

    private func reOpenDevNull() throws {
        let file = open("/dev/null", O_RDWR)
        guard file != -1 else {
            throw App.Errno(stage: "open(/dev/null)")
        }
        defer { close(file) }

        var devNullStat = stat()
        try withUnsafeMutablePointer(to: &devNullStat) { pointer in
            guard fstat(file, pointer) == 0 else {
                throw App.Errno(stage: "fstat(/dev/null)")
            }
        }

        for fd: Int32 in 0...2 {
            var fdStat = stat()
            try withUnsafeMutablePointer(to: &fdStat) { pointer in
                guard fstat(fd, pointer) == 0 else {
                    throw App.Errno(stage: "fstat(fd)")
                }
            }

            if fdStat.st_rdev == devNullStat.st_rdev {
                guard dup3(file, fd, 0) != -1 else {
                    throw App.Errno(stage: "dup3(null)")
                }
            }
        }
    }

    /// Pivots the rootfs of the calling process in the namespace to the provided
    /// rootfs in the argument.
    ///
    /// The pivot_root(".", ".") and unmount old root approach is exactly the same
    /// as runc's pivot root implementation in:
    /// https://github.com/opencontainers/runc/blob/main/libcontainer/rootfs_linux.go
    private func pivotRoot(rootfs: String) throws {
        let oldRoot = open("/", O_RDONLY | O_DIRECTORY)
        if oldRoot <= 0 {
            throw App.Errno(stage: "open(oldroot)")
        }
        defer { close(oldRoot) }

        let newRoot = open(rootfs, O_RDONLY | O_DIRECTORY)
        if newRoot <= 0 {
            throw App.Errno(stage: "open(newroot)")
        }
        defer { close(newRoot) }

        // change cwd to the new root
        guard fchdir(newRoot) == 0 else {
            throw App.Errno(stage: "fchdir(newroot)")
        }
        guard CZ_pivot_root(toCString("."), toCString(".")) == 0 else {
            throw App.Errno(stage: "pivot_root()")
        }
        // change cwd to the old root
        guard fchdir(oldRoot) == 0 else {
            throw App.Errno(stage: "fchdir(oldroot)")
        }
        // mount old root rslave so that unmount doesn't propagate back to outside
        // the namespace
        guard mount("", ".", "", UInt(MS_SLAVE | MS_REC), nil) == 0 else {
            throw App.Errno(stage: "mount(., slave|rec)")
        }
        // unmount old root
        guard umount2(".", Int32(MNT_DETACH)) == 0 else {
            throw App.Errno(stage: "umount(.)")
        }
        // switch cwd to the new root
        guard chdir("/") == 0 else {
            throw App.Errno(stage: "chdir(/)")
        }
    }

    private func toCString(_ str: String) -> UnsafeMutablePointer<CChar>? {
        let cString = str.utf8CString
        let cStringCopy = UnsafeMutableBufferPointer<CChar>.allocate(capacity: cString.count)
        _ = cStringCopy.initialize(from: cString)
        return UnsafeMutablePointer(cStringCopy.baseAddress)
    }

    private func mountConsole(path: String) throws {
        let console = "/dev/console"
        if access(console, F_OK) != 0 {
            let fd = open(console, O_RDWR | O_CREAT, mode_t(UInt16(0o600)))
            guard fd != -1 else {
                throw App.Errno(stage: "open(/dev/console)")
            }
            close(fd)
        }

        guard mount(path, console, "bind", UInt(MS_BIND), nil) == 0 else {
            throw App.Errno(stage: "mount(console)")
        }
    }
}
