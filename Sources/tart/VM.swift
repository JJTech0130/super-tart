import Foundation
import Virtualization
import Semaphore
import Dynamic

struct UnsupportedRestoreImageError: Error {
}

struct NoMainScreenFoundError: Error {
}

struct DownloadFailed: Error {
}

struct UnsupportedOSError: Error, CustomStringConvertible {
  let description: String

  init(_ what: String, _ plural: String, _ requires: String = "running macOS 13.0 (Ventura) or newer") {
    description = "error: \(what) \(plural) only supported on hosts \(requires)"
  }
}

struct UnsupportedArchitectureError: Error {
}

class VM: NSObject, VZVirtualMachineDelegate, ObservableObject {
  // Virtualization.Framework's virtual machine
  @Published var virtualMachine: VZVirtualMachine

  // Virtualization.Framework's virtual machine configuration
  var configuration: VZVirtualMachineConfiguration

  // Semaphore used to communicate with the VZVirtualMachineDelegate
  var sema = AsyncSemaphore(value: 0)

  // VM's config
  var name: String

  // VM's config
  var config: VMConfig

  var network: Network

  init(vmDir: VMDirectory,
       network: Network = NetworkShared(),
       additionalStorageDevices: [VZStorageDeviceConfiguration] = [],
       directorySharingDevices: [VZDirectorySharingDeviceConfiguration] = [],
       serialPorts: [VZSerialPortConfiguration] = [],
       suspendable: Bool = false,
       nested: Bool = false,
       audio: Bool = true,
       clipboard: Bool = true,
       sync: VZDiskImageSynchronizationMode = .full,
       caching: VZDiskImageCachingMode? = nil
  ) throws {
    name = vmDir.name
    config = try VMConfig.init(fromURL: vmDir.configURL)

    if config.arch != CurrentArchitecture() {
      throw UnsupportedArchitectureError()
    }

    // Initialize the virtual machine and its configuration
    self.network = network
    configuration = try Self.craftConfiguration(diskURL: vmDir.diskURL,
                                                nvramURL: vmDir.nvramURL, romURL: vmDir.romURL, vmConfig: config,
                                                network: network, additionalStorageDevices: additionalStorageDevices,
                                                directorySharingDevices: directorySharingDevices,
                                                serialPorts: serialPorts,
                                                suspendable: suspendable,
                                                nested: nested,
                                                audio: audio,
                                                clipboard: clipboard,
                                                sync: sync,
                                                caching: caching
    )
    virtualMachine = VZVirtualMachine(configuration: configuration)

    super.init()
    virtualMachine.delegate = self
  }

  static func retrieveIPSW(remoteURL: URL) async throws -> URL {
    // Check if we already have this IPSW in cache
    var headRequest = URLRequest(url: remoteURL)
    headRequest.httpMethod = "HEAD"
    let (_, headResponse) = try await Fetcher.fetch(headRequest, viaFile: false)

    if let hash = headResponse.value(forHTTPHeaderField: "x-amz-meta-digest-sha256") {
      let ipswLocation = try IPSWCache().locationFor(fileName: "sha256:\(hash).ipsw")

      if FileManager.default.fileExists(atPath: ipswLocation.path) {
        defaultLogger.appendNewLine("Using cached *.ipsw file...")
        try ipswLocation.updateAccessDate()

        return ipswLocation
      }
    }

    // Download the IPSW
    defaultLogger.appendNewLine("Fetching \(remoteURL.lastPathComponent)...")

    let request = URLRequest(url: remoteURL)
    let (channel, response) = try await Fetcher.fetch(request, viaFile: true)

    let temporaryLocation = try Config().tartTmpDir.appendingPathComponent(UUID().uuidString + ".ipsw")

    let progress = Progress(totalUnitCount: response.expectedContentLength)
    ProgressObserver(progress).log(defaultLogger)

    FileManager.default.createFile(atPath: temporaryLocation.path, contents: nil)
    let lock = try FileLock(lockURL: temporaryLocation)
    try lock.lock()

    let fileHandle = try FileHandle(forWritingTo: temporaryLocation)
    let digest = Digest()

    for try await chunk in channel {
      try fileHandle.write(contentsOf: chunk)
      digest.update(chunk)
      progress.completedUnitCount += Int64(chunk.count)
    }

    try fileHandle.close()

    let finalLocation = try IPSWCache().locationFor(fileName: digest.finalize() + ".ipsw")

    return try FileManager.default.replaceItemAt(finalLocation, withItemAt: temporaryLocation)!
  }

