// voice-audio-bridge — DJiPhone Kit 通话音频桥（macOS）
//
// 模式 1（默认，App 通话）：
//   模块 UAC "AC Interface"(8kHz, 蜂窝→Mac) → Mac 默认输出（扬声器）
//   Mac 默认输入（麦克风）→ 模块 UAC "AS Interface"(8kHz, Mac→蜂窝)
//
// 模式 2（--fifo-rx/--fifo-tx，CellBridge SIP 网关）：
//   蜂窝音频（AC Interface）→ s16le 8k mono 写入 rx FIFO（网关读）
//   tx FIFO（网关写）→ 蜂窝（AS Interface）
//   对应 CellBridge voice.backend=raw-pcm（rx_path/tx_path）。
//
// 退出：SIGTERM/SIGINT 时干净停止。

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - 环形缓冲（单写单读，锁保护足够）
final class RingBuffer {
    private var buf: [Float]
    private var r = 0
    private var w = 0
    private let lock = NSLock()
    private let capacity: Int

    init(capacity: Int = 1 << 16) {
        self.capacity = capacity
        self.buf = [Float](repeating: 0, count: capacity)
    }

    func write(_ data: UnsafePointer<Float>, count n: Int) {
        lock.lock()
        for i in 0..<n {
            let next = (w + 1) % capacity
            if next == r { r = (r + 1) % capacity }  // 满则丢最旧
            buf[w] = data[i]
            w = next
        }
        lock.unlock()
    }

    func read(_ out: UnsafeMutablePointer<Float>, count n: Int) -> Int {
        lock.lock()
        var got = 0
        while got < n && r != w {
            out[got] = buf[r]
            r = (r + 1) % capacity
            got += 1
        }
        lock.unlock()
        return got
    }
}

// MARK: - CoreAudio 工具
func getDevices() -> [(id: AudioDeviceID, name: String)] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    guard status == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    guard status == noErr else { return [] }
    var result: [(AudioDeviceID, String)] = []
    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: CFString? = nil
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &cfName) == noErr,
           let n = cfName as String? {
            result.append((id, n))
        }
    }
    return result
}

func findDevice(matching needle: String) -> AudioDeviceID? {
    for (id, name) in getDevices() where name.localizedCaseInsensitiveContains(needle) {
        return id
    }
    return nil
}

func defaultDevice(_ scope: AudioObjectPropertyScope) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: scope == kAudioObjectPropertyScopeOutput
            ? kAudioHardwarePropertyDefaultOutputDevice
            : kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else {
        return nil
    }
    return id
}

let SAMPLE_RATE: Float64 = 8000

func makeFloatFormat() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: SAMPLE_RATE,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1,
        mBytesPerFrame: 4, mChannelsPerFrame: 1,
        mBitsPerChannel: 32, mReserved: 0)
}

func makeS16Format() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: SAMPLE_RATE,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1,
        mBytesPerFrame: 2, mChannelsPerFrame: 1,
        mBitsPerChannel: 16, mReserved: 0)
}

// HAL 单元：enableInput 开 element 1 的输入捕获，enableOutput 开 element 0 的输出。
func makeHALUnit(device: AudioDeviceID, enableInput: Bool, enableOutput: Bool) -> AudioUnit? {
    var au: AudioUnit?
    var comp = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    guard let compRef = AudioComponentFindNext(nil, &comp) else { return nil }
    guard AudioComponentInstanceNew(compRef, &au) == noErr, let au = au else { return nil }

    var one: UInt32 = 1, zero: UInt32 = 0
    AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
    AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))
    if enableOutput {
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, UInt32(MemoryLayout<UInt32>.size))
    }
    if !enableInput {
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, UInt32(MemoryLayout<UInt32>.size))
    }

    var dev = device
    guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
        AudioComponentInstanceDispose(au)
        return nil
    }
    return au
}

func setClientFormat(_ au: AudioUnit, _ fmt: UnsafePointer<AudioStreamBasicDescription>) -> Bool {
    return AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
}

func setInputFormat(_ au: AudioUnit, _ fmt: UnsafePointer<AudioStreamBasicDescription>) -> Bool {
    return AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
}

