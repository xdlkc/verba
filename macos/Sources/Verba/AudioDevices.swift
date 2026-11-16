import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - System Audio TCC Permission

enum SystemAudioPermission {
    enum Status {
        case unknown
        case granted
        case denied
    }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32

    private static let tccHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY)
            ?? dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY)
    }()

    private static let preflightFn: PreflightFn? = {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    static let serviceKey = "kTCCServiceAudioCapture" as CFString

    static func status() -> Status {
        guard let fn = preflightFn else { return .unknown }
        switch fn(serviceKey, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - CoreAudio Device Enumeration

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channels: UInt32
    let isVirtual: Bool
}

struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    private static let virtualKeywords = [
        "blackhole", "loopback", "soundflower", "background music",
        "existential audio", "microsoft teams audio", "zoomaudiodevice", "multi-output"
    ]

    static func defaultOutput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return (status == noErr && dev != kAudioObjectUnknown) ? dev : nil
    }

    static func defaultInput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return (status == noErr && dev != kAudioObjectUnknown) ? dev : nil
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    static func inputs() -> [InputDevice] {
        allDeviceIDs().compactMap { id in
            let ch = channelCount(device: id, scope: kAudioDevicePropertyScopeInput)
            guard ch > 0, let uid = deviceUID(device: id), let name = deviceName(device: id) else { return nil }
            let lower = name.lowercased()
            let virtual = virtualKeywords.contains { lower.contains($0) }
            return InputDevice(id: id, uid: uid, name: name, channels: ch, isVirtual: virtual)
        }
    }

    static func outputs() -> [OutputDevice] {
        allDeviceIDs().compactMap { id in
            let ch = channelCount(device: id, scope: kAudioDevicePropertyScopeOutput)
            guard ch > 0, let uid = deviceUID(device: id), let name = deviceName(device: id) else { return nil }
            return OutputDevice(id: id, uid: uid, name: name)
        }
    }

    static func roomMicChoices() -> [InputDevice] {
        inputs().filter { !$0.isVirtual }
    }

    static func channelCount(device: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let bufPtr = UnsafeMutableAudioBufferListPointer(list)
        return bufPtr.reduce(0) { $0 + $1.mNumberChannels }
    }

    static func deviceUID(device: AudioDeviceID) -> String? {
        stringProperty(objectID: device, selector: kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(device: AudioDeviceID) -> String? {
        stringProperty(objectID: device, selector: kAudioObjectPropertyName)
    }

    static func processObjectID(pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidVal = pid
        var procObj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &pidVal,
            &size,
            &procObj
        )
        return (status == noErr && procObj != kAudioObjectUnknown) ? procObj : nil
    }

    private static func stringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &cfStr)
        guard status == noErr, let s = cfStr?.takeRetainedValue() else { return nil }
        return s as String
    }
}

// MARK: - CoreAudio Process Tap (No Screen Recording Permission Needed)

