import SwiftUI

@main
struct ExpandDisplayApp: App {
    @StateObject private var coordinator = StreamCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(coordinator)
        } label: {
            Image(systemName: coordinator.streaming ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContentView: View {
    @EnvironmentObject var c: StreamCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ExpandDisplay").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Label(c.serverStatus, systemImage: "wifi")
                Label(c.usbStatus, systemImage: "cable.connector")
                if let name = c.clientName {
                    Label("연결됨: \(name)", systemImage: "iphone")
                } else {
                    Label("폰에서 앱을 열면 자동으로 연결됩니다", systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                }
                if let res = c.resolutionText {
                    Label(res, systemImage: "display")
                }
                if c.streaming {
                    Label("스트리밍 중", systemImage: "dot.radiowaves.right").foregroundStyle(.green)
                }
                if let err = c.lastError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .font(.callout)

            Divider()

            Toggle("USB 케이블 연결 사용", isOn: $c.usbEnabled)
            Toggle("HiDPI (Retina) 모드", isOn: $c.hiDPI)
            Picker("비트레이트", selection: $c.bitrateMbps) {
                ForEach([10, 20, 30, 50, 80], id: \.self) { Text("\($0) Mbps").tag($0) }
            }
            Picker("프레임레이트", selection: $c.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
                Text("120 fps").tag(120)
            }

            Divider()

            if !c.hasScreenPermission {
                Button("화면 기록 권한 허용…") { c.requestScreenPermission() }
            }
            if !c.hasAccessibilityPermission {
                Button("손쉬운 사용 권한 허용 (터치 → 클릭)…") { c.requestAccessibilityPermission() }
            }
            if c.hasScreenPermission && c.hasAccessibilityPermission {
                Label("권한 OK", systemImage: "checkmark.seal").foregroundStyle(.secondary).font(.caption)
            } else {
                Text("이미 허용했는데도 계속 요청하면 → 이전 버전의 권한 기록이 남아 있는 것입니다.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("앱 재시작") { c.relaunch() }
                    Button("권한 초기화 후 재시작") { c.resetPermissionsAndRelaunch() }
                }
            }

            HStack {
                if c.clientName != nil {
                    Button("연결 끊기") { c.disconnectClient() }
                }
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { c.refreshPermissions() }
    }
}