typealias AUProc = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<AudioUnitRenderActionFlags>, UnsafePointer<AudioTimeStamp>, UInt32, UInt32, UnsafeMutablePointer<AudioBufferList>?) -> OSStatus

func installCallback(_ au: AudioUnit, _ refCon: UnsafeMutableRawPointer, proc: AUProc, isInput: Bool) -> Bool {
    var cb = AURenderCallbackStruct(inputProc: proc, inputProcRefCon: refCon)
    if isInput {
        return AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
    }
    return AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
}

// MARK: - 模式 1：App 通话桥（扬声器 + 麦克风）
final class Channel {
    let ring = RingBuffer()
    var inputUnit: AudioUnit?
    var outputUnit: AudioUnit?
    let label: String
    var totalFrames: UInt64 = 0
    let scratch = RenderScratch()

    init(label: String) { self.label = label }
}

// MARK: - 输入渲染工具
// HALOutput 的输入回调里 ioData 为 nil，必须自备 AudioBufferList 调 AudioUnitRender。
final class RenderScratch {
    var buf: UnsafeMutableRawPointer?
    var bytes = 0
    var lastStatus: OSStatus = 0

    func ensure(_ want: Int) {
        if buf == nil || bytes < want {
            buf?.deallocate()
            buf = UnsafeMutableRawPointer.allocate(byteCount: want, alignment: 16)
            bytes = want
        }
    }

    func render(_ unit: AudioUnit, _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ inTimeStamp: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32, itemSize: Int) -> UnsafeMutableRawPointer? {
        ensure(Int(frames) * itemSize)
        guard let p = buf else { return nil }
        let abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { abl.deallocate() }
        abl.pointee.mNumberBuffers = 1
        abl.pointee.mBuffers.mNumberChannels = 1
        abl.pointee.mBuffers.mDataByteSize = UInt32(Int(frames) * itemSize)
        abl.pointee.mBuffers.mData = p
        let st = AudioUnitRender(unit, ioActionFlags, inTimeStamp, bus, frames, abl)
        lastStatus = st
        return st == noErr ? p : nil
    }
}

private func channelInputCallback(_ inRefCon: UnsafeMutableRawPointer, _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ inTimeStamp: UnsafePointer<AudioTimeStamp>, _ inBusNumber: UInt32, _ inNumberFrames: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let ch = Unmanaged<Channel>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = ch.inputUnit, let p = ch.scratch.render(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, itemSize: 4) else {
        return noErr
    }
    let floats = p.assumingMemoryBound(to: Float.self)
    ch.ring.write(floats, count: Int(inNumberFrames))
    ch.totalFrames += UInt64(inNumberFrames)
    return noErr
}

private func channelRenderCallback(_ inRefCon: UnsafeMutableRawPointer, _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ inTimeStamp: UnsafePointer<AudioTimeStamp>, _ inBusNumber: UInt32, _ inNumberFrames: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let ch = Unmanaged<Channel>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ablPtr = ioData else { return -1 }
    let bufPtr = ablPtr.pointee.mBuffers
    guard let data = bufPtr.mData else { return -1 }
    let floats = data.assumingMemoryBound(to: Float.self)
    let got = ch.ring.read(floats, count: Int(inNumberFrames))
    if got < Int(inNumberFrames) {
        for i in got..<Int(inNumberFrames) { floats[i] = 0 }  // 欠载补零
    }
    return noErr
}

