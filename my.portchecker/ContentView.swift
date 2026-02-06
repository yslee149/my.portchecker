//
//  ContentView.swift
//  my.portchecker
//
//  Created by yslee on 2/6/26.
//

import SwiftUI
import Network

// MARK: - Model

struct PortProcess: Identifiable, Sendable {
    let id = UUID()
    let command: String
    let pid: Int32
    let user: String
    let type: String
    let name: String
    let port: Int

    /// lsof NAME 필드에서 포트 번호 추출 (*:8080, 127.0.0.1:3000, [::1]:8080 등)
    nonisolated static func extractPort(from name: String) -> Int {
        let cleanName = String(name.split(separator: " ").first ?? Substring(name))
        // "->" 가 있으면 로컬 쪽(왼쪽)만 사용
        let localPart = String(cleanName.split(separator: "-").first ?? Substring(cleanName))
        if let lastColon = localPart.lastIndex(of: ":") {
            let afterColon = localPart[localPart.index(after: lastColon)...]
            let portStr = afterColon.prefix(while: { $0.isNumber })
            return Int(portStr) ?? 0
        }
        return 0
    }
}

// MARK: - ViewModel

@Observable
class PortCheckerViewModel {
    var portNumber: String = ""
    var processes: [PortProcess] = []
    var isSearching = false
    var statusMessage = "포트 번호를 입력하고 검색 버튼을 누르세요."
    var showKillConfirm = false
    var processToKill: PortProcess?
    var isShowingAllPorts = false
    var localIPAddress: String = "확인 중..."
    var networkType: NetworkType = .unknown
    var ipCopiedToast = false

    enum NetworkType {
        case wifi
        case ethernet
        case unknown

        var label: String {
            switch self {
            case .wifi: return "Wi-Fi"
            case .ethernet: return "Ethernet"
            case .unknown: return ""
            }
        }

