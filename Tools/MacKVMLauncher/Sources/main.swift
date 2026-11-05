// MacKVM Launcher: a small SwiftUI app that keeps the server settings, starts and
// stops the bundled `MacKVM serve` process, shows its log, and restarts the Linux
// client over ssh. The server itself is unchanged; this app only builds its
// command line.
import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Settings

struct LauncherSettings: Codable, Equatable {
  var role = "server"
  var clientName = "user-HP-ProBook"
  var edge = "right"
  var port = 24800
  var loopbackOnly = false
  var identityLabel = "MacKVM E2E dev BA52FA10-ED49-48E9-B3C8-B63240AC44FD"
  /// Empty = the MacKVM binary inside this app bundle.
  var serverBinary = ""
  var clientSSHHost = "jetubuntu"
  var clientRestartCommand = "pkill -x barrierc"
  var autoStartServer = false

  init() {}

  // Missing keys keep their defaults, so older or partial files still load.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = LauncherSettings()
    role = try c.decodeIfPresent(String.self, forKey: .role) ?? d.role
    clientName = try c.decodeIfPresent(String.self, forKey: .clientName) ?? d.clientName
    edge = try c.decodeIfPresent(String.self, forKey: .edge) ?? d.edge
    port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
    loopbackOnly = try c.decodeIfPresent(Bool.self, forKey: .loopbackOnly) ?? d.loopbackOnly
    identityLabel = try c.decodeIfPresent(String.self, forKey: .identityLabel) ?? d.identityLabel
    serverBinary = try c.decodeIfPresent(String.self, forKey: .serverBinary) ?? d.serverBinary
    clientSSHHost = try c.decodeIfPresent(String.self, forKey: .clientSSHHost) ?? d.clientSSHHost
    clientRestartCommand =
      try c.decodeIfPresent(String.self, forKey: .clientRestartCommand) ?? d.clientRestartCommand
    autoStartServer = try c.decodeIfPresent(Bool.self, forKey: .autoStartServer) ?? d.autoStartServer
  }

  var arguments: [String] {
    var a = ["serve", "--client", clientName, "--edge", edge, "--port", String(port)]
    if loopbackOnly { a.append("--loopback-only") }
    if !identityLabel.isEmpty { a += ["--identity-label", identityLabel] }
    return a
  }

  func validationError() -> String? {
    let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    if clientName.isEmpty || clientName.count > 64
      || clientName.unicodeScalars.contains(where: { !ok.contains($0) })
    {
      return "Client 名稱只能用英數字、- 和 _（1–64 字）"
    }
    if !(1...65535).contains(port) { return "連接埠要在 1–65535" }
    return nil
  }
}

enum ConfigFiles {
  static let home = FileManager.default.homeDirectoryForCurrentUser
  /// Where the app saves its own settings.
  static let saved = home.appendingPathComponent("Library/Application Support/MacKVM/config.json")
  /// A hand-written settings file the app offers to apply when it differs.
  static let external = home.appendingPathComponent(".config/mackvm/config.json")

  static func load(_ url: URL) -> LauncherSettings? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(LauncherSettings.self, from: data)
  }

  static func save(_ s: LauncherSettings, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try e.encode(s).write(to: url, options: .atomic)
  }
}

// MARK: - Process control

@MainActor
final class ServerController: ObservableObject {
  @Published var settings: LauncherSettings
  @Published var log: [String] = []
  @Published var running = false
  @Published var pendingExternal: LauncherSettings?
  @Published var notice: String?

  private var process: Process?

