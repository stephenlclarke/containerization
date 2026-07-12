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

import ContainerizationOCI
import Foundation

/// Virtual graphics configuration for a Linux VM.
public enum GraphicsConfiguration: Sendable, Equatable {
    /// Do not attach a graphics device.
    case disabled
    /// Attach a virtio-gpu device using the default VZ-required scanout.
    case deviceOnly
    /// Attach a virtio-gpu device with one scanout/display.
    case display(widthInPixels: Int = 1920, heightInPixels: Int = 1080)

    public var isEnabled: Bool {
        switch self {
        case .disabled:
            return false
        case .deviceOnly, .display:
            return true
        }
    }

    public var hasDisplay: Bool {
        if case .display = self {
            return true
        }
        return false
    }
}

/// Destination for boot log (serial console) output.
public struct BootLog: Sendable {
    /// The underlying representation of the boot log destination.
    internal enum Representation: Sendable {
        case file(path: URL, append: Bool)
        case fileHandle(FileHandle)
    }

    internal var base: Representation

    /// Write boot logs to a file at the specified path.
    ///
    /// - Parameters:
    ///   - path: The URL of the file to write boot logs to.
    ///   - append: Whether to append to an existing file or overwrite it. Defaults to true.
    ///
    /// - Returns: A boot log destination that writes to a file.
    public static func file(path: URL, append: Bool = true) -> BootLog {
        self.init(base: .file(path: path, append: append))
    }

    /// Write boot logs to a file handle.
    ///
    /// - Parameter fileHandle: The file handle to write boot logs to.
    ///
    /// - Returns: A boot log destination that writes to a file handle.
    public static func fileHandle(_ fileHandle: FileHandle) -> BootLog {
        self.init(base: .fileHandle(fileHandle))
    }
}

/// Protocol for VM creation configuration. Allows VMMs to extend with specific settings
/// while maintaining a common core configuration.
public protocol VMCreationConfig: Sendable {
    /// The common VM configuration that all VMMs must support.
    var configuration: VMConfiguration { get }
}

/// Standard VM creation configuration with only common settings.
public struct StandardVMConfig: VMCreationConfig {
    public var configuration: VMConfiguration

    public init(configuration: VMConfiguration) {
        self.configuration = configuration
    }
}

/// Configuration for creating a virtual machine instance.
public struct VMConfiguration: Sendable {
    /// The amount of CPUs to allocate.
    public var cpus: Int
    /// The memory in bytes to allocate.
    public var memoryInBytes: UInt64
    /// The network interfaces to attach.
    public var interfaces: [any Interface]
    /// Mounts organized by metadata ID (e.g. container ID).
    /// Each ID maps to an array of mounts for that workload.
    public var mountsByID: [String: [Mount]]
    /// Optional destination for serial boot logs.
    public var bootLog: BootLog?
    /// Enable nested virtualization support. If the VirtualMachineManager
    /// does not support this feature, it MUST return an .unsupported ContainerizationError.
    public var nestedVirtualization: Bool
    /// Extension objects that participate in the VM instance lifecycle.
    /// Extension packages append their types here; VZ-aware extensions
    /// should conform to ``VZInstanceExtension``.
    public var extensions: [any Sendable] = []
    /// Virtual graphics device configuration.
    public var graphics: GraphicsConfiguration
    /// Enable virtio-gpu device.
    public var graphicsDevice: Bool {
        get { self.graphics.isEnabled }
        set {
            self.graphics = newValue ? .deviceOnly : .disabled
        }
    }
    /// Enable graphical output (scanout) for the virtio-gpu device.
    public var graphicsDisplay: Bool {
        get { self.graphics.hasDisplay }
        set {
            if newValue {
                self.graphics = .display()
            } else if self.graphics.isEnabled {
                self.graphics = .deviceOnly
            } else {
                self.graphics = .disabled
            }
        }
    }

    public init(
        cpus: Int = 4,
        memoryInBytes: UInt64 = 1024 * 1024 * 1024,
        interfaces: [any Interface] = [],
        mountsByID: [String: [Mount]] = [:],
        bootLog: BootLog? = nil,
        nestedVirtualization: Bool = false,
        graphicsDevice: Bool = false,
        graphicsDisplay: Bool = false,
        graphics: GraphicsConfiguration? = nil
    ) {
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
        self.interfaces = interfaces
        self.mountsByID = mountsByID
        self.bootLog = bootLog
        self.nestedVirtualization = nestedVirtualization
        self.graphics = graphics ?? (graphicsDisplay ? .display() : (graphicsDevice ? .deviceOnly : .disabled))
    }
}