final class SystemAudioTap {
    enum TapError: LocalizedError {
        case noOutputDevice
        case tapCreationFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case audioUnitFailed(OSStatus)
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .noOutputDevice: return "未找到默认音频输出设备"
            case .tapCreationFailed(let s): return "创建系统音频 Tap 失败 (\(s))"
            case .aggregateFailed(let s): return "创建聚合音频设备失败 (\(s))"
            case .audioUnitFailed(let s): return "启动音频采集单元失败 (\(s))"
            case .invalidFormat: return "系统音频格式无效"
            }
        }
    }

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var audioUnit: AudioComponentInstance?
    private var renderFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onRateChange: (() -> Void)?
    private var rateListenerBlock: AudioObjectPropertyListenerBlock?
    private var listenedDeviceID: AudioDeviceID = kAudioObjectUnknown

    private static func nominalSampleRate(_ device: AudioObjectID) -> Float64? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        return (status == noErr && rate > 0) ? rate : nil
    }

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onRateChange: @escaping () -> Void
    ) throws {
        stop()
        guard let outID = AudioDevices.defaultOutput(),
              let outUID = AudioDevices.deviceUID(device: outID) else {
            throw TapError.noOutputDevice
        }

        self.onBuffer = onBuffer
        self.onRateChange = onRateChange

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded: [AudioObjectID] = AudioDevices.processObjectID(pid: ownPID).map { [$0] } ?? []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "VerbaSystemTap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &createdTap)
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        self.tapID = createdTap

        // Read tap UID
        var tapUIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfTapUID: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(createdTap, &tapUIDAddr, 0, nil, &uidSize, &cfTapUID) == noErr,
              let tapUID = cfTapUID?.takeRetainedValue() as String? else {
            stop()
            throw TapError.tapCreationFailed(-1)
        }

        let aggUID = "com.verba.tap.\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Verba System Audio",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: tapUID,
                ]
            ],
        ]

        var createdAgg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &createdAgg)
        guard aggStatus == noErr, createdAgg != kAudioObjectUnknown else {
            stop()
            throw TapError.aggregateFailed(aggStatus)
        }
        self.aggregateID = createdAgg

        // Set up HALOutput AudioUnit reading from aggregate device
        var compDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &compDesc) else {
            stop()
            throw TapError.audioUnitFailed(-1)
        }
        var unit: AudioComponentInstance?
        let instErr = AudioComponentInstanceNew(comp, &unit)
        guard instErr == noErr, let unit else {
            stop()
            throw TapError.audioUnitFailed(instErr)
        }
        self.audioUnit = unit

        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        try checkAU(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, 4))
        try checkAU(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput, 4))

        var devID = createdAgg
        try checkAU(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size)))

        // Skip the output device's own input channels (e.g. headset mic channels) so we read only the tap channels
        let outOwnInputChannels = Int32(AudioDevices.channelCount(device: outID, scope: kAudioDevicePropertyScopeInput))
        var streamDesc = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkAU(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &streamDesc, &propSize))

        let desiredChannels: UInt32 = 2
        if outOwnInputChannels > 0 {
            var channelMap: [Int32] = [outOwnInputChannels, outOwnInputChannels + 1]
            _ = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Output,
                1,
                &channelMap,
                UInt32(channelMap.count * MemoryLayout<Int32>.size)
            )
        }

        let unitRate = streamDesc.mSampleRate > 0 ? streamDesc.mSampleRate : 48_000
        let actualRate = Self.nominalSampleRate(createdAgg) ?? Self.nominalSampleRate(outID) ?? unitRate

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: unitRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: desiredChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try checkAU(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        guard let avFormat = AVAudioFormat(streamDescription: &clientFormat),
              let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: actualRate, channels: 1, interleaved: false) else {
            stop()
            throw TapError.invalidFormat
        }
        self.renderFormat = avFormat
        self.monoFormat = monoFmt

        var cbStruct = AURenderCallbackStruct(
            inputProc: Self.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try checkAU(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try checkAU(AudioUnitInitialize(unit))
        try checkAU(AudioOutputUnitStart(unit))

        installRateListener(deviceID: outID)
    }

    private func installRateListener(deviceID: AudioDeviceID) {
        listenedDeviceID = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onRateChange?()
        }
        rateListenerBlock = block
        AudioObjectAddPropertyListenerBlock(deviceID, &addr, DispatchQueue.global(), block)
    }

    private func checkAU(_ status: OSStatus) throws {
        if status != noErr {
            stop()
            throw TapError.audioUnitFailed(status)
        }
    }

    func stop() {
        if let block = rateListenerBlock, listenedDeviceID != kAudioObjectUnknown {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(listenedDeviceID, &addr, DispatchQueue.global(), block)
        }
        rateListenerBlock = nil
        listenedDeviceID = kAudioObjectUnknown

        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        renderFormat = nil
        monoFormat = nil
        onBuffer = nil
        onRateChange = nil
    }

    deinit {
        stop()
    }

    private static let renderCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
        let me = Unmanaged<SystemAudioTap>.fromOpaque(refCon).takeUnretainedValue()
        guard let unit = me.audioUnit, let fmt = me.renderFormat else { return noErr }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: inNumberFrames) else { return noErr }
        pcm.frameLength = inNumberFrames
        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, pcm.mutableAudioBufferList)
        guard status == noErr, pcm.frameLength > 0 else { return status }

        if let monoFmt = me.monoFormat,
           let mono = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: inNumberFrames),
           let src = pcm.floatChannelData,
           let dst = mono.floatChannelData {
            mono.frameLength = inNumberFrames
            let n = Int(inNumberFrames)
            if pcm.format.channelCount >= 2 {
                for i in 0..<n {
                    dst[0][i] = (src[0][i] + src[1][i]) * 0.5
                }
            } else {
                memcpy(dst[0], src[0], n * MemoryLayout<Float>.size)
            }
            me.onBuffer?(mono)
        } else {
            me.onBuffer?(pcm)
        }
        return status
    }
}