  /// The newest server line, without its timestamp, for the status strip.
  var lastStatus: String {
    guard let line = log.last(where: { !$0.contains("DIAG") }) else { return "按「開始分享」啟動 server" }
    if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
      return String(line[line.index(after: end)...]).trimmingCharacters(in: .whitespaces)
    }
    return line
  }

  init() {
    settings = ConfigFiles.load(ConfigFiles.saved) ?? LauncherSettings()
    if let ext = ConfigFiles.load(ConfigFiles.external), ext != settings {
      pendingExternal = ext
    }
    if settings.autoStartServer, pendingExternal == nil { start() }
  }

  var binaryURL: URL {
    if !settings.serverBinary.isEmpty { return URL(fileURLWithPath: settings.serverBinary) }
    return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MacKVM")
  }

  func save() {
    do {
      try ConfigFiles.save(settings, to: ConfigFiles.saved)
      notice = "已儲存到 \(ConfigFiles.saved.path)"
    } catch { notice = "儲存失敗：\(error.localizedDescription)" }
  }

  func applyExternal() {
    guard let ext = pendingExternal else { return }
    settings = ext
    pendingExternal = nil
    save()
  }

  func importFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if let s = ConfigFiles.load(url) {
      settings = s
      save()
    } else {
      notice = "這個檔案不是有效的設定檔"
    }
  }

  func exportFile() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "mackvm-config.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try ConfigFiles.save(settings, to: url)
      notice = "已匯出到 \(url.path)"
    } catch { notice = "匯出失敗：\(error.localizedDescription)" }
  }

  func start() {
    guard !running else { return }
    if let err = settings.validationError() {
      notice = err
      return
    }
    guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
      notice = "找不到 server 執行檔：\(binaryURL.path)"
      return
    }
    // The server runs as a child of this app, so macOS checks this app's
    // permissions. Ask here, where the system can show its own prompts.
    let ax = AXIsProcessTrustedWithOptions(
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    let listen = CGPreflightListenEventAccess() || CGRequestListenEventAccess()
    if !ax || !listen {
      notice = "請在「系統設定 → 隱私權與安全性」的「輔助使用」和「輸入監控」打開 MacKVM，再按開始分享。"
      openPrivacyPane(ax ? "Privacy_ListenEvent" : "Privacy_Accessibility")
      return
    }
    save()
    let p = Process()
    p.executableURL = binaryURL
    p.arguments = settings.arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      Task { @MainActor in self?.append(text) }
    }
    p.terminationHandler = { [weak self] proc in
      Task { @MainActor in
        self?.running = false
        self?.process = nil
        self?.append("— server 已結束（代碼 \(proc.terminationStatus)）\n")
        if proc.terminationStatus == 77 {
          self?.notice = "缺少「輔助使用」或「輸入監控」權限：請在系統設定打開 MacKVM 後重新開始分享。"
        }
      }
    }
    do {
      try p.run()
      process = p
      running = true
      append("— 啟動：MacKVM \(settings.arguments.joined(separator: " "))\n")
    } catch {
      notice = "啟動失敗：\(error.localizedDescription)"
    }
  }

  func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
      NSWorkspace.shared.open(url)
    }
  }

  func stop() {
    guard let p = process, p.isRunning else { return }
    p.interrupt()  // SIGINT, same as Ctrl-C: the server releases keys and restores the cursor.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
  }

  func restartClient() {
    let host = settings.clientSSHHost
    let cmd = settings.clientRestartCommand
    append("— 重啟 client：ssh \(host) '\(cmd)'\n")
    Task.detached {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, cmd]
      let pipe = Pipe()
      p.standardOutput = pipe
      p.standardError = pipe
      var out = ""
      do {
        try p.run()
        p.waitUntilExit()
        out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        out += "— ssh 結束（代碼 \(p.terminationStatus)）；client 約 5 秒後自動重連\n"
      } catch { out = "— ssh 失敗：\(error.localizedDescription)\n" }
      let text = out
      await MainActor.run { self.append(text) }
    }
  }

  private func append(_ text: String) {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      log.append(String(line))
    }
    if log.count > 2000 { log.removeFirst(log.count - 2000) }
  }
}

// MARK: - UI
//
// Design: the window is a plan view of the desk. The hero draws this Mac and the
// Linux screen as two slabs; the seam between them is the link the pointer
// crosses, and it lights cobalt while the server runs. Clicking another side of
// the Mac slab moves the client there. Everything below the hero stays quiet.