func runBridgeMode(acDevice: AudioDeviceID, asDevice: AudioDeviceID, macIn: AudioDeviceID, macOut: AudioDeviceID, verbose: Bool) {
    let down = Channel(label: "cellular->mac")   // AC 蜂窝进 Mac 扬声器
    let up = Channel(label: "mac->cellular")     // 麦克风进 AS 蜂窝

    var fmt = makeFloatFormat()

    down.inputUnit = makeHALUnit(device: acDevice, enableInput: true, enableOutput: false)
    down.outputUnit = makeHALUnit(device: macOut, enableInput: false, enableOutput: true)
    up.inputUnit = makeHALUnit(device: macIn, enableInput: true, enableOutput: false)
    up.outputUnit = makeHALUnit(device: asDevice, enableInput: false, enableOutput: true)

    for ch in [down, up] {
        guard let iu = ch.inputUnit, let ou = ch.outputUnit else {
            FileHandle.standardError.write("AudioUnit 创建失败（\(ch.label)）\n".data(using: .utf8)!)
            exit(3)
        }
        let iuRef = Unmanaged.passUnretained(ch).toOpaque()
        guard setClientFormat(iu, &fmt), setInputFormat(iu, &fmt),
              setClientFormat(ou, &fmt),
              installCallback(iu, iuRef, proc: channelInputCallback, isInput: true),
              installCallback(ou, iuRef, proc: channelRenderCallback, isInput: false),
              AudioUnitInitialize(iu) == noErr,
              AudioUnitInitialize(ou) == noErr else {
            FileHandle.standardError.write("AudioUnit 配置失败（\(ch.label)）\n".data(using: .utf8)!)
            exit(3)
        }
        guard AudioOutputUnitStart(iu) == noErr, AudioOutputUnitStart(ou) == noErr else {
            FileHandle.standardError.write("AudioUnit 启动失败（\(ch.label)）\n".data(using: .utf8)!)
            exit(3)
        }
    }

    FileHandle.standardError.write("voice-audio-bridge 运行中：AC Interface→扬声器，麦克风→AS Interface\n".data(using: .utf8)!)

    var lastDown: UInt64 = 0, lastUp: UInt64 = 0
    while !interrupted {
        Thread.sleep(forTimeInterval: 5)
        let d = down.totalFrames, u = up.totalFrames
        if verbose {
            FileHandle.standardError.write(String(format: "[stats] down=%llu fr (%llu fr/s) up=%llu fr (%llu fr/s)\n", d - lastDown, (d - lastDown) / 5, u - lastUp, (u - lastUp) / 5).data(using: .utf8)!)
        }
        lastDown = d; lastUp = u
    }

    for ch in [down, up] {
        if let iu = ch.inputUnit { AudioOutputUnitStop(iu); AudioUnitUninitialize(iu) }
        if let ou = ch.outputUnit { AudioOutputUnitStop(ou); AudioUnitUninitialize(ou) }
    }
}

// MARK: - 模式 2：FIFO（CellBridge raw-pcm 后端）
final class FifoLink {
    var unit: AudioUnit?
    var fd: Int32 = -1
    let label: String
    var totalFrames: UInt64 = 0
    var droppedBytes: UInt64 = 0
    // 上次成功把数据写进 rx FIFO 的时刻。写入成功 ⇔ 网关正在取流 ⇔ 通话进行中；
    // EAGAIN（计入 droppedBytes）⇔ 网关没在取流 ⇔ 空闲。空闲挂起靠它判定。
    var lastDrainAt: CFAbsoluteTime = 0
    let scratch = RenderScratch()

    init(label: String) { self.label = label }
}

// AC 捕获 → rx FIFO（网关读=对方声音）。非阻塞写，FIFO 满则丢弃并计数。
private func fifoCaptureCallback(_ inRefCon: UnsafeMutableRawPointer, _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ inTimeStamp: UnsafePointer<AudioTimeStamp>, _ inBusNumber: UInt32, _ inNumberFrames: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let link = Unmanaged<FifoLink>.fromOpaque(inRefCon).takeUnretainedValue()
    guard link.fd >= 0, let unit = link.unit else {
        guardExits += 1
        if guardExits <= 5 || guardExits % 500 == 0 {
            FileHandle.standardError.write("[capture] guard 退出 #\(guardExits) fd=\(link.fd) unit=\(String(describing: link.unit))\n".data(using: .utf8)!)
        }
        return noErr
    }
    guard let p = link.scratch.render(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, itemSize: 2) else {
        renderFailures += 1
        if renderFailures <= 3 || renderFailures % 200 == 0 {
            FileHandle.standardError.write(String(format: "[capture] AudioUnitRender 失败 #%llu status=%d frames=%u\n", renderFailures, link.scratch.lastStatus, inNumberFrames).data(using: .utf8)!)
        }
        return noErr
    }
    let byteCount = Int(inNumberFrames) * 2  // s16le mono
    var written = 0
    while written < byteCount {
        let n = write(link.fd, p + written, byteCount - written)
        if n > 0 { written += n; continue }
        if errno == EINTR { continue }
        link.droppedBytes += UInt64(byteCount - written)  // EAGAIN：网关没在取流
        break
    }
    if written > 0 { link.lastDrainAt = CFAbsoluteTimeGetCurrent() }  // 网关在取流 → 通话中
    link.totalFrames += UInt64(inNumberFrames)
    return noErr
}