// MARK: - Room Microphone Capture

final class RoomMic {
    private var engine: AVAudioEngine?

    func start(deviceID: AudioDeviceID?, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let eng = AVAudioEngine()
        let input = eng.inputNode
        if let devID = deviceID, let unit = input.audioUnit {
            var id = devID
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buffer, _ in
            if buffer.frameLength > 0 {
                onBuffer(buffer)
            }
        }
        eng.prepare()
        try eng.start()
        engine = eng
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    deinit {
        stop()
    }
}

// MARK: - PCM Conversion to 16kHz Mono Float32

final class PCMConverter {
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var lastSourceRate: Double = 0
    private var lastSourceChannels: AVAudioChannelCount = 0

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let srcFmt = input.format
        if srcFmt.sampleRate == targetFormat.sampleRate,
           srcFmt.channelCount == targetFormat.channelCount,
           srcFmt.commonFormat == targetFormat.commonFormat,
           !srcFmt.isInterleaved {
            return input
        }
        if converter == nil || lastSourceRate != srcFmt.sampleRate || lastSourceChannels != srcFmt.channelCount {
            converter = AVAudioConverter(from: srcFmt, to: targetFormat)
            lastSourceRate = srcFmt.sampleRate
            lastSourceChannels = srcFmt.channelCount
        }
        guard let conv = converter else { return nil }
        let ratio = targetFormat.sampleRate / max(srcFmt.sampleRate, 1)
        let outCap = max(AVAudioFrameCount(Double(input.frameLength) * ratio) + 64, 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return nil }

        var fed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || err != nil || out.frameLength == 0 {
            return nil
        }
        return out
    }
}

// MARK: - Crash-Safe Audio File Writer (.caf -> .m4a Mix Export)

final class AudioFileWriter {
    private let folder: URL
    private let systemCAF: URL
    private let roomCAF: URL
    private let finalM4A: URL

    private var sysFile: AVAudioFile?
    private var roomFile: AVAudioFile?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var framesWritten: AVAudioFramePosition = 0

    init(folder: URL) {
        self.folder = folder
        self.systemCAF = folder.appendingPathComponent("system.caf")
        self.roomCAF = folder.appendingPathComponent("room.caf")
        self.finalM4A = folder.appendingPathComponent("system.m4a")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func appendSystem(_ buffer: AVAudioPCMBuffer, elapsedFrames targetFrame: AVAudioFramePosition) {
        if sysFile == nil {
            sysFile = try? AVAudioFile(forWriting: systemCAF, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        guard let file = sysFile else { return }
        if targetFrame > framesWritten + 320 {
            let gap = AVAudioFrameCount(min(targetFrame - framesWritten, 16_000 * 30))
            if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: gap) {
                silence.frameLength = gap
                try? file.write(from: silence)
                framesWritten += AVAudioFramePosition(gap)
            }
        }
        try? file.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    func appendRoom(_ buffer: AVAudioPCMBuffer) {
        if roomFile == nil {
            roomFile = try? AVAudioFile(forWriting: roomCAF, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        try? roomFile?.write(from: buffer)
    }

    func finish() async -> Bool {
        sysFile = nil
        roomFile = nil

        let fm = FileManager.default
        let hasSys = fm.fileExists(atPath: systemCAF.path)
        let hasRoom = fm.fileExists(atPath: roomCAF.path)
        guard hasSys || hasRoom else { return false }

        let comp = AVMutableComposition()
        if hasSys {
            let asset = AVURLAsset(url: systemCAF)
            if let track = try? await asset.loadTracks(withMediaType: .audio).first,
               let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let dur = (try? await asset.load(.duration)) ?? .zero
                try? dst.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: track, at: .zero)
            }
        }
        if hasRoom {
            let asset = AVURLAsset(url: roomCAF)
            if let track = try? await asset.loadTracks(withMediaType: .audio).first,
               let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let dur = (try? await asset.load(.duration)) ?? .zero
                try? dst.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: track, at: .zero)
            }
        }

        try? fm.removeItem(at: finalM4A)
        guard let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        exporter.outputURL = finalM4A
        exporter.outputFileType = .m4a
        await exporter.export()

        let ok = exporter.status == .completed && fm.fileExists(atPath: finalM4A.path)
        if ok {
            try? fm.removeItem(at: systemCAF)
            try? fm.removeItem(at: roomCAF)
        }
        return ok
    }
}

// MARK: - VAD & Echo Suppression

final class VoiceActivity {
    private var noiseFloor: Float = 0.0025

