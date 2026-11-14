// SPDX-License-Identifier: GPL-3.0-only
// Unofficial experiment. This screen does not read or write device settings on launch.
import SwiftUI
import UIKit

struct GXCanvasLabView: View {
    @State private var busy = false
    @State private var inspected = false
    @State private var backedUp = false
    @State private var defaultZoom = false
    @State private var acceptsRisk = false
    @State private var showApply = false
    @State private var showRestore = false
    @State private var showOriginal = false
    @State private var preset = 0
    @State private var message = "아직 검사하지 않았습니다. 이 빌드는 실기기 미검증 실험판입니다."
    @State private var report = ""
    @State private var hasReport = false
    @State private var hasBackup = false

    private var width: Int { preset == 0 ? 1206 : 1179 }
    private var height: Int { preset == 0 ? 2622 : 2556 }

    var body: some View {
        NavigationStack {
            Form {
                Section("실험 범위") {
                    Text("iPhone 13 · iOS 27.2 · GestaltX 1.1.1")
                        .font(.headline)
                    Text("해상도 캔버스만 변경합니다. MobileGestalt, 노치 하드웨어, 통화 표시 플래그는 이 화면에서 바꾸지 않습니다.")
                    Text("실기기 미검증 · 적용/복원/화면 개선을 보장하지 않습니다. 화면 조작이 불가능해지면 전체 기기 복원이 필요할 수 있습니다.")
                        .foregroundStyle(.red)
                }
                Section("1. 접근 검사") {
                    Button("설정 변경 없이 접근 검사") { run(0) }
                        .disabled(busy)
                    Text("기존 plist를 O_RDWR로 열되 쓰거나 잘라내지 않습니다. App Group의 임시 접근 절차는 원본 GestaltX 구현을 사용합니다. 파일이 없으면 만들지 않습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("2. 캔버스 선택") {
                    Picker("프리셋", selection: $preset) {
                        Text("18 Pro 레이아웃 실험 후보 · 1206 × 2622").tag(0)
                        Text("14 Pro 레이아웃 실험 후보 · 1179 × 2556").tag(1)
                    }
                    .disabled(busy)
                    Text("두 값은 미검증 실험 후보입니다. 현재 18 Pro 레이아웃이면 첫 후보를 사용하세요. 이 화면은 레이아웃을 자동 변경하지 않습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("전체 기기 백업과 MG 백업을 따로 보관했습니다", isOn: $backedUp)
                    Toggle("디스플레이 확대를 ‘표준’으로 되돌렸습니다", isOn: $defaultZoom)
                    Toggle("조작 불능·복원 실패 가능성을 이해했습니다", isOn: $acceptsRisk)
                    Button("실험 적용: \(width) × \(height)", role: .destructive) { showApply = true }
                        .disabled(busy || !inspected || !backedUp || !defaultZoom || !acceptsRisk)
                }
                Section("3. 복원·내보내기") {
                    Button("실험 전 원본으로 복원", role: .destructive) { showRestore = true }
                        .disabled(busy || !hasBackup)
                    if hasBackup {
                        ShareLink(item: GXCLBackupURL()) {
                            Label("실험 전 설정 백업 내보내기", systemImage: "square.and.arrow.up")
                        }
                    }
                    if hasReport {
                        ShareLink(item: GXCLReportURL()) {
                            Label("진단 로그 내보내기", systemImage: "doc.text")
                        }
                    }
                    Text("백업은 공장 기본값이 아닌 ‘이 실험 직전’ 파일입니다. 인증 키는 기기 전용 Keychain에 남습니다. 앱을 삭제하거나 다른 서명/번들로 바꾸지 마세요. 원본과 실험 결과에서 벗어난 파일은 안전을 위해 덮어쓰지 않습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("결과") {
                    if busy { ProgressView("작업 중 — 앱을 닫지 마세요") }
                    Text(message).textSelection(.enabled)
                    if !report.isEmpty {
                        Text(report).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button("원래 GestaltX 화면 열기") { showOriginal = true }
                        .disabled(busy)
                    Text("두 화면에서 동시에 작업하지 마세요. 캔버스 적용 후에는 백업·로그를 내보내고 직접 기기를 재시작하세요. 재시작 후 새 스크린샷의 픽셀 크기와 통화 표시를 확인하세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("출처·라이선스") {
                    Text("GestaltX(huamidev 및 기여자)용 비공식 수정판 · 2026-11-14. GPL-3.0-only, 무보증으로 제공됩니다. 라이선스 조건에 따라 수정·재배포할 수 있습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("원본 GestaltX · GPLv3 라이선스", destination: URL(string: "https://github.com/huamidev/GestaltX/blob/f34d5a7271c14e540edb58e328dc9c06f8f3368f/LICENSE")!)
                }
            }
            .navigationTitle("Canvas Lab · 실험판")
            .alert("캔버스 변경을 시도할까요?", isPresented: $showApply) {
                Button("취소", role: .cancel) {}
                Button("백업 후 적용 시도", role: .destructive) { run(1) }
            } message: {
                Text("\(width) × \(height)을 시도합니다. 최초 백업 인증 및 저장에 실패하거나 접근이 거부되면 중단합니다. 성공하더라도 통화 표시 개선은 보장되지 않습니다. 자동 재부팅하지 않습니다.")
            }
            .alert("실험 전 파일로 복원할까요?", isPresented: $showRestore) {
                Button("취소", role: .cancel) {}
                Button("인증된 원본으로 복원", role: .destructive) { run(2) }
            } message: {
                Text("같은 기기·OS 빌드의 인증된 백업이 필요합니다. 현재 파일이 알려진 상태와 다르면 다른 변경을 덮어쓰지 않고 중단합니다.")
            }
            .sheet(isPresented: $showOriginal) {
                NavigationStack {
                    ContentView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("실험 화면으로") { showOriginal = false }
                            }
                        }
                }
            }
            .onAppear { updateExports() }
        }
    }

    private func updateExports() {
        hasReport = FileManager.default.fileExists(atPath: GXCLReportURL().path)
        hasBackup = FileManager.default.fileExists(atPath: GXCLBackupURL().path)
    }
    private func run(_ operation: Int) {
        guard !busy, !showOriginal else { return }
        busy = true
        let w = width, h = height
        DispatchQueue.global(qos: .userInitiated).async {
            let response: [String: Any]
            switch operation {
            case 1: response = GXCLApply(w, h)
            case 2: response = GXCLRestore()
            default: response = GXCLInspect()
            }
            // Pass only Swift value types back to the main queue, not NSDictionary.
            let newMessage = response["message"] as? String ?? "알 수 없는 결과"
            let newReport = response["report"] as? String ?? ""
            let couldInspect = response["inspected"] as? Bool ?? false
            DispatchQueue.main.async {
                message = newMessage
                report = newReport
                inspected = couldInspect
                busy = false
                updateExports()
            }
        }
    }
}