        var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .ethernet: return "cable.connector.horizontal"
            case .unknown: return "questionmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .wifi: return .green
            case .ethernet: return .blue
            case .unknown: return .secondary
            }
        }
    }

    // MARK: - IP Address

    func fetchLocalIP() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            localIPAddress = "알 수 없음"
            networkType = .unknown
            return
        }
        defer { freeifaddrs(ifaddr) }

        // 인터페이스별 IP 수집: (인터페이스명, IP)
        var found: [(name: String, ip: String)] = []

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            guard addr.sa_family == UInt8(AF_INET),
                  (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0 else { continue }

            let ifName = String(cString: ptr.pointee.ifa_name)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 {
                let ip = String(cString: hostname)
                if !ip.isEmpty {
                    found.append((name: ifName, ip: ip))
                }
            }
        }

        // en0 = Wi-Fi, en1~enX = Ethernet (macOS 기준)
        if let entry = found.first(where: { $0.name == "en0" }) {
            localIPAddress = entry.ip
            networkType = .wifi
        } else if let entry = found.first(where: { $0.name.hasPrefix("en") }) {
            localIPAddress = entry.ip
            networkType = .ethernet
        } else if let entry = found.first {
            localIPAddress = entry.ip
            networkType = .unknown
        } else {
            localIPAddress = "알 수 없음"
            networkType = .unknown
        }
    }

    func copyIP() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localIPAddress, forType: .string)
        ipCopiedToast = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            ipCopiedToast = false
        }
    }

    // MARK: - Search

    func searchPort() {
        isShowingAllPorts = false
        let trimmed = portNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), port > 0, port <= 65535 else {
            statusMessage = "올바른 포트 번호를 입력해주세요 (1-65535)"
            processes = []
            return
        }

        isSearching = true
        statusMessage = "포트 \(port) 검색 중..."
        processes = []

        let portArg = ":\(port)"
        Task.detached {
            let output = Self.runShell(
                "/usr/sbin/lsof",
                arguments: ["-i", portArg, "-P", "-n"]
            )
            let parsed = Self.parseLsofOutput(output, deduplicateByPID: true)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.processes = parsed
                if parsed.isEmpty {
                    self.statusMessage = "포트 \(port)을(를) 사용하는 프로세스가 없습니다."
                } else {
                    self.statusMessage = "\(parsed.count)개의 프로세스를 찾았습니다."
                }
                self.isSearching = false
            }
        }
    }

    // MARK: - Fetch All Ports

    func fetchAllPorts() {
        isShowingAllPorts = true
        isSearching = true
        statusMessage = "사용 중인 포트 검색 중..."
        processes = []

        Task.detached {
            let output = Self.runShell(
                "/usr/sbin/lsof",
                arguments: ["-iTCP", "-sTCP:LISTEN", "-P", "-n"]
            )
            let parsed = Self.parseLsofOutput(output, deduplicateByPID: false)
                .sorted { $0.port < $1.port }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.processes = parsed
                if parsed.isEmpty {
                    self.statusMessage = "사용 중인 포트가 없습니다."
                } else {
                    self.statusMessage = "\(parsed.count)개의 포트가 사용 중입니다."
                }
                self.isSearching = false
            }
        }
    }

    // MARK: - Kill

    func confirmKill(_ process: PortProcess) {
        processToKill = process
        showKillConfirm = true
    }

    func killSelectedProcess() {
        guard let process = processToKill else { return }
        processToKill = nil

        // 일반 kill 시도 (현재 사용자 소유 프로세스)
        let result = Darwin.kill(process.pid, SIGKILL)

        if result == 0 {
            statusMessage = "프로세스 '\(process.command)' (PID: \(process.pid))를 종료했습니다."
            refreshAfterDelay()
        } else if errno == EPERM {
            // 권한 부족 → 관리자 권한으로 재시도
            killWithAdminPrivileges(process)
        } else {
            statusMessage = "프로세스 종료 실패 (에러 코드: \(errno))"
        }
    }

    private func killWithAdminPrivileges(_ process: PortProcess) {
        let source = "do shell script \"kill -9 \(process.pid)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            statusMessage = "스크립트 실행 실패"
            return
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "알 수 없는 오류"
            statusMessage = "프로세스 종료 실패: \(msg)"
        } else {
            statusMessage = "프로세스 '\(process.command)' (PID: \(process.pid))를 종료했습니다."
            refreshAfterDelay()
        }
    }

    private func refreshAfterDelay() {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if isShowingAllPorts {
                fetchAllPorts()
            } else {
                searchPort()
            }
        }
    }

    // MARK: - Shell Helpers

    nonisolated private static func runShell(_ path: String, arguments: [String]) -> String {
        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    nonisolated private static func parseLsofOutput(
        _ output: String,
        deduplicateByPID: Bool = true
    ) -> [PortProcess] {
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > 1 else { return [] }

        var results: [PortProcess] = []
        var seenPIDs = Set<Int32>()
        var seenPorts = Set<Int>()

        for line in lines.dropFirst() {
            let parts = line.split(
                separator: " ", maxSplits: 8, omittingEmptySubsequences: true
            )
            guard parts.count >= 9,
                  let pid = Int32(parts[1]) else { continue }

            let name = String(parts[8])
            let port = PortProcess.extractPort(from: name)

            if deduplicateByPID {
                // 특정 포트 검색: PID 기준 중복 제거
                guard !seenPIDs.contains(pid) else { continue }
                seenPIDs.insert(pid)
            } else {
                // 전체 포트 목록: 포트 번호 기준 중복 제거
                guard !seenPorts.contains(port) else { continue }
                seenPorts.insert(port)
            }

            results.append(PortProcess(
                command: String(parts[0]),
                pid: pid,
                user: String(parts[2]),
                type: String(parts[4]),
                name: name,
                port: port
            ))
        }

        return results
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var viewModel = PortCheckerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ipBar

            Divider()

            searchBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            if viewModel.processes.isEmpty {
                emptyState
            } else {
                processList
            }

            Divider()

            statusBar
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.fetchLocalIP()
        }
        .alert("프로세스 종료 확인", isPresented: $viewModel.showKillConfirm) {
            Button("취소", role: .cancel) { }
            Button("종료", role: .destructive) {
                viewModel.killSelectedProcess()
            }
        } message: {
            if let p = viewModel.processToKill {
                Text("'\(p.command)' (PID: \(p.pid)) 프로세스를 종료하시겠습니까?\n이 작업은 되돌릴 수 없습니다.")
            }
        }
    }

    // MARK: - IP Bar

    private var ipBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .font(.caption)
                .foregroundStyle(.blue)

            Text("Port Checker")
                .font(.headline)

            Spacer()

            // 네트워크 타입 (Wi-Fi / Ethernet)
            HStack(spacing: 4) {
                Image(systemName: viewModel.networkType.icon)
                    .font(.caption)
                    .foregroundStyle(viewModel.networkType.color)
                Text(viewModel.networkType.label)
                    .font(.caption)
                    .foregroundStyle(viewModel.networkType.color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(viewModel.networkType.color.opacity(0.1))
            .clipShape(Capsule())

            // IP 주소
            Text(viewModel.localIPAddress)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .textSelection(.enabled)

            Button {
                viewModel.copyIP()
            } label: {
                Image(systemName: viewModel.ipCopiedToast ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(viewModel.ipCopiedToast ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help("IP 주소 복사")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            TextField("포트 번호 (1-65535)", text: $viewModel.portNumber)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onSubmit {
                    viewModel.searchPort()
                }

            Button {
                viewModel.searchPort()
            } label: {
                Label("검색", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isSearching || viewModel.portNumber.isEmpty)

            Divider()
                .frame(height: 20)

            Button {
                viewModel.fetchAllPorts()
            } label: {
                Label("사용 중인 포트", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isSearching)

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("검색 결과가 없습니다")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("포트 번호를 입력하고 검색하세요")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Process List

    private var processList: some View {
        VStack(spacing: 0) {
            // 테이블 헤더
            HStack(spacing: 0) {
                if viewModel.isShowingAllPorts {
                    Text("포트")
                        .frame(width: 70, alignment: .leading)
                }
                Text("프로세스")
                    .frame(width: 110, alignment: .leading)
                Text("PID")
                    .frame(width: 70, alignment: .leading)
                Text("사용자")
                    .frame(width: 80, alignment: .leading)
                Text("타입")
                    .frame(width: 60, alignment: .center)
                Text("연결 정보")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("")
                    .frame(width: 70)
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.processes) { process in
                        processRow(process)
                        Divider()
                    }
                }
            }
        }
    }

    private func processRow(_ process: PortProcess) -> some View {
        HStack(spacing: 0) {
            if viewModel.isShowingAllPorts {
                Text("\(process.port)")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                    .frame(width: 70, alignment: .leading)
            }

            HStack(spacing: 6) {
                Image(systemName: "app.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text(process.command)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)

            Text("\(process.pid)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(process.user)
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)

            Text(process.type)
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    process.type == "IPv6"
                        ? Color.purple.opacity(0.15)
                        : Color.blue.opacity(0.15)
                )
                .foregroundStyle(
                    process.type == "IPv6" ? .purple : .blue
                )
                .clipShape(Capsule())
                .frame(width: 60, alignment: .center)

            Text(process.name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive) {
                viewModel.confirmKill(process)
            } label: {
                Label("Kill", systemImage: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .frame(width: 70, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !viewModel.processes.isEmpty {
                Text("\(viewModel.processes.count)개 프로세스")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

#Preview {
    ContentView()
}