enum Palette {
  static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { a in
      let v = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
        blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    })
  }
  static let canvas = dyn(0xE9EDF1, 0x14181D)
  static let sheet = dyn(0xFFFFFF, 0x1D232A)
  static let ink = dyn(0x17212B, 0xE6ECF2)
  static let graphite = dyn(0x5E6B77, 0x93A1AE)
  static let hairline = dyn(0xD3DAE1, 0x2C343D)
  static let cobalt = dyn(0x2D5BE3, 0x6E93FF)
  static let live = dyn(0x12A06E, 0x3CCB93)
}

struct ContentView: View {
  @EnvironmentObject var c: ServerController
  @State private var showLog = false

  var body: some View {
    VStack(spacing: 0) {
      if let ext = c.pendingExternal { ExternalBanner(ext: ext) }
      DeskPlan()
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
      ControlStrip(showLog: $showLog)
        .padding(.horizontal, 28)
      if showLog {
        LogPane().padding(.horizontal, 28).padding(.top, 14)
      } else {
        HStack(alignment: .top, spacing: 14) {
          ConnectionSheet()
          ClientSheet()
        }
        .padding(.horizontal, 28).padding(.top, 14)
      }
      Spacer(minLength: 0)
      Footer().padding(.horizontal, 28).padding(.vertical, 14)
    }
    .frame(minWidth: 720, idealWidth: 760, minHeight: 640, idealHeight: 680)
    .background(Palette.canvas)
    .foregroundStyle(Palette.ink)
  }
}

// The hero: a plan view of the two screens and the link between them.
struct DeskPlan: View {
  @EnvironmentObject var c: ServerController
  @State private var pulse = false

  var body: some View {
    let edge = c.settings.edge
    let horizontal = edge == "left" || edge == "right"
    GeometryReader { geo in
      let mac = CGSize(width: 220, height: 138)
      let linux = CGSize(width: 200, height: 124)
      let gap: CGFloat = 26
      let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
      let total = horizontal ? mac.width + gap + linux.width : mac.height + gap + linux.height
      let macCenter: CGPoint = {
        switch edge {
        case "left": CGPoint(x: center.x + total / 2 - mac.width / 2, y: center.y)
        case "top": CGPoint(x: center.x, y: center.y + total / 2 - mac.height / 2)
        case "bottom": CGPoint(x: center.x, y: center.y - total / 2 + mac.height / 2)
        default: CGPoint(x: center.x - total / 2 + mac.width / 2, y: center.y)
        }
      }()
      let offset: CGPoint = {
        let dx = mac.width / 2 + gap + linux.width / 2
        let dy = mac.height / 2 + gap + linux.height / 2
        switch edge {
        case "left": return CGPoint(x: -dx, y: 0)
        case "top": return CGPoint(x: 0, y: -dy)
        case "bottom": return CGPoint(x: 0, y: dy)
        default: return CGPoint(x: dx, y: 0)
        }
      }()
      let linuxCenter = CGPoint(x: macCenter.x + offset.x, y: macCenter.y + offset.y)
      let seam = CGPoint(
        x: macCenter.x + offset.x * (horizontal ? (mac.width / 2 + gap / 2) / offset.x : 0),
        y: macCenter.y + (horizontal ? 0 : offset.y * (mac.height / 2 + gap / 2) / offset.y))

      ZStack {
        // Seam: the edge the pointer crosses.
        Capsule()
          .fill(c.running ? Palette.cobalt : Palette.hairline)
          .frame(width: horizontal ? 4 : 120, height: horizontal ? 90 : 4)
          .shadow(color: c.running ? Palette.cobalt.opacity(pulse ? 0.55 : 0.15) : .clear, radius: 10)
          .position(seam)
          .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)

        Slab(
          title: "這台 Mac", subtitle: Host.current().localizedName ?? "MacKVM server",
          symbol: "laptopcomputer", size: mac, emphasized: true
        )
        .position(macCenter)

        Slab(
          title: c.settings.clientName.isEmpty ? "Linux" : c.settings.clientName,
          subtitle: c.settings.clientSSHHost, symbol: "desktopcomputer", size: linux,
          emphasized: false
        )
        .position(linuxCenter)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: edge)

        ForEach(["left", "right", "top", "bottom"].filter { $0 != edge }, id: \.self) { side in
          EdgeHandle(side: side)
            .position(handlePosition(side, macCenter: macCenter, mac: mac))
        }
      }
      .animation(.spring(response: 0.45, dampingFraction: 0.8), value: edge)
    }
    .frame(height: 250)
    .background(
      RoundedRectangle(cornerRadius: 14).fill(Palette.sheet)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline))
    )
    .overlay(alignment: .topLeading) {
      Text("滑鼠從亮起的那條邊移出去，就會到 Linux。點 Mac 其他邊可以換位置。")
        .font(.callout).foregroundStyle(Palette.graphite)
        .padding(14)
    }
    .onAppear { pulse = true }
    .disabled(c.running)
  }

  private func handlePosition(_ side: String, macCenter: CGPoint, mac: CGSize) -> CGPoint {
    switch side {
    case "left": CGPoint(x: macCenter.x - mac.width / 2 - 14, y: macCenter.y)
    case "right": CGPoint(x: macCenter.x + mac.width / 2 + 14, y: macCenter.y)
    case "top": CGPoint(x: macCenter.x, y: macCenter.y - mac.height / 2 - 14)
    default: CGPoint(x: macCenter.x, y: macCenter.y + mac.height / 2 + 14)
    }
  }
}

