import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import Network
import ScreenCaptureKit
import VirtualDisplayBridge

/// Owns the server, the virtual display, the active client and the capture pipeline. Main thread only.
final class StreamCoordinator: ObservableObject {
    @Published private(set) var serverStatus = "시작 중…"
    @Published private(set) var clientName: String?
    @Published private(set) var resolutionText: String?
    @Published private(set) var streaming = false
    @Published private(set) var lastError: String?
    @Published private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var hasAccessibilityPermission = AXIsProcessTrusted()

    @Published var hiDPI: Bool = UserDefaults.standard.object(forKey: "hiDPI") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hiDPI, forKey: "hiDPI"); if oldValue != hiDPI { rebuild() } }
    }
    @Published var bitrateMbps: Int = UserDefaults.standard.object(forKey: "bitrate") as? Int ?? 30 {
        didSet {
            UserDefaults.standard.set(bitrateMbps, forKey: "bitrate")
            // Applied live to the running encoder — no display/pipeline restart (that caused cropping).
            if oldValue != bitrateMbps { pipeline?.updateBitrate(bitrateMbps * 1_000_000) }
        }
    }
    @Published var fps: Int = UserDefaults.standard.object(forKey: "fps") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(fps, forKey: "fps"); if oldValue != fps { rebuild() } }
    }

    private let server = Server()
    private let input = InputInjector()
    private var session: ClientSession?
    private var pipeline: CapturePipeline?
    private var display: EDVirtualDisplay?
    private var request: (width: Int, height: Int, dpi: Int, name: String)?
    private var generation = 0
    private var teardown: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var appliedMode: (w: Int, h: Int, hiDPI: Bool, refresh: Int)?
    private var restartWork: DispatchWorkItem?

    init() {
        server.onConnection = { [weak self] conn in self?.accept(conn) }
        server.onStateChange = { [weak self] s in self?.serverStatus = s }
        server.start()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
            guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
            let me = Unmanaged<StreamCoordinator>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { me.displayReconfigured(displayID) }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: Permissions

    private var lastProbe = Date.distantPast

    func refreshPermissions() {
        let ax = AXIsProcessTrusted()
        if ax != hasAccessibilityPermission { hasAccessibilityPermission = ax }

        // CGPreflightScreenCaptureAccess() is cached for the life of the process, so after the user
        // grants access it keeps saying "no" until relaunch. Probe ScreenCaptureKit for the truth.
        if CGPreflightScreenCaptureAccess() {
            if !hasScreenPermission { hasScreenPermission = true }
            return
        }
        guard Date().timeIntervalSince(lastProbe) > 5 else { return }
        lastProbe = Date()
        Task {
            let ok = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
            await MainActor.run {
                if ok != self.hasScreenPermission { self.hasScreenPermission = ok }
            }
        }
    }

    /// Relaunch the app (permission changes are only fully picked up by a fresh process).
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Wipe stale TCC entries (left over from older builds with a different signature) and relaunch.
    /// After relaunch macOS asks again and the fresh grant sticks to this build.
    func resetPermissionsAndRelaunch() {
        let id = Bundle.main.bundleIdentifier ?? "dev.seon.expanddisplay"
        for service in ["ScreenCapture", "Accessibility"] {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            t.arguments = ["reset", service, id]
            try? t.run()
            t.waitUntilExit()
        }
        relaunch()
    }

    func requestScreenPermission() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Connections

    func disconnectClient() {
        session?.close()
    }

    private func accept(_ conn: NWConnection) {
        // Only one phone at a time: the newest connection wins.
        if let old = session {
            old.onClose = nil
            old.close()
        }
        stopPipeline()
        teardown?.cancel()
        teardown = nil
        lastError = nil

        let s = ClientSession(connection: conn)
        s.onConfig = { [weak self, weak s] w, h, dpi, name in
            guard let self, let s, s === self.session else { return }
            self.handleConfig(width: w, height: h, dpi: dpi, name: name)
        }
        s.onTouch = { [weak self, weak s] action, x, y in
            guard let self, let s, s === self.session, let id = self.display?.displayID else { return }
            if !self.hasAccessibilityPermission {
                self.refreshPermissions()
            }
            self.input.handle(action: action, x: x, y: y, displayID: id)
        }
        s.onKeyframeRequest = { [weak self, weak s] in
            guard let self, let s, s === self.session else { return }
            self.pipeline?.requestKeyframe()
        }
        s.onClose = { [weak self, weak s] in
            guard let self, let s, s === self.session else { return }
            self.session = nil
            self.clientName = nil
            self.stopPipeline()
            self.scheduleTeardown()
        }
        session = s
        clientName = s.peerDescription
        s.start()
    }

    private func handleConfig(width: Int, height: Int, dpi: Int, name: String) {
        clientName = name
        let w = max(320, width) & ~1
        let h = max(240, height) & ~1
        if let r = request, r.width == w, r.height == h, r.dpi == dpi, pipeline != nil {
            pipeline?.requestKeyframe()
            return
        }
        request = (w, h, dpi, name)
        rebuild()
    }

    // MARK: Display + pipeline

    /// Full rebuild: (re)apply the virtual display mode, then restart capture once the mode is stable.
    private func rebuild() {
        guard let req = request, let session else { return }
        stopPipeline()

        // Don't gate on CGPreflightScreenCaptureAccess() (stale cache) — ScreenCaptureKit will
        // report a real permission failure when the pipeline starts.
        refreshPermissions()

        var modeChanged = false
        guard ensureDisplay(for: req, modeChanged: &modeChanged) != nil else {
            lastError = "가상 디스플레이를 만들 수 없습니다"
            session.sendStatus("Mac에서 가상 디스플레이를 만들지 못했습니다")
            return
        }
        startPipeline(settle: modeChanged)
    }

    /// Restart only capture/encode on the existing display (no mode change).
    private func restartPipeline() {
        guard display != nil, request != nil, session != nil else { return }
        startPipeline(settle: false)
    }

    private func startPipeline(settle: Bool) {
        guard let req = request, let display else { return }
        stopPipeline()
        let gen = generation
        let id = display.displayID

        // After a mode change macOS reconfigures the display asynchronously. The pixel size can
        // read "correct" before the reconfiguration lands, so require it to be stable for a while.
        waitForStableMode(displayID: id, width: req.width, height: req.height,
                          stableNeeded: settle ? 4 : 1, attempts: 50) { [weak self] in
            guard let self, gen == self.generation, let session = self.session else { return }
            let (pw, ph) = Self.pixelSize(of: id, fallback: (req.width, req.height))
            let p = CapturePipeline(displayID: id, width: pw, height: ph, fps: self.fps,
                                    bitrate: self.bitrateMbps * 1_000_000, session: session)
            p.onError = { [weak self, weak p] err in
                guard let self, let p, p === self.pipeline else { return }
                // Stream died (usually a display reconfiguration) — restart capture.
                self.lastError = err.localizedDescription
                self.streaming = false
                self.scheduleRestart(after: 0.5)
            }
            self.pipeline = p
            self.resolutionText = "\(pw)×\(ph)" + (self.hiDPI ? " (HiDPI)" : "") + " @\(self.fps)Hz"
            session.sendVideoConfig(width: pw, height: ph)
            Task {
                do {
                    try await p.start()
                    await MainActor.run {
                        if p === self.pipeline { self.streaming = true; self.lastError = nil }
                    }
                } catch {
                    await MainActor.run {
                        if p === self.pipeline {
                            self.lastError = error.localizedDescription
                            self.refreshPermissions()
                            let hint = self.hasScreenPermission ? "" : " — Mac 메뉴바에서 '권한 초기화 후 재시작'을 눌러 주세요"
                            self.session?.sendStatus("Mac 오류: \(error.localizedDescription)\(hint)")
                        }
                    }
                }
            }
        }
    }

    /// Called for any display reconfiguration. If our display's pixel size no longer matches what
    /// we're capturing (e.g. the user changed it in System Settings), restart capture to match.
    fileprivate func displayReconfigured(_ id: CGDirectDisplayID) {
        guard let d = display, d.displayID == id, let p = pipeline else { return }
        let (pw, ph) = Self.pixelSize(of: id, fallback: (p.width, p.height))
        if pw != p.width || ph != p.height {
            scheduleRestart(after: 0.3)
        }
    }

    private func scheduleRestart(after delay: TimeInterval) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartPipeline() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func ensureDisplay(for req: (width: Int, height: Int, dpi: Int, name: String),
                               modeChanged: inout Bool) -> EDVirtualDisplay? {
        let modeW = hiDPI ? req.width / 2 : req.width
        let modeH = hiDPI ? req.height / 2 : req.height
        let wanted = (w: modeW, h: modeH, hiDPI: hiDPI, refresh: fps)

        if let d = display, d.maxPixelsWide >= UInt32(req.width), d.maxPixelsHigh >= UInt32(req.height) {
            // Re-applying an identical mode makes macOS reconfigure the display for nothing.
            if let m = appliedMode, m == wanted {
                modeChanged = false
                return d
            }
            if d.applyMode(width: UInt32(modeW), height: UInt32(modeH), refreshRate: Double(fps), hiDPI: hiDPI) {
                appliedMode = wanted
                modeChanged = true
                return d
            }
        }

        // (Re)create. Allow both orientations without recreating (folded/unfolded, rotation).
        display = nil
        appliedMode = nil
        let side = UInt32(max(req.width, req.height))
        let dpi = Double(max(req.dpi, 100))
        let mm = CGSize(width: Double(req.width) / dpi * 25.4, height: Double(req.height) / dpi * 25.4)
        guard let d = EDVirtualDisplay(name: "\(req.name) (ExpandDisplay)", maxPixelsWide: side,
                                       maxPixelsHigh: side, sizeInMillimeters: mm, serial: 0xED0001) else {
            return nil
        }
        guard d.applyMode(width: UInt32(modeW), height: UInt32(modeH), refreshRate: Double(fps), hiDPI: hiDPI) else {
            return nil
        }
        display = d
        appliedMode = wanted
        modeChanged = true
        return d
    }

    private func waitForStableMode(displayID: CGDirectDisplayID, width: Int, height: Int,
                                   stableNeeded: Int, attempts: Int, stable: Int = 0,
                                   then: @escaping () -> Void) {
        let (pw, ph) = Self.pixelSize(of: displayID, fallback: (0, 0))
        let nowStable = (pw == width && ph == height) ? stable + 1 : 0
        if nowStable >= stableNeeded || attempts <= 0 {
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForStableMode(displayID: displayID, width: width, height: height,
                                    stableNeeded: stableNeeded, attempts: attempts - 1,
                                    stable: nowStable, then: then)
        }
    }

    private static func pixelSize(of id: CGDirectDisplayID, fallback: (Int, Int)) -> (Int, Int) {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return fallback }
        let w = mode.pixelWidth & ~1
        let h = mode.pixelHeight & ~1
        return (w > 0 && h > 0) ? (w, h) : fallback
    }

    private func stopPipeline() {
        restartWork?.cancel()
        restartWork = nil
        generation += 1
        pipeline?.stop()
        pipeline = nil
        streaming = false
    }

    private func scheduleTeardown() {
        teardown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session == nil else { return }
            self.display = nil
            self.appliedMode = nil
            self.request = nil
            self.resolutionText = nil
        }
        teardown = work
        // Keep the display briefly so a quick reconnect doesn't reshuffle windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
}
