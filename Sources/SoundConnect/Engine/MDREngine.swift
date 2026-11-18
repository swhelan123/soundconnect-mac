import CMDR
import Foundation

// Compound C macros (bit-shift expressions) don't import into Swift, so mirror them here.
let kInitDefault: MDRHeadphonesInitFlags = (1 << 20) - 1   // MDR_HEADPHONES_INIT_DEFAULT
let kSyncDefault: MDRHeadphonesSyncFlags = (1 << 4) - 1    // MDR_HEADPHONES_SYNC_DEFAULT
let kSyncBattery: MDRHeadphonesSyncFlags = 1 << 0          // MDR_HEADPHONES_SYNC_BATTERY
let kSyncSafeListening: MDRHeadphonesSyncFlags = 1 << 1    // MDR_HEADPHONES_SYNC_SAFE_LISTENING
let kOK = MDRResult(MDR_RESULT_OK)
let kInProgress = MDRResult(MDR_RESULT_INPROGRESS)
let kTimeout = MDRResult(MDR_RESULT_ERROR_TIMEOUT)

/// Owns the libmdr connection + headphones instance on one dedicated thread.
///
/// libmdr is not thread-safe, so *every* mdr call happens on `thread`. The UI talks to it
/// through `perform { hp in ... }` closures and receives immutable `HeadphoneState` snapshots.
/// The macOS Bluetooth backend dispatches IOBluetooth work onto the main queue, so the main
/// thread must stay responsive (SwiftUI's run loop is fine).
final class MDREngine: @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case connecting
        case initializing
        case ready
    }

    enum Event {
        case phase(Phase)
        case state(HeadphoneState)
        case failed(String)
        case alert(String)
    }

    var onEvent: ((Event) -> Void)?

    private let lock = NSLock()
    private var queue: [(OpaquePointer) -> Void] = []
    private var pendingConnect: (address: String, uuid: String, proto: MDRProtocolVersion)?
    private var wantDisconnect = false

    // Worker-thread-only state below.
    private let macConn: OpaquePointer
    private let conn: UnsafeMutablePointer<MDRConnection>
    private var hp: OpaquePointer?
    private var phase: Phase = .idle
    private var proto: MDRProtocolVersion = MDRProtocolVersion(MDR_PROTOCOL_V2)
    private var connectDeadline = Date.distantFuture
    private var pendingSync: MDRHeadphonesSyncFlags = 0
    private var lastBatterySync = Date.distantPast
    private var lastSafeListeningSync = Date.distantPast
    private var snapshotDirty = false
    private var forcePublish = false
    private var lastSnapshot: HeadphoneState?
    private var thread: Thread?

    private static let pollInterval: TimeInterval = 0.025 // 40 Hz, same as upstream client
    private static let connectTimeout: TimeInterval = 10
    private static let batterySyncInterval: TimeInterval = 60
    /// Sound pressure (for exposure tracking) is only reported when asked.
    private static let safeListeningSyncInterval: TimeInterval = 20

    init() {
        macConn = mdrConnectionMacOSCreate()
        conn = mdrConnectionMacOSGet(macConn)
    }

    deinit { mdrConnectionMacOSDestroy(macConn) }

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "SoundConnect.MDR"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    // MARK: - Public (any thread)

    func connect(address: String, serviceUUID: String, protocolVersion: MDRProtocolVersion) {
        lock.withLock { pendingConnect = (address, serviceUUID, protocolVersion) }
    }

    func disconnect() {
        lock.withLock { wantDisconnect = true }
    }

    /// Close the RFCOMM channel right now (app quitting). If it isn't closed, bluetoothd keeps the
    /// channel reserved for a while and the next launch can't open it (OI_RFCOMM_Connect status 911).
    /// Safe to call from the main thread: the backend's disconnect is non-blocking.
    func shutdown() {
        lock.withLock { pendingConnect = nil; queue.removeAll() }
        mdrConnectionDisconnect(conn)
        // The macOS backend closes the channel in a block dispatched to the main queue; when quitting
        // (we're on main, about to exit) that block would never run. Spin the run loop so it does.
        if Thread.isMainThread {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
    }

    /// Run `body` on the worker thread with a live, initialized headphones handle.
    /// Dropped silently if not connected by the time it runs.
    func perform(_ body: @escaping (OpaquePointer) -> Void) {
        lock.withLock { queue.append(body) }
    }

    // MARK: - Worker loop

    private func run() {
        while true {
            autoreleasepool { tick() }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
    }

    private func setPhase(_ p: Phase) {
        guard p != phase else { return }
        phase = p
        onEvent?(.phase(p))
    }

    private func tick() {
        let (connectReq, disconnectReq, work): ((String, String, MDRProtocolVersion)?, Bool, [(OpaquePointer) -> Void]) =
            lock.withLock {
                defer { pendingConnect = nil; wantDisconnect = false; queue.removeAll() }
                return (pendingConnect, wantDisconnect, queue)
            }

        if disconnectReq { teardown(reason: nil) }

        if let (address, uuid, p) = connectReq {
            teardown(reason: nil)
            proto = p
            let r = address.withCString { a in uuid.withCString { u in mdrConnectionConnect(conn, a, u) } }
            if r == kOK || r == kInProgress {
                connectDeadline = Date().addingTimeInterval(Self.connectTimeout)
                setPhase(.connecting)
            } else {
                fail(connectionError(r))
            }
        }

        switch phase {
        case .idle:
            return
        case .connecting:
            pollConnecting()
        case .initializing, .ready:
            if let hp, mdrHeadphonesIsInitialized(hp) == MDR_TRUE {
                for w in work { w(hp) }
                if !work.isEmpty { snapshotDirty = true; forcePublish = true }
            }
            pollDevice()
        }
    }

    private func pollConnecting() {
        let r = mdrConnectionPoll(conn, 0)
        switch r {
        case kOK:
            var h: OpaquePointer?
            guard mdrHeadphonesCreate(MDR_ABI_VERSION, conn, proto, &h) == kOK, let h else {
                fail("libmdr ABI mismatch")
                return
            }
            hp = h
            guard mdrHeadphonesRequestInit(h, kInitDefault) == kOK else {
                fail(lastError())
                return
            }
            setPhase(.initializing)
        case kInProgress, kTimeout:
            if Date() > connectDeadline { fail("Timed out connecting to headphones") }
        default:
            fail(connectionError(r))
        }
    }

    private func pollDevice() {
        guard let hp else { return }
        // Drain every event available this tick.
        for _ in 0..<64 {
            var event: MDREvent = MDREvent(MDR_EVENT_NONE)
            guard mdrHeadphonesPoll(hp, &event) == kOK else {
                fail(lastError())
                return
            }
            if event == MDR_EVENT_NONE { break }
            snapshotDirty = true
            switch event {
            case MDREvent(MDR_EVENT_INITIALIZE_COMPLETE):
                // Hold off on .ready until the first sync lands, so the UI never flashes 0% battery.
                pendingSync |= kSyncDefault
                lastBatterySync = Date()
            case MDREvent(MDR_EVENT_SYNC_COMPLETE):
                // `defaults write dev.soundconnect.mac debugDump -bool YES` logs everything the device reports.
                if phase != .ready, UserDefaults.standard.bool(forKey: "debugDump") { DeviceDump.run(hp) }
                setPhase(.ready)
            case MDREvent(MDR_EVENT_NEED_SYNC):
                var flags: MDRHeadphonesSyncFlags = 0
                if mdrHeadphonesGetSync(hp, &flags) == kOK { pendingSync |= flags }
            case MDREvent(MDR_EVENT_ALERT):
                onEvent?(.alert(Reader(hp).text(MDRText(MDR_TEXT_LAST_ALERT))))
            default:
                break
            }
        }

        if phase == .ready, Date().timeIntervalSince(lastBatterySync) > Self.batterySyncInterval {
            pendingSync |= kSyncBattery
            lastBatterySync = Date()
        }
        if phase == .ready, Date().timeIntervalSince(lastSafeListeningSync) > Self.safeListeningSyncInterval {
            pendingSync |= kSyncSafeListening
            lastSafeListeningSync = Date()
        }

        if mdrHeadphonesIsReady(hp) == MDR_TRUE {
            if mdrHeadphonesIsDirty(hp) == MDR_TRUE {
                if mdrHeadphonesRequestCommit(hp) != kOK { fail(lastError()); return }
            } else if pendingSync != 0 {
                let flags = pendingSync
                pendingSync = 0
                if mdrHeadphonesRequestSync(hp, flags) != kOK { fail(lastError()); return }
            }
        }

        if snapshotDirty, phase == .ready {
            snapshotDirty = false
            let s = HeadphoneState.read(from: hp)
            // Devices stream reports (e.g. sound pressure) several times a second; only publish real
            // changes, unless we just wrote something (the UI applied it optimistically and must be
            // corrected if the device refused it).
            if s != lastSnapshot || forcePublish {
                lastSnapshot = s
                onEvent?(.state(s))
            }
            forcePublish = false
        }
    }

    // MARK: - Errors / teardown

    private func fail(_ message: String) {
        teardown(reason: message)
    }

    private func teardown(reason: String?) {
        if let hp { mdrHeadphonesDestroy(hp) }
        hp = nil
        if phase != .idle { mdrConnectionDisconnect(conn) }
        pendingSync = 0
        snapshotDirty = false
        lastSnapshot = nil
        setPhase(.idle)
        if let reason { onEvent?(.failed(reason)) }
    }

    private func lastError() -> String {
        if let hp {
            let t = Reader(hp).text(MDRText(MDR_TEXT_LAST_ERROR))
            if !t.isEmpty { return t }
        }
        return String(cString: mdrConnectionGetLastError(conn))
    }

    private func connectionError(_ r: MDRResult) -> String {
        let e = String(cString: mdrConnectionGetLastError(conn))
        return e.isEmpty ? String(cString: mdrResultString(r)) : e
    }
}