struct Slab: View {
  let title: String
  let subtitle: String
  let symbol: String
  let size: CGSize
  let emphasized: Bool

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: symbol).font(.system(size: 26, weight: .light))
      Text(title).font(.system(.headline, design: .rounded))
        .lineLimit(1).truncationMode(.middle)
      Text(subtitle).font(.caption).foregroundStyle(Palette.graphite).lineLimit(1)
    }
    .padding(.horizontal, 10)
    .frame(width: size.width, height: size.height)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(emphasized ? Palette.canvas : Palette.sheet)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          emphasized ? Palette.ink.opacity(0.75) : Palette.graphite,
          style: StrokeStyle(lineWidth: emphasized ? 1.5 : 1, dash: emphasized ? [] : [5, 4]))
    )
  }
}

struct EdgeHandle: View {
  @EnvironmentObject var c: ServerController
  let side: String
  @State private var hover = false

  var body: some View {
    Button {
      c.settings.edge = side
      c.save()
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 20, height: 20)
        .background(Circle().fill(hover ? Palette.cobalt : Palette.sheet))
        .overlay(Circle().strokeBorder(hover ? Palette.cobalt : Palette.hairline))
        .foregroundStyle(hover ? Color.white : Palette.graphite)
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help("把 Linux 放到\(["left": "左邊", "right": "右邊", "top": "上面", "bottom": "下面"][side] ?? side)")
    .accessibilityLabel("把 Linux 放到 \(side)")
  }
}

struct ControlStrip: View {
  @EnvironmentObject var c: ServerController
  @Binding var showLog: Bool

  var body: some View {
    HStack(spacing: 14) {
      Button {
        c.running ? c.stop() : c.start()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: c.running ? "stop.fill" : "play.fill")
          Text(c.running ? "停止分享" : "開始分享")
        }
        .font(.system(.body, design: .rounded).weight(.semibold))
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(Capsule().fill(c.running ? Palette.ink : Palette.cobalt))
        .foregroundStyle(c.running ? Palette.sheet : Color.white)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.return, modifiers: .command)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Circle().fill(c.running ? Palette.live : Palette.graphite.opacity(0.5))
            .frame(width: 7, height: 7)
          Text(c.running ? "分享中" : "未分享").font(.subheadline.weight(.medium))
        }
        Text(c.lastStatus).font(.caption).foregroundStyle(Palette.graphite).lineLimit(1)
      }
      Spacer()
      Picker("", selection: $showLog) {
        Text("設定").tag(false)
        Text("記錄").tag(true)
      }
      .pickerStyle(.segmented)
      .frame(width: 140)
      .labelsHidden()
    }
  }
}