  var inFinalState: Bool {
    get {
      virtualMachine.state == VZVirtualMachine.State.stopped ||
        virtualMachine.state == VZVirtualMachine.State.paused ||
        virtualMachine.state == VZVirtualMachine.State.error

    }
  }

  #if arch(arm64)
    init(
      vmDir: VMDirectory,
      ipswURL: URL,
      diskSizeGB: UInt16,
      romURL: URL,
      network: Network = NetworkShared(),
      additionalStorageDevices: [VZStorageDeviceConfiguration] = [],
      directorySharingDevices: [VZDirectorySharingDeviceConfiguration] = [],
      serialPorts: [VZSerialPortConfiguration] = []
    ) async throws {
      var ipswURL = ipswURL

      if !ipswURL.isFileURL {
        ipswURL = try await VM.retrieveIPSW(remoteURL: ipswURL)
      }

      // We create a temporary TART_HOME directory in tests, which has its "cache" folder symlinked
      // to the users Tart cache directory (~/.tart/cache). However, the Virtualization.Framework
      // cannot deal with paths that contain symlinks, so expand them here first.
      ipswURL.resolveSymlinksInPath()

      // Load the restore image and try to get the requirements
      // that match both the image and our platform
      let image = try await withCheckedThrowingContinuation { continuation in
        VZMacOSRestoreImage.load(from: ipswURL) { result in
          continuation.resume(with: result)
        }
      }

      guard let requirements = image.mostFeaturefulSupportedConfiguration else {
        throw UnsupportedRestoreImageError()
      }

      // Create NVRAM
      _ = try VZMacAuxiliaryStorage(creatingStorageAt: vmDir.nvramURL, hardwareModel: requirements.hardwareModel)

      // Create disk
      try vmDir.resizeDisk(diskSizeGB)

      name = vmDir.name
      // Create config
      config = VMConfig(
        platform: Darwin(ecid: VZMacMachineIdentifier(), hardwareModel: requirements.hardwareModel),
        cpuCountMin: requirements.minimumSupportedCPUCount,
        memorySizeMin: requirements.minimumSupportedMemorySize
      )
      // allocate at least 4 CPUs because otherwise VMs are frequently freezing
      try config.setCPU(cpuCount: max(4, requirements.minimumSupportedCPUCount))
      try config.save(toURL: vmDir.configURL)
      
      // Copy ROM
      try FileManager.default.copyItem(atPath: romURL.path, toPath: vmDir.romURL.path)

      // Initialize the virtual machine and its configuration
      self.network = network
      configuration = try Self.craftConfiguration(diskURL: vmDir.diskURL, nvramURL: vmDir.nvramURL,
                                                  romURL: vmDir.romURL, vmConfig: config, network: network,
                                                  additionalStorageDevices: additionalStorageDevices,
                                                  directorySharingDevices: directorySharingDevices,
                                                  serialPorts: serialPorts
      )
      virtualMachine = VZVirtualMachine(configuration: configuration)

      super.init()
      virtualMachine.delegate = self

      // Run automated installation
      try await install(ipswURL)
    }

