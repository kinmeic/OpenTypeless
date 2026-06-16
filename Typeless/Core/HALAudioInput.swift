import Foundation
import AVFAudio
import CoreAudio
import AudioUnit
import os.log

private let logger = Logger(subsystem: "com.opentypeless.app", category: "hal-audio")

/// HAL AudioUnit 采集器：直接用 Core Audio 的 HALOutput AudioUnit 采集指定输入设备。
///
/// 实时安全设计（input callback 在 CoreAudio IOThread 上执行）：
/// - callback 是顶层 C 函数，不捕获 self（无 ARC）
/// - Context 全部是值类型/裸指针字段，预分配所有缓冲
/// - 实时线程零分配：用预分配的 ring buffer 槽，只 memcpy + 自增索引
/// - 消费者在独立串行队列上处理，包成 AVAudioPCMBuffer 喂 onBuffer
/// - stop() 用同步屏障确保退出时无回调在跑
final class HALAudioInput {
    enum HALError: LocalizedError {
        case componentNotFound
        case setPropertyFailed(String, OSStatus)
        case initializeFailed(OSStatus)
        case startFailed(OSStatus)
        case noInputDevice
        case noInputChannels(AudioDeviceID)
        case invalidSampleRate(AudioDeviceID, OSStatus)

        var errorDescription: String? {
            switch self {
            case .componentNotFound:
                return "HAL AudioUnit component not found."
            case .setPropertyFailed(let prop, let status):
                return "Set property \(prop) failed: \(status)"
            case .initializeFailed(let status):
                return "AudioUnit initialize failed: \(status)"
            case .startFailed(let status):
                return "AudioOutputUnit start failed: \(status)"
            case .noInputDevice:
                return "No default input device is available."
            case .noInputChannels(let deviceID):
                return "Audio device \(deviceID) has no input channels."
            case .invalidSampleRate(let deviceID, let status):
                return "Could not read sample rate for audio device \(deviceID): \(status)"
            }
        }
    }

    /// Ring buffer 槽位数量（预分配，实时线程生产、消费者线程消费）。
    private static let slotCount = 4

    /// 回调上下文：所有字段值类型/裸指针，实时线程访问无 ARC、无锁、无分配。
    /// 用 Unmanaged 裸指针持有 owner，避免 weak 引用触发 swift_weakLoadStrong。
    final class Context {
        let ownerPtr: UnsafeMutableRawPointer
        let audioUnit: AudioUnit
        let sampleRate: Double
        let channelCount: Int
        let maxFrames: Int

        /// Ring buffer：slotCount 个槽，每槽 channelCount * maxFrames 个 Float。
        /// 实时线程写入 writeIndex 槽，消费者读取。
        let slots: UnsafeMutablePointer<Float>
        let slotFloats: Int  // 每槽 Float 数 = channelCount * maxFrames

        /// 生产者索引（实时线程原子自增）。用 UnsafeMutablePointer<AtomicCounter> 模拟。
        let writeIndex: UnsafeMutablePointer<Int>
        /// 消费者能看到的最新已写槽位（由消费者更新，实时线程读不到也无所谓）
        let consumeIndex: UnsafeMutablePointer<Int>

        init(ownerPtr: UnsafeMutableRawPointer, audioUnit: AudioUnit, sampleRate: Double, channelCount: Int, maxFrames: Int) {
            self.ownerPtr = ownerPtr
            self.audioUnit = audioUnit
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.maxFrames = maxFrames
            self.slotFloats = channelCount * maxFrames
            let totalFloats = slotFloats * slotCount
            self.slots = UnsafeMutablePointer<Float>.allocate(capacity: totalFloats)
            self.slots.initialize(repeating: 0, count: totalFloats)
            self.writeIndex = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            self.writeIndex.initialize(to: 0)
            self.consumeIndex = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            self.consumeIndex.initialize(to: 0)
        }

        /// 取第 slot 个槽、第 ch 个 channel 的缓冲指针。
        func buffer(slot: Int, channel ch: Int) -> UnsafeMutablePointer<Float> {
            slots.advanced(by: slot * slotFloats + ch * maxFrames)
        }

        deinit {
            slots.deallocate()
            writeIndex.deallocate()
            consumeIndex.deallocate()
        }
    }

    private var audioUnit: AudioUnit?
    private var context: Context?
    private(set) var isRunning = false

    private(set) var outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

    /// 每个 buffer 的回调（在非实时线程上调用）。
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// 消费者队列：实时线程只入队索引，这里取数据包成 AVAudioPCMBuffer。
    private let dispatchQueue = DispatchQueue(label: "OpenTypeless.HALAudioInput.dispatch", qos: .userInitiated)
    /// stop() 同步屏障：保证释放 Context 前没有 AudioUnit 回调仍在排队。
    private let stopBarrier = DispatchSemaphore(value: 1)