var renderFailures: UInt64 = 0
var guardExits: UInt64 = 0

// 诊断：打印设备原生流格式与实际采样率
func dumpDeviceFormat(_ device: AudioDeviceID, tag: String) {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamFormat,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: 1)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &asbd) == noErr {
        FileHandle.standardError.write(String(format: "[%@] 输入流格式: rate=%.0f ch=%u bits=%u\n", tag, asbd.mSampleRate, asbd.mChannelsPerFrame, asbd.mBitsPerChannel).data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("[\(tag)] 输入流格式查询失败\n".data(using: .utf8)!)
    }
    var ratesAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: 1)
    var rSize: UInt32 = 0
    if AudioObjectGetPropertyDataSize(device, &ratesAddr, 0, nil, &rSize) == noErr, rSize > 0 {
        let count = Int(rSize) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        if AudioObjectGetPropertyData(device, &ratesAddr, 0, nil, &rSize, &ranges) == noErr {
            let desc = ranges.prefix(8).map { String(format: "%.0f-%.0f", $0.mMinimum, $0.mMaximum) }.joined(separator: ", ")
            FileHandle.standardError.write("[\(tag)] 支持采样率: \(desc)\n".data(using: .utf8)!)
        }
    }
}

// tx FIFO（网关写=己方声音）→ AS 播放。非阻塞读，无数据补零。
private func fifoPlaybackCallback(_ inRefCon: UnsafeMutableRawPointer, _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ inTimeStamp: UnsafePointer<AudioTimeStamp>, _ inBusNumber: UInt32, _ inNumberFrames: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let link = Unmanaged<FifoLink>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ablPtr = ioData else { return -1 }
    let bufPtr = ablPtr.pointee.mBuffers
    guard let data = bufPtr.mData else { return -1 }
    let bytes = Int(bufPtr.mDataByteSize)
    memset(data, 0, bytes)
    guard link.fd >= 0 else { return noErr }
    var got = 0
    while got < bytes {
        let n = read(link.fd, data + got, bytes - got)
        if n > 0 { got += n; continue }
        break  // EAGAIN / EOF：补零即可
    }
    link.totalFrames += UInt64(inNumberFrames)
    return noErr
}

