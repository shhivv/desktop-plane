import Foundation
import Virtualization

/// Builds VM configurations. The build-time configuration (`.build`) and the runtime one
/// (`.runtime`) differ only in what connects the VM to the outside:
///
/// - build: NAT network (to install arc-cua) and a read-only share with the guest tools.
/// - runtime: a dead-end NIC owned by this process, a vsock device, and nothing else shared.
///   No shared folders, clipboard, audio, USB or Rosetta.
enum VMFactory {
    enum Purpose {
        case build(tools: URL)
        case runtime(nic: FileHandle)
    }

    static let display = (width: 1440, height: 900, ppi: 80)

    @MainActor
    static func configuration(image: VMImage, disk: URL, aux: URL, cpus: Int, memoryGB: Int,
                              purpose: Purpose) throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = try image.hardwareModel()
        platform.machineIdentifier = try image.machineIdentifier()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: aux)
        c.platform = platform
        c.bootLoader = VZMacOSBootLoader()

        c.cpuCount = min(max(cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                         VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        c.memorySize = min(max(UInt64(memoryGB) << 30, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                           VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let gfx = VZMacGraphicsDeviceConfiguration()
        gfx.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: display.width,
                                                          heightInPixels: display.height,
                                                          pixelsPerInch: display.ppi)]
        c.graphicsDevices = [gfx]
        c.keyboards = [VZMacKeyboardConfiguration()]
        c.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false,
                                                                    cachingMode: .automatic,
                                                                    synchronizationMode: .full)
        c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        let net = VZVirtioNetworkDeviceConfiguration()
        guard let mac = VZMACAddress(string: image.meta.macAddress) else { throw PlaneError("bad MAC in image") }
        net.macAddress = mac
        switch purpose {
        case .build(let tools):
            net.attachment = VZNATNetworkDeviceAttachment()
            let share = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: tools, readOnly: true))
            c.directorySharingDevices = [share]
        case .runtime(let nic):
            net.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: nic)
            // An empty USB controller, part of the snapshot, so a session's data volume can be
            // plugged in after restore without changing the restored configuration.
            if #available(macOS 15.0, *) {
                c.usbControllers = [VZXHCIControllerConfiguration()]
            }
        }
        c.networkDevices = [net]

        try c.validate()
        return c
    }
}