    @MainActor
    private func install(_ url: URL) async throws {
      let installer = VZMacOSInstaller(virtualMachine: self.virtualMachine, restoringFromImageAt: url)
      defaultLogger.appendNewLine("Installing OS...")
      ProgressObserver(installer.progress).log(defaultLogger)

      try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
          installer.install { result in
            continuation.resume(with: result)
          }
        }
      }, onCancel: {
        installer.progress.cancel()
      })
    }
  #endif

  @available(macOS 13, *)
  static func linux(vmDir: VMDirectory, diskSizeGB: UInt16) async throws -> VM {
    // Create NVRAM
    _ = try VZEFIVariableStore(creatingVariableStoreAt: vmDir.nvramURL)

    // Create disk
    try vmDir.resizeDisk(diskSizeGB)

    // Create config
    let config = VMConfig(platform: Linux(), cpuCountMin: 4, memorySizeMin: 4096 * 1024 * 1024)
    try config.save(toURL: vmDir.configURL)

    return try VM(vmDir: vmDir)
  }

  func start(recovery: Bool, resume shouldResume: Bool, vmStartOptions: VMStartOptions) async throws {
    try network.run(sema)

    if shouldResume {
      try await resume()
    } else {
      try await start(recovery, vmStartOptions: vmStartOptions)
    }
  }

  func run() async throws {
    do {
      try await sema.waitUnlessCancelled()
    } catch is CancellationError {
      // Triggered by "tart stop", Ctrl+C, or closing the
      // VM window, so shut down the VM gracefully below.
    }

    if Task.isCancelled {
      if (self.virtualMachine.state == VZVirtualMachine.State.running) {
        print("Stopping VM...")
        try await stop()
      }
    }

    try await network.stop()
  }

  @MainActor
  private func start(_ recovery: Bool, vmStartOptions: VMStartOptions) async throws {
    #if arch(arm64)
      let startOptions = VZMacOSVirtualMachineStartOptions()
      startOptions.startUpFromMacOSRecovery = recovery
      Dynamic(startOptions)._setForceDFU(vmStartOptions.forceDFU)
      Dynamic(startOptions)._setPanicAction(vmStartOptions.stopOnPanic)
      Dynamic(startOptions)._setStopInIBootStage1(vmStartOptions.stopInIBootStage1)
      Dynamic(startOptions)._setStopInIBootStage2(vmStartOptions.stopInIBootStage2)
      try await virtualMachine.start(options: startOptions)
    #else
      try await virtualMachine.start()
    #endif
  }

  @MainActor
  private func resume() async throws {
    try await virtualMachine.resume()
  }

  @MainActor
  private func stop() async throws {
    try await self.virtualMachine.stop()
  }

  static func craftConfiguration(
    diskURL: URL,
    nvramURL: URL,
    romURL: URL,
    vmConfig: VMConfig,
    network: Network = NetworkShared(),
    additionalStorageDevices: [VZStorageDeviceConfiguration],
    directorySharingDevices: [VZDirectorySharingDeviceConfiguration],
    serialPorts: [VZSerialPortConfiguration],
    suspendable: Bool = false,
    nested: Bool = false,
    audio: Bool = true,
    clipboard: Bool = true,
    sync: VZDiskImageSynchronizationMode = .full,
    caching: VZDiskImageCachingMode? = nil
  ) throws -> VZVirtualMachineConfiguration {
    let configuration = VZVirtualMachineConfiguration()

    // Boot loader
    let bootloader = try vmConfig.platform.bootLoader(nvramURL: nvramURL)
    Dynamic(bootloader)._setROMURL(romURL)
    configuration.bootLoader = bootloader

    // CPU and memory
    configuration.cpuCount = vmConfig.cpuCount
    configuration.memorySize = vmConfig.memorySize

    // Platform
    configuration.platform = try vmConfig.platform.platform(nvramURL: nvramURL, needsNestedVirtualization: nested)

    // Display
    configuration.graphicsDevices = [vmConfig.platform.graphicsDevice(vmConfig: vmConfig)]

    // Audio
    let soundDeviceConfiguration = VZVirtioSoundDeviceConfiguration()

    if audio && !suspendable {
      let inputAudioStreamConfiguration = VZVirtioSoundDeviceInputStreamConfiguration()
      let outputAudioStreamConfiguration = VZVirtioSoundDeviceOutputStreamConfiguration()

      inputAudioStreamConfiguration.source = VZHostAudioInputStreamSource()
      outputAudioStreamConfiguration.sink = VZHostAudioOutputStreamSink()

      soundDeviceConfiguration.streams = [inputAudioStreamConfiguration, outputAudioStreamConfiguration]
    } else {
      // just a null speaker
      soundDeviceConfiguration.streams = [VZVirtioSoundDeviceOutputStreamConfiguration()]
    }

    configuration.audioDevices = [soundDeviceConfiguration]

    // Keyboard and mouse
    if suspendable, let platformSuspendable = vmConfig.platform.self as? PlatformSuspendable {
      configuration.keyboards = platformSuspendable.keyboardsSuspendable()
      configuration.pointingDevices = platformSuspendable.pointingDevicesSuspendable()
    } else {
      configuration.keyboards = vmConfig.platform.keyboards()
      configuration.pointingDevices = vmConfig.platform.pointingDevices()
    }

    // Networking
    configuration.networkDevices = network.attachments().map {
      let vio = VZVirtioNetworkDeviceConfiguration()
      vio.attachment = $0
      vio.macAddress = vmConfig.macAddress
      return vio
    }

    // Clipboard sharing via Spice agent
    if clipboard && vmConfig.os == .linux {
      let spiceAgentConsoleDevice = VZVirtioConsoleDeviceConfiguration()
      let spiceAgentPort = VZVirtioConsolePortConfiguration()
      spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
      spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
      spiceAgentConsoleDevice.ports[0] = spiceAgentPort
      configuration.consoleDevices.append(spiceAgentConsoleDevice)
    }

    // Storage
    let attachment: VZDiskImageStorageDeviceAttachment =  try VZDiskImageStorageDeviceAttachment(
      url: diskURL,
      readOnly: false,
      // When not specified, use "cached" caching mode for Linux VMs to prevent file-system corruption[1]
      //
      // [1]: https://github.com/cirruslabs/tart/pull/675
      cachingMode: caching ?? (vmConfig.os == .linux ? .cached : .automatic),
      synchronizationMode: sync
    )

    var devices: [VZStorageDeviceConfiguration] = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
    devices.append(contentsOf: additionalStorageDevices)
    configuration.storageDevices = devices

    // Entropy
    if !suspendable {
      configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    }

    // Directory sharing devices
    configuration.directorySharingDevices = directorySharingDevices

    // Serial Port
    configuration.serialPorts = serialPorts

    // Version console device
    //
    // A dummy console device useful for implementing
    // host feature checks in the guest agent software.
    if !suspendable {
      let consolePort = VZVirtioConsolePortConfiguration()
      consolePort.name = "tart-version-\(CI.version)"

      let consoleDevice = VZVirtioConsoleDeviceConfiguration()
      consoleDevice.ports[0] = consolePort

      configuration.consoleDevices.append(consoleDevice)
    }
      
    // Debug port
    let debugStub = Dynamic._VZGDBDebugStubConfiguration(port: vmConfig.debugPort);
    Dynamic(configuration)._setDebugStub(debugStub);

    // // Serial console
    // let serialPort: VZSerialPortConfiguration = Dynamic._VZPL011SerialPortConfiguration().asObject as! VZSerialPortConfiguration
    // serialPort.attachment = VZFileHandleSerialPortAttachment(
    //   fileHandleForReading: FileHandle.standardInput,
    //   fileHandleForWriting: FileHandle.standardOutput
    // )
    // configuration.serialPorts = [serialPort]

    try configuration.validate()

    return configuration
  }

  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    print("guest has stopped the virtual machine")
    sema.signal()
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    print("guest has stopped the virtual machine due to error: \(error)")
    sema.signal()
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
    print("virtual machine's network attachment \(networkDevice) has been disconnected with error: \(error)")
    sema.signal()
  }
}