struct SheetBox<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.system(.subheadline, design: .rounded).weight(.semibold))
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 12).fill(Palette.sheet)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    )
  }
}

struct Field<Content: View>: View {
  let label: String
  var hint: String? = nil
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption).foregroundStyle(Palette.graphite)
      content
      if let hint { Text(hint).font(.caption2).foregroundStyle(Palette.graphite) }
    }
  }
}

struct ConnectionSheet: View {
  @EnvironmentObject var c: ServerController
  @State private var advanced = false
  var body: some View {
    SheetBox(title: "這台 Mac") {
      Field(label: "Linux 的螢幕名稱", hint: "要跟 Linux 端 barrierc 的 --name 一樣") {
        TextField("", text: $c.settings.clientName).textFieldStyle(.roundedBorder)
      }
      Field(label: "連接埠") {
        TextField("", value: $c.settings.port, format: .number.grouping(.never))
          .textFieldStyle(.roundedBorder).frame(width: 100)
      }
      Toggle("開啟 App 時自動開始分享", isOn: $c.settings.autoStartServer)
      DisclosureGroup("進階", isExpanded: $advanced) {
        VStack(alignment: .leading, spacing: 10) {
          Toggle("只接受本機連線", isOn: $c.settings.loopbackOnly)
          Field(label: "憑證身分標籤", hint: "換掉會產生新憑證，Linux 要重新信任") {
            TextField("", text: $c.settings.identityLabel).textFieldStyle(.roundedBorder)
          }
          Field(label: "Server 程式（留空用 App 內建）") {
            TextField("", text: $c.settings.serverBinary).textFieldStyle(.roundedBorder)
          }
        }
        .padding(.top, 8)
      }
      .font(.callout)
    }
    .disabled(c.running)
    .onSubmit { c.save() }
  }
}

struct ClientSheet: View {
  @EnvironmentObject var c: ServerController
  var body: some View {
    SheetBox(title: "Linux client") {
      Field(label: "SSH 主機") {
        TextField("", text: $c.settings.clientSSHHost).textFieldStyle(.roundedBorder)
      }
      Field(label: "重啟指令", hint: "Linux 上的 run-client.sh 會在 5 秒後自動重連") {
        TextField("", text: $c.settings.clientRestartCommand).textFieldStyle(.roundedBorder)
      }
      Button {
        c.restartClient()
      } label: {
        Label("重啟 Linux client", systemImage: "arrow.clockwise")
      }
      .help("滑鼠卡住或不動時先按這個")
    }
    .onSubmit { c.save() }
  }
}

struct LogPane: View {
  @EnvironmentObject var c: ServerController
  @State private var diagOnly = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Toggle("只看 DIAG", isOn: $diagOnly).toggleStyle(.checkbox)
        Spacer()
        Button("複製全部") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(c.log.joined(separator: "\n"), forType: .string)
        }
        Button("清除") { c.log.removeAll() }
      }
      ScrollViewReader { proxy in
        ScrollView {
          let lines = diagOnly ? c.log.filter { $0.contains("DIAG") } : c.log
          LazyVStack(alignment: .leading, spacing: 2) {
            if lines.isEmpty {
              Text("開始分享後，server 的訊息會出現在這裡。")
                .foregroundStyle(Palette.graphite).padding(.vertical, 20)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
              Text(line)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.contains("DIAG") ? Palette.cobalt : Palette.ink)
                .textSelection(.enabled).id(i)
            }
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: c.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
      }
      .frame(minHeight: 220)
      .background(
        RoundedRectangle(cornerRadius: 12).fill(Palette.sheet)
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
      )
    }
  }
}