func runFifoMode(acDevice: AudioDeviceID, asDevice: AudioDeviceID, rxPath: String, txPath: String, verbose: Bool) {
    dumpDeviceFormat(acDevice, tag: "AC")
    let rxLink = FifoLink(label: "cellular->fifo")
    let txLink = FifoLink(label: "fifo->cellular")

    // 1) tx FIFO 读端：O_RDONLY|O_NONBLOCK 立即成功，网关写端随后接上
    txLink.fd = open(txPath, O_RDONLY | O_NONBLOCK)
    guard txLink.fd >= 0 else {
        FileHandle.standardError.write("打开 tx FIFO（\(txPath)）失败：\(String(cString: strerror(errno)))\n".data(using: .utf8)!)
        exit(4)
    }
    // 2) rx FIFO 写端：非阻塞开（网关读端就绪后才成功；平时网关不读，写满即丢，绝不阻塞 IOProc）
    let rxOpen = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var fd: Int32 = -1
        for _ in 0..<600 {  // 最长等 120s：ENXIO=暂无读者，重试
            fd = open(rxPath, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { break }
            if errno == ENXIO {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            FileHandle.standardError.write("打开 rx FIFO 失败：\(String(cString: strerror(errno)))\n".data(using: .utf8)!)
            break
        }
        rxLink.fd = fd
        FileHandle.standardError.write("[rx] FIFO 打开结果 fd=\(fd)\n".data(using: .utf8)!)
        rxOpen.signal()
    }
    FileHandle.standardError.write("等待网关打开 rx FIFO（\(rxPath)）...\n".data(using: .utf8)!)
    if rxOpen.wait(timeout: .now() + 120) == .timedOut || rxLink.fd < 0 {
        FileHandle.standardError.write("等待 rx FIFO 读者超时（网关未启动？）\n".data(using: .utf8)!)
        exit(4)
    }

    var s16 = makeS16Format()

    rxLink.unit = makeHALUnit(device: acDevice, enableInput: true, enableOutput: false)
    txLink.unit = makeHALUnit(device: asDevice, enableInput: false, enableOutput: true)
    guard let riu = rxLink.unit, let tou = txLink.unit else {
        FileHandle.standardError.write("AudioUnit 创建失败（FIFO 模式）\n".data(using: .utf8)!)
        exit(3)
    }
    let rxRef = Unmanaged.passUnretained(rxLink).toOpaque()
    let txRef = Unmanaged.passUnretained(txLink).toOpaque()
    guard setClientFormat(riu, &s16), setInputFormat(riu, &s16),
          setClientFormat(tou, &s16),
          installCallback(riu, rxRef, proc: fifoCaptureCallback, isInput: true),
          installCallback(tou, txRef, proc: fifoPlaybackCallback, isInput: false),
          AudioUnitInitialize(riu) == noErr,
          AudioUnitInitialize(tou) == noErr else {
        FileHandle.standardError.write("AudioUnit 配置失败（FIFO 模式）\n".data(using: .utf8)!)
        exit(3)
    }
    func startUnits() -> Bool {
        let r = AudioOutputUnitStart(riu)
        let t = AudioOutputUnitStart(tou)
        return r == noErr && t == noErr
    }
    func stopUnits() {
        _ = AudioOutputUnitStop(riu)
        _ = AudioOutputUnitStop(tou)
    }
    // 挂起期间网关若已开始写，tx FIFO 里会积压若干帧；恢复前丢弃，
    // 避免把陈旧音频播出去造成可感知的通话延迟。
    func drainTxFifo() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { read(txLink.fd, $0.baseAddress!, 4096) }
            if n <= 0 { break }
        }
    }

    guard startUnits() else {
        FileHandle.standardError.write("AudioUnit 启动失败（FIFO 模式）\n".data(using: .utf8)!)
        exit(3)
    }

    FileHandle.standardError.write("voice-audio-bridge FIFO 模式运行中：AC Interface→\(rxPath)，\(txPath)→AS Interface（s16le 8k mono）\n".data(using: .utf8)!)

    // ── 空闲挂起（散热优化）────────────────────────────────────────────
    // 空闲时两个 AudioUnit 仍以 ~8000 fr/s 双向全速搬运（日志 [stats] 可见），
    // 模块的 UAC 端点因此被 USB 主机持续轮询、无法进入低功耗，是长期值守
    // 的主要热源之一。这里在无通话时停掉 AudioUnit，通话建立时自动唤醒：
    //   空闲判据  网关不读 rx FIFO → capture 写 EAGAIN（droppedBytes 增长）
    //   唤醒信号  网关每 20ms 往 tx FIFO 写一帧（bridge.go 空闲补静音），
    //             故 poll(txLink.fd) 有数据即代表通话已建立
    // CB_AUDIO_IDLE_SUSPEND=0 关闭本特性；CB_AUDIO_IDLE_SECONDS 调空闲阈值。
    let env = ProcessInfo.processInfo.environment
    var idleSuspend = env["CB_AUDIO_IDLE_SUSPEND"] != "0"
    let idleSeconds = Double(env["CB_AUDIO_IDLE_SECONDS"] ?? "") ?? 10.0
    let minRunSeconds = 3.0   // 恢复后至少运行这么久，避免边界抖动

    var unitsRunning = true
    var lastDrain = CFAbsoluteTimeGetCurrent()
    var lastResume = CFAbsoluteTimeGetCurrent()
    var suspendCount = 0
    var lastRx: UInt64 = 0, lastTx: UInt64 = 0, lastDrop: UInt64 = 0
    var lastStats = CFAbsoluteTimeGetCurrent()

    while !interrupted {
        let now = CFAbsoluteTimeGetCurrent()

        if unitsRunning {
            if rxLink.lastDrainAt > lastDrain { lastDrain = rxLink.lastDrainAt }
            if idleSuspend, now - lastDrain > idleSeconds, now - lastResume > minRunSeconds {
                stopUnits()
                unitsRunning = false
                suspendCount += 1
                FileHandle.standardError.write(String(format: "[idle] 第 %d 次暂停 AudioUnit（已空闲 %.0fs，等待通话音频唤醒）\n", suspendCount, idleSeconds).data(using: .utf8)!)
            }
            Thread.sleep(forTimeInterval: 0.5)
        } else {
            // 阻塞等待 tx FIFO 出现数据；500ms 超时以便及时响应退出信号
            var pfd = pollfd(fd: txLink.fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 500)
            if pr > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                drainTxFifo()
                if startUnits() {
                    unitsRunning = true
                    lastResume = now
                    lastDrain = now
                    FileHandle.standardError.write("[idle] 检测到通话音频，AudioUnit 已恢复\n".data(using: .utf8)!)
                } else {
                    // 恢复失败：永久退回常开模式，绝不牺牲通话能力
                    idleSuspend = false
                    FileHandle.standardError.write("[idle] AudioUnit 恢复失败，退回常开模式（不再挂起）\n".data(using: .utf8)!)
                }
            }
        }

        // 统计：每 5 秒一次（挂起时也打印，便于确认真的停了）
        if verbose, now - lastStats >= 5 {
            let r = rxLink.totalFrames, t = txLink.totalFrames, dp = rxLink.droppedBytes
            let tag = unitsRunning ? "" : " [已挂起]"
            FileHandle.standardError.write(String(format: "[stats]%@ cellular->fifo=%llu fr fifo->cellular=%llu fr dropped=%llu B\n", tag, r - lastRx, t - lastTx, dp - lastDrop).data(using: .utf8)!)
            lastRx = r; lastTx = t; lastDrop = dp
            lastStats = now
        }
    }

    if let iu = rxLink.unit { AudioOutputUnitStop(iu); AudioUnitUninitialize(iu) }
    if let ou = txLink.unit { AudioOutputUnitStop(ou); AudioUnitUninitialize(ou) }
    close(rxLink.fd); close(txLink.fd)
}

