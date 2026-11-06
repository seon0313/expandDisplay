import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import Network
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
        didSet { UserDefaults.standard.set(bitrateMbps, forKey: "bitrate"); if oldValue != bitrateMbps { rebuild() } }
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
    }

    // MARK: Permissions

    func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess()
        let ax = AXIsProcessTrusted()
        if screen != hasScreenPermission { hasScreenPermission = screen }
        if ax != hasAccessibilityPermission { hasAccessibilityPermission = ax }
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

    private func rebuild() {
        guard let req = request, let session else { return }
        stopPipeline()

        refreshPermissions()
        guard hasScreenPermission else {
            lastError = "화면 기록 권한이 필요합니다"
            session.sendStatus("Mac에서 '화면 기록' 권한을 허용한 뒤 앱을 다시 실행해 주세요")
            CGRequestScreenCaptureAccess()
            return
        }

        guard let display = ensureDisplay(for: req) else {
            lastError = "가상 디스플레이를 만들 수 없습니다"
            session.sendStatus("Mac에서 가상 디스플레이를 만들지 못했습니다")
            return
        }

        generation += 1
        let gen = generation
        let id = display.displayID
        let expectW = req.width, expectH = req.height

        waitForMode(displayID: id, width: expectW, height: expectH, attempts: 30) { [weak self] in
            guard let self, gen == self.generation, let session = self.session else { return }
            let (pw, ph) = Self.pixelSize(of: id, fallback: (expectW, expectH))
            let p = CapturePipeline(displayID: id, width: pw, height: ph, fps: self.fps,
                                    bitrate: self.bitrateMbps * 1_000_000, session: session)
            p.onError = { [weak self, weak p] err in
                guard let self, let p, p === self.pipeline else { return }
                self.lastError = err.localizedDescription
                self.streaming = false
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
                            self.session?.sendStatus("Mac 오류: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func ensureDisplay(for req: (width: Int, height: Int, dpi: Int, name: String)) -> EDVirtualDisplay? {
        let modeW = hiDPI ? req.width / 2 : req.width
        let modeH = hiDPI ? req.height / 2 : req.height
        let refresh = Double(fps)

        if let d = display, d.maxPixelsWide >= UInt32(req.width), d.maxPixelsHigh >= UInt32(req.height) {
            if d.applyMode(width: UInt32(modeW), height: UInt32(modeH), refreshRate: refresh, hiDPI: hiDPI) {
                return d
            }
        }

        // (Re)create. Allow both orientations without recreating (folded/unfolded, rotation).
        display = nil
        let side = UInt32(max(req.width, req.height))
        let dpi = Double(max(req.dpi, 100))
        let mm = CGSize(width: Double(req.width) / dpi * 25.4, height: Double(req.height) / dpi * 25.4)
        guard let d = EDVirtualDisplay(name: "\(req.name) (ExpandDisplay)", maxPixelsWide: side,
                                       maxPixelsHigh: side, sizeInMillimeters: mm, serial: 0xED0001) else {
            return nil
        }
        guard d.applyMode(width: UInt32(modeW), height: UInt32(modeH), refreshRate: refresh, hiDPI: hiDPI) else {
            return nil
        }
        display = d
        return d
    }

    private func waitForMode(displayID: CGDirectDisplayID, width: Int, height: Int, attempts: Int,
                             then: @escaping () -> Void) {
        let (pw, ph) = Self.pixelSize(of: displayID, fallback: (0, 0))
        if (pw == width && ph == height) || attempts <= 0 {
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForMode(displayID: displayID, width: width, height: height, attempts: attempts - 1, then: then)
        }
    }

    private static func pixelSize(of id: CGDirectDisplayID, fallback: (Int, Int)) -> (Int, Int) {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return fallback }
        let w = mode.pixelWidth & ~1
        let h = mode.pixelHeight & ~1
        return (w > 0 && h > 0) ? (w, h) : fallback
    }

    private func stopPipeline() {
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
            self.request = nil
            self.resolutionText = nil
        }
        teardown = work
        // Keep the display briefly so a quick reconnect doesn't reshuffle windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
}