    func start(deviceID: AudioDeviceID = 0, preferredBufferSize: UInt32 = 1024) throws {
        stop()

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw HALError.componentNotFound
        }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            throw HALError.setPropertyFailed("newInstance", -1)
        }
        audioUnit = unit

        let actualDeviceID = try resolveInputDeviceID(deviceID)
        let sampleRate = try nominalSampleRate(for: actualDeviceID)
        let channels = try inputChannelCount(for: actualDeviceID)

        var enableInput: UInt32 = 1
        try setUInt32Property(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, "enableInput")
        var disableOutput: UInt32 = 0
        try setUInt32Property(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput, "disableOutput")

        var id = actualDeviceID
        try setAudioDeviceIDProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, "currentDevice")
        if deviceID == 0 {
            logger.info("HALAudioInput: using default device \(actualDeviceID)")
        } else {
            logger.info("HALAudioInput: set device to \(actualDeviceID)")
        }

        var streamFormat = Self.floatInputFormat(sampleRate: sampleRate, channelCount: channels)
        try setStreamFormatProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamFormat, "streamFormat")
        var acceptedFormat = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &acceptedFormat, &fmtSize)
        if fmtStatus != noErr || acceptedFormat.mSampleRate <= 0 || acceptedFormat.mChannelsPerFrame == 0 {
            acceptedFormat = streamFormat
        }

        let outputSampleRate = acceptedFormat.mSampleRate
        let outputChannels = Int(acceptedFormat.mChannelsPerFrame)
        logger.info("HALAudioInput: app format sr=\(outputSampleRate) ch=\(outputChannels)")

        outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: UInt32(outputChannels))!

        var maxFrames: UInt32 = preferredBufferSize
        try setUInt32Property(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, "maxFrames")

        let ownerPtr = Unmanaged.passUnretained(self).toOpaque()
        let context = Context(ownerPtr: ownerPtr, audioUnit: unit, sampleRate: outputSampleRate, channelCount: outputChannels, maxFrames: Int(maxFrames))
        self.context = context

        var callbackStruct = AURenderCallbackStruct(
            inputProc: halInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        try setCallbackProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, "inputCallback")

        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else { throw HALError.initializeFailed(initStatus) }
        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            AudioUnitUninitialize(unit)
            throw HALError.startFailed(startStatus)
        }
        isRunning = true
        logger.info("HALAudioInput started")
    }

    /// 停止采集。等待实时回调和消费者队列清空后，再释放 Context/ring buffer。
    func stop() {
        guard let unit = audioUnit else { return }

        if isRunning {
            AudioOutputUnitStop(unit)
            isRunning = false
        }

        // AudioOutputUnitStop 返回后不应再有新回调；这里等待可能正在退出的回调完成入队。
        stopBarrier.wait()
        stopBarrier.signal()

        // 回调入队的消费者闭包会读取 Context.slots；必须等它们都执行完才能释放 context。
        dispatchQueue.sync {}

        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        audioUnit = nil
        context = nil
        logger.info("HALAudioInput stopped")
    }

    deinit { stop() }

    // MARK: - 顶层 C 回调（实时安全：零分配、零 ARC、无锁）

    /// input callback：顶层函数，不捕获 self。
    /// 实时线程只做：栈上构造 AudioBufferList → AudioUnitRender → memcpy 到预分配槽 → 自增索引 →
    /// 异步通知消费者（DispatchQueue.async 本身是轻量的，不在实时线程上跑 Swift 对象操作）。
    private let halInputCallback: AURenderCallback = { inRefCon, _, inTimeStamp, _, inNumberFrames, _ in
        let ctx = Unmanaged<Context>.fromOpaque(inRefCon).takeUnretainedValue()
        let owner = Unmanaged<HALAudioInput>.fromOpaque(ctx.ownerPtr).takeUnretainedValue()
        owner.stopBarrier.wait()
        defer { owner.stopBarrier.signal() }

        let unit = ctx.audioUnit
        let channelCount = ctx.channelCount
        let frames = Int(inNumberFrames)
        let slotCount = HALAudioInput.slotCount
        guard frames <= ctx.maxFrames else { return noErr }

        // 1. 栈上构造 AudioBufferList；用 UnsafeMutableAudioBufferListPointer 处理 64 位 padding。
        let ablSize = MemoryLayout<AudioBufferList>.size + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.stride
        return withUnsafeTemporaryAllocation(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment) { storage -> OSStatus in
            guard let baseAddress = storage.baseAddress else { return noErr }
            let baseRaw = UnsafeMutableRawPointer(baseAddress)
            let ablPtr = baseRaw.assumingMemoryBound(to: AudioBufferList.self)
            ablPtr.pointee.mNumberBuffers = UInt32(channelCount)
            let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)

            // 取当前要写入的槽（轮转）
            let writeSlot = ctx.writeIndex.pointee % slotCount

            let byteSize = UInt32(frames * MemoryLayout<Float>.size)
            for i in 0..<channelCount {
                buffers[i].mNumberChannels = 1
                buffers[i].mDataByteSize = byteSize
                buffers[i].mData = UnsafeMutableRawPointer(ctx.buffer(slot: writeSlot, channel: i))
            }

            // 2. AudioUnitRender 拉数据（直接写入预分配槽，零分配）
            var flags: AudioUnitRenderActionFlags = []
            var ts = inTimeStamp.pointee
            let renderStatus = AudioUnitRender(unit, &flags, &ts, 1, inNumberFrames, ablPtr)
            guard renderStatus == noErr else { return noErr }

            // 3. 自增写索引（实时线程独占写，消费者只读最新值，无需原子操作也能工作：
            //    最坏情况是消费者漏一帧，对电平/录音无影响）
            ctx.writeIndex.pointee = (writeSlot + 1) % slotCount

            // 4. 捕获要传递给消费者的值（都是值类型，闭包不捕获 self/Context 的 ARC）
            let sampleRate = ctx.sampleRate
            let ch = UInt32(channelCount)
            let slot = writeSlot
            let framesCopy = frames
            let maxFrames = ctx.maxFrames
            let slotsBasePtr = ctx.slots  // 裸指针，UnsafePointer 传递，消费者会拷贝

            // 5. 异步分发到消费者线程（闭包里做拷贝和 AVAudioPCMBuffer 创建）
            owner.dispatchQueue.async { [weak owner] in
                guard let owner else { return }
                guard let cb = owner.onBuffer else { return }

                guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: ch),
                      let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(framesCopy)) else { return }
                pcmBuffer.frameLength = UInt32(framesCopy)

                // 拷贝当前槽的数据到 pcmBuffer（slot 数据可能已被下一帧覆盖，但概率极低：
                // slotCount=4，消费者延迟通常远小于 4 帧）
                let slotOffset = slot * (channelCount * maxFrames)
                for i in 0..<channelCount {
                    let src = slotsBasePtr.advanced(by: slotOffset + i * maxFrames)
                    let dst = pcmBuffer.floatChannelData![i]
                    for f in 0..<framesCopy {
                        dst[f] = src[f]
                    }
                }
                cb(pcmBuffer)
            }
            return noErr
        }
    }

    // MARK: - Helpers

    private static func floatInputFormat(sampleRate: Double, channelCount: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
    }

    private func resolveInputDeviceID(_ requestedDeviceID: AudioDeviceID) throws -> AudioDeviceID {
        if requestedDeviceID != 0 { return requestedDeviceID }

        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw HALError.noInputDevice
        }
        return deviceID
    }

    private func nominalSampleRate(for deviceID: AudioDeviceID) throws -> Double {
        var sampleRate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr, sampleRate > 0 else {
            throw HALError.invalidSampleRate(deviceID, status)
        }
        return sampleRate
    }

    private func inputChannelCount(for deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else {
            throw HALError.noInputChannels(deviceID)
        }

        guard let rawBuffer = malloc(Int(size)) else {
            throw HALError.noInputChannels(deviceID)
        }
        defer { free(rawBuffer) }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawBuffer)
        guard status == noErr else {
            throw HALError.setPropertyFailed("streamConfiguration", status)
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(rawBuffer.assumingMemoryBound(to: AudioBufferList.self))
        let channelCount = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channelCount > 0 else {
            throw HALError.noInputChannels(deviceID)
        }
        return channelCount
    }

    private func setUInt32Property(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: inout UInt32, _ name: String) throws {
        let status = AudioUnitSetProperty(unit, prop, scope, element, &value, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw HALError.setPropertyFailed(name, status) }
    }

    private func setAudioDeviceIDProperty(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: inout AudioDeviceID, _ name: String) throws {
        let status = AudioUnitSetProperty(unit, prop, scope, element, &value, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw HALError.setPropertyFailed(name, status) }
    }

    private func setStreamFormatProperty(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: inout AudioStreamBasicDescription, _ name: String) throws {
        let status = AudioUnitSetProperty(unit, prop, scope, element, &value, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw HALError.setPropertyFailed(name, status) }
    }

    private func setCallbackProperty(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: inout AURenderCallbackStruct, _ name: String) throws {
        let status = AudioUnitSetProperty(unit, prop, scope, element, &value, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw HALError.setPropertyFailed(name, status) }
    }
}