    func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n {
            let v = ch[i]
            sum += v * v
        }
        return sqrtf(sum / Float(n))
    }

    func hasSpeech(_ buffer: AVAudioPCMBuffer) -> Bool {
        let level = rms(buffer)
        if level < noiseFloor * 1.4 {
            noiseFloor = noiseFloor * 0.96 + level * 0.04
        }
        let threshold = max(0.004, noiseFloor * 2.4)
        return level >= threshold
    }
}

final class EchoGate {
    private var lastSystemRMS: Float = 0
    private var lastSystemAt: Date = .distantPast

    func noteSystemLevel(_ rms: Float) {
        if rms > 0.01 {
            lastSystemRMS = rms
            lastSystemAt = Date()
        }
    }

    func shouldAcceptRoom(rms: Float) -> Bool {
        if Date().timeIntervalSince(lastSystemAt) < 0.25 {
            return rms > max(0.018, lastSystemRMS * 1.35)
        }
        return true
    }
}

// MARK: - Audio Router & Language Replay Ring Buffer

final class AudioRouter {
    private let queue = DispatchQueue(label: "com.verba.audiorouter")
    private let sysConverter = PCMConverter()
    private let roomConverter = PCMConverter()
    private let sysVAD = VoiceActivity()
    private let roomVAD = VoiceActivity()
    private let echoGate = EchoGate()
    private var writer: AudioFileWriter?
    private var startDate = Date()

    // Ring buffer of recent 16kHz system samples (~2.5s = 40,000 samples) for language switch replay
    private var ring = [Float](repeating: 0, count: 40_000)
    private var ringWrite = 0
    private var ringFilled = 0

    var onSystemPCM: ((AVAudioPCMBuffer) -> Void)?
    var onRoomPCM: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    func beginSession(folder: URL) {
        queue.sync {
            startDate = Date()
            writer = AudioFileWriter(folder: folder)
            ring = [Float](repeating: 0, count: 40_000)
            ringWrite = 0
            ringFilled = 0
        }
    }

    func pushSystem(_ raw: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let pcm = self.sysConverter.convert(raw) else { return }
            let lvl = self.sysVAD.rms(pcm)
            self.echoGate.noteSystemLevel(lvl)
            self.onLevel?(lvl)
            let elapsed = AVAudioFramePosition(max(0, Date().timeIntervalSince(self.startDate)) * 16_000.0)
            self.writer?.appendSystem(pcm, elapsedFrames: elapsed)
            self.recordRing(pcm)
            self.onSystemPCM?(pcm)
        }
    }

    func pushRoom(_ raw: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let pcm = self.roomConverter.convert(raw) else { return }
            let lvl = self.roomVAD.rms(pcm)
            guard self.echoGate.shouldAcceptRoom(rms: lvl) else { return }
            self.writer?.appendRoom(pcm)
            self.onRoomPCM?(pcm)
        }
    }

    func recentSystemSamples() -> [Float] {
        // Explicit closure return type avoids Swift 6.4 tuple/inference crash in DispatchQueue.sync
        queue.sync { () -> [Float] in
            guard ringFilled > 0 else { return [] }
            let cap = ring.count
            if ringFilled < cap {
                return Array(ring[0..<ringFilled])
            }
            return Array(ring[ringWrite..<cap]) + Array(ring[0..<ringWrite])
        }
    }

    func finishSession() async -> Bool {
        let w: AudioFileWriter? = queue.sync { () -> AudioFileWriter? in
            let current = writer
            writer = nil
            return current
        }
        guard let w else { return false }
        return await w.finish()
    }

    private func recordRing(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        let cap = ring.count
        for i in 0..<n {
            ring[ringWrite] = ch[i]
            ringWrite = (ringWrite + 1) % cap
            if ringFilled < cap { ringFilled += 1 }
        }
    }
}