// MARK: - 主流程
var interrupted = false
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
    src.setEventHandler { interrupted = true }
    src.resume()
}

var args = Array(CommandLine.arguments.dropFirst())
var verbose = args.contains("--verbose")
func argValue(_ flag: String) -> String? {
    if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
    return nil
}
let cellularInName = argValue("--in-name") ?? "AC Interface"
let cellularOutName = argValue("--out-name") ?? "AS Interface"

guard let acDevice = findDevice(matching: cellularInName) else {
    FileHandle.standardError.write("找不到模块 UAC 输入设备（含 \(cellularInName)）\n".data(using: .utf8)!)
    exit(2)
}
guard let asDevice = findDevice(matching: cellularOutName) else {
    FileHandle.standardError.write("找不到模块 UAC 输出设备（含 \(cellularOutName)）\n".data(using: .utf8)!)
    exit(2)
}

if let rxPath = argValue("--fifo-rx"), let txPath = argValue("--fifo-tx") {
    runFifoMode(acDevice: acDevice, asDevice: asDevice, rxPath: rxPath, txPath: txPath, verbose: verbose)
} else {
    guard let macOut = defaultDevice(kAudioObjectPropertyScopeOutput) else {
        FileHandle.standardError.write("找不到 Mac 默认输出设备\n".data(using: .utf8)!)
        exit(2)
    }
    guard let macIn = defaultDevice(kAudioObjectPropertyScopeInput) else {
        FileHandle.standardError.write("找不到 Mac 默认输入设备\n".data(using: .utf8)!)
        exit(2)
    }
    runBridgeMode(acDevice: acDevice, asDevice: asDevice, macIn: macIn, macOut: macOut, verbose: verbose)
}
FileHandle.standardError.write("voice-audio-bridge 已退出\n".data(using: .utf8)!)