struct Footer: View {
  @EnvironmentObject var c: ServerController
  var body: some View {
    HStack(spacing: 14) {
      Text("⌃⌥⌘↩ 隨時把滑鼠鍵盤拉回這台 Mac")
        .font(.caption).foregroundStyle(Palette.graphite)
      if let n = c.notice {
        Text(n).font(.caption).foregroundStyle(Palette.cobalt).lineLimit(1)
          .onTapGesture { c.notice = nil }
      }
      Spacer()
      Button("匯入設定檔…") { c.importFile() }.buttonStyle(.link)
      Button("匯出設定檔…") { c.exportFile() }.buttonStyle(.link)
    }
    .font(.caption)
  }
}

struct ExternalBanner: View {
  @EnvironmentObject var c: ServerController
  let ext: LauncherSettings
  @State private var showDiff = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: "doc.badge.arrow.up").foregroundStyle(Palette.cobalt)
        Text("找到設定檔 ~/.config/mackvm/config.json，內容跟目前不同。").font(.callout)
        Spacer()
        Button(showDiff ? "收起" : "看差異") { showDiff.toggle() }.buttonStyle(.link)
        Button("略過") { c.pendingExternal = nil }
        Button("套用設定檔") { c.applyExternal() }.buttonStyle(.borderedProminent)
      }
      if showDiff {
        Text(diffText).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.graphite)
      }
    }
    .padding(.horizontal, 28).padding(.vertical, 12)
    .background(Palette.cobalt.opacity(0.08))
    .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
  }

  var diffText: String {
    let a = c.settings, b = ext
    var lines: [String] = []
    func row(_ name: String, _ x: String, _ y: String) { if x != y { lines.append("\(name): \(x) → \(y)") } }
    row("clientName", a.clientName, b.clientName)
    row("edge", a.edge, b.edge)
    row("port", "\(a.port)", "\(b.port)")
    row("loopbackOnly", "\(a.loopbackOnly)", "\(b.loopbackOnly)")
    row("identityLabel", a.identityLabel, b.identityLabel)
    row("serverBinary", a.serverBinary, b.serverBinary)
    row("clientSSHHost", a.clientSSHHost, b.clientSSHHost)
    row("clientRestartCommand", a.clientRestartCommand, b.clientRestartCommand)
    row("autoStartServer", "\(a.autoStartServer)", "\(b.autoStartServer)")
    return lines.joined(separator: "\n")
  }
}

// MARK: - Menu bar

struct MenuBarContent: View {
  @EnvironmentObject var c: ServerController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text(c.running ? "分享中 → \(c.settings.clientName)" : "未分享")
    Divider()
    Button(c.running ? "停止分享" : "開始分享") { c.running ? c.stop() : c.start() }
    Button("重啟 Linux client") { c.restartClient() }
    Divider()
    Button("開啟 MacKVM 視窗…") { showMainWindow() }
    Divider()
    Button("結束 MacKVM（會停止分享）") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private func showMainWindow() {
    NSApp.setActivationPolicy(.regular)
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var controller: ServerController?
  private var observer: NSObjectProtocol?

  /// Closing the window keeps the app (and the server) running in the menu bar.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationDidFinishLaunching(_ notification: Notification) {
    observer = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { note in
      guard let w = note.object as? NSWindow, w.identifier?.rawValue.hasPrefix("main") == true
      else { return }
      // Leave the Dock and live only in the menu bar.
      DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    NSApp.setActivationPolicy(.regular)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { controller?.stop() }
    Thread.sleep(forTimeInterval: 1)
  }
}

@main
struct MacKVMLauncherApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var controller = ServerController()

  var body: some Scene {
    Window("MacKVM", id: "main") {
      ContentView()
        .environmentObject(controller)
        .onAppear { delegate.controller = controller }
    }
    .windowResizability(.contentMinSize)

    MenuBarExtra {
      MenuBarContent().environmentObject(controller)
    } label: {
      Image(systemName: controller.running ? "rectangle.connected.to.line.below" : "rectangle.on.rectangle")
    }
  }
}
