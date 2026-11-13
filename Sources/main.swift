import SwiftUI
import AppKit
import ServiceManagement
import IOKit.pwr_mgt

// MARK: - Model

struct LogLine: Identifiable {
    let id = UUID()
    let time: String
    let text: String
    let isError: Bool
}

/// Splits a byte stream into complete lines.
final class LineSplitter {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 10) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }
}

enum Health { case stopped, connecting, ready, busy, attention, error }

/// Runs Silicondust's eacapture.php as a child process and turns its log
/// output into observable state for the UI.
@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var running = false
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var device = "Searching…"
    @Published private(set) var checkIn = "Waiting for first check-in"
    @Published private(set) var checkInOK = false
    @Published private(set) var clockDelta = "—"
    @Published private(set) var serverMessage = ""
    @Published private(set) var nextCapture = "—"
    @Published private(set) var activity = "Stopped"
    @Published private(set) var problems: [String] = []
    @Published private(set) var phpMissing = false
    @Published private(set) var keepAwakeActive = false
    private var assertionID: IOPMAssertionID = 0

    private var process: Process?
    private var stopRequested = false
    private var deviceNames: [String: String] = [:]

    /// Set when a setting that is only read at engine start has changed while running.
    @Published private(set) var needsRestart = false
    private var restartWhenStopped = false

    var dataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("eacapture")
    }

    // MARK: Settings (stored in UserDefaults; the views edit them via @AppStorage)

    enum Key {
        static let preserve = "preserveRecordings"
        static let preserveDir = "preserveDir"
        static let autoStart = "autoStartCapturing"
        static let showMenuBar = "showMenuBar"
        static let keepAwake = "keepAwakeWhileRunning"
    }

    static var defaultPreserveDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("eacapture/Preserved").path
    }

    private var preserveArgument: String? {
        let d = UserDefaults.standard
        guard d.bool(forKey: Key.preserve) else { return nil }
        let dir = d.string(forKey: Key.preserveDir) ?? ""
        return dir.isEmpty ? Self.defaultPreserveDir : dir
    }

    /// Called by the settings sheet when a start-time setting changes.
    func settingChangedNeedingRestart() {
        if running { needsRestart = true }
    }

    func restart() {
        needsRestart = false
        guard running else { start(); return }
        restartWhenStopped = true
        stop()
    }

    /// Clears the log but keeps the most recent line so it is never blank.
    func purgeLog() {
        if let last = log.last { log = [last] }
    }

    var health: Health {
        if phpMissing { return .error }
        if !running { return .stopped }
        if !problems.isEmpty { return .attention }
        if !checkInOK { return .connecting }
        if activity.hasPrefix("Recording") || activity.hasPrefix("Uploading") { return .busy }
        return .ready
    }

    var healthTitle: String {
        switch health {
        case .stopped: return "Stopped"
        case .connecting: return "Connecting…"
        case .ready: return "Ready"
        case .busy: return activity.hasPrefix("Recording") ? "Recording" : "Uploading"
        case .attention: return "Needs attention"
        case .error: return "PHP not found"
        }
    }

    // MARK: Start / stop

    /// The PHP that ships inside the app. Developer builds without it fall back
    /// to a Homebrew PHP so the project can still be run from source.
    private func findPHP() -> String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/php").path
        for path in [bundled, "/opt/homebrew/bin/php", "/usr/local/bin/php"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    func start() {
        guard process == nil else { return }

        guard let php = findPHP() else {
            phpMissing = true
            append("EACapture's built-in PHP is missing. Please reinstall the app.", isError: true)
            return
        }
        append(php.contains("/Contents/Helpers/") ? "Using the built-in PHP." : "Using a system PHP (developer build).", isError: false)
        guard let script = Bundle.main.url(forResource: "eacapture", withExtension: "php") else {
            append("The bundled eacapture.php script is missing from the app.", isError: true)
            return
        }
        phpMissing = false

        let p = Process()
        p.executableURL = URL(fileURLWithPath: php)
        // Homebrew's php.ini pins date.timezone to UTC, which makes the script
        // log in UTC. Hand it the Mac's current zone so times are local.
        let zone = TimeZone.autoupdatingCurrent.identifier
        var arguments = ["-n", "-d", "date.timezone=\(zone)", script.path, "--data-dir=\(dataDir.path)"]
        if let preserve = preserveArgument { arguments.append("--preserve-dir=\(preserve)") }
        p.arguments = arguments

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let outSplitter = LineSplitter(), errSplitter = LineSplitter()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let lines = outSplitter.feed(data)
            Task { @MainActor in lines.forEach { self?.handle($0, isStderr: false) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let lines = errSplitter.feed(data)
            Task { @MainActor in lines.forEach { self?.handle($0, isStderr: true) } }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.didExit(code: code) }
        }

        do {
            try p.run()
        } catch {
            append("Could not start: \(error.localizedDescription)", isError: true)
            return
        }

        process = p
        stopRequested = false
        needsRestart = false
        running = true
        problems = []
        checkInOK = false
        checkIn = "Waiting for first check-in"
        device = "Searching…"
        activity = "Starting…"
        updateKeepAwake()
    }

    /// Holds the Mac awake (no idle sleep) while capturing, if the setting is on.
    /// The display and screen saver are free to run. Released when capturing stops.
    func updateKeepAwake() {
        let enabled = UserDefaults.standard.object(forKey: Key.keepAwake) as? Bool ?? true
        let wanted = running && enabled
        if wanted && assertionID == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "EACapture is capturing" as CFString,
                &id)
            if result == kIOReturnSuccess { assertionID = id }
        } else if !wanted && assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        keepAwakeActive = assertionID != 0
    }

    func stop() {
        stopRequested = true
        process?.terminate()
    }

    /// Called when the app quits.
    func shutdown() {
        stopRequested = true
        process?.terminate()
    }

    private func didExit(code: Int32) {
        process = nil
        running = false
        updateKeepAwake()
        nextCapture = "—"
        if stopRequested {
            activity = "Stopped"
            append("EACapture stopped.", isError: false)
        } else {
            activity = "Stopped (exit code \(code))"
            append("EACapture exited unexpectedly (code \(code)).", isError: true)
        }
        if restartWhenStopped {
            restartWhenStopped = false
            start()
        }
    }

    // MARK: Log parsing

    private func append(_ text: String, isError: Bool, time: String? = nil) {
        let t = time ?? Self.clock.string(from: Date())
        log.append(LogLine(time: t, text: text, isError: isError))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private func handle(_ raw: String, isStderr: Bool) {
        var line = raw
        var time: String? = nil
        // The script prefixes lines with "YYYY-MM-DD HH:MM:SS  ".
        if line.count > 21 {
            let chars = Array(line)
            if chars[4] == "-" && chars[7] == "-" && chars[13] == ":" {
                time = String(chars[11..<19])
                line = String(chars[21...])
            }
        }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }

        if isStderr {
            append(line, isError: true, time: time)
            problems = [line]
            return
        }

        let isError = line.hasPrefix("ERROR:") || line.contains("failed") || line.contains("Failed")
        append(line, isError: isError, time: time)

        if line.hasPrefix("Found: ") {
            // "Found: <FriendlyName> <DeviceID>"
            let rest = String(line.dropFirst(7))
            if let space = rest.lastIndex(of: " ") {
                deviceNames[String(rest[rest.index(after: space)...])] = String(rest[..<space])
            }
        } else if line.hasPrefix("Chosen: ") {
            let id = String(line.dropFirst(8))
            device = deviceNames[id].map { "\($0) \(id)" } ?? id
            problems = []
        } else if line.hasPrefix("ERROR: ") {
            let msg = String(line.dropFirst(7))
            if !problems.contains(msg) { problems.append(msg) }
        } else if line.hasPrefix("Device discovery found no devices")
                    || line.hasPrefix("No suitable device found")
                    || line.hasPrefix("Device discovery failed") {
            device = "None found"
            problems = [line + " Make sure an ATSC 3.0 HDHomeRun is on this network."]
        } else if line == "Check-in succeeded." {
            checkInOK = true
            checkIn = "Succeeded at \(Self.shortTime.string(from: Date()))"
            problems = []
            if activity == "Starting…" { activity = "Idle" }
        } else if line.hasPrefix("Clock delta: ") {
            clockDelta = String(line.dropFirst(13))
        } else if line.hasPrefix("Message from server: ") {
            serverMessage = String(line.dropFirst(21))
        } else if line.hasPrefix("Could not decode response") {
            checkInOK = false
            checkIn = "Server reply could not be read"
        } else if line.hasPrefix("Check-in failed") {
            checkInOK = false
            checkIn = "Failed – retrying in 60 seconds"
            if activity == "Starting…" { activity = "Idle" }
        } else if line.hasPrefix("Next capture to run at ") {
            nextCapture = String(line.dropFirst(23))
            activity = "Idle"
        } else if line.hasPrefix("Capturing ") {
            activity = "Recording…"
            nextCapture = "—"
        } else if line.hasPrefix("Upload to run at ") {
            activity = "Upload scheduled for " + String(line.dropFirst(17))
        } else if line.hasPrefix("Uploading ") {
            activity = "Uploading…"
        } else if line.hasPrefix("Push failed") {
            activity = "Upload failed – will retry"
        } else if line.hasPrefix("Capture failed") || line.contains("produced no data") {
            activity = "Last capture failed"
        } else if line.hasPrefix("Capture already in progress") {
            activity = "Waiting for next capture"
        }
    }
}

// MARK: - Views

struct StatusDot: View {
    let health: Health
    var color: Color {
        switch health {
        case .stopped: return .gray
        case .connecting: return .blue
        case .ready: return .green
        case .busy: return .purple
        case .attention: return .orange
        case .error: return .red
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 14, height: 14)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundColor(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
    }
}

struct ContentView: View {
    @ObservedObject var engine: Engine
    @State private var showSettings = false
    @ObservedObject private var endOfTest = EndOfTest.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusDot(health: engine.health)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EACapture").font(.title2).bold()
                    Text(engine.healthTitle).foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button(engine.running ? "Stop" : "Start") {
                    engine.running ? engine.stop() : engine.start()
                }
                .keyboardShortcut(.defaultAction)
            }

            if !engine.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(engine.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            if !engine.serverMessage.isEmpty {
                Label(engine.serverMessage, systemImage: "info.circle.fill")
                    .foregroundColor(.blue)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
            }

            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Tuner", value: engine.device)
                InfoRow(label: "Check-in", value: engine.checkIn)
                InfoRow(label: "Clock offset", value: engine.clockDelta)
                InfoRow(label: "Activity", value: engine.activity)
                InfoRow(label: "Next capture", value: engine.nextCapture)
                InfoRow(label: "Keep awake", value: engine.keepAwakeActive ? "On – this Mac won't sleep while capturing" : "Off")
            }

            HStack {
                Button("Show Captures Folder") {
                    try? FileManager.default.createDirectory(at: engine.dataDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(engine.dataDir)
                }
                Spacer()
            }

            Text("Log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(engine.log) { entry in
                            Text("\(entry.time)  \(entry.text)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(entry.isError ? .red : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                .onChange(of: engine.log.count) { _ in
                    if let last = engine.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if endOfTest.isPast {
                EndedNotice()
            } else {
                EASNotice()
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 600)
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine)
        }
    }
}

/// Tracks when the EAS test period is over and asks the user to uninstall.
@MainActor
final class EndOfTest: ObservableObject {
    static let shared = EndOfTest()

    /// 10 p.m. Eastern on November 17, 2026 (EST, UTC-5) = 03:00 UTC on November 18.
    static let cutoff: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 17; c.hour = 22; c.minute = 0
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c) ?? .distantFuture
    }()

    @Published private(set) var isPast = Date() >= EndOfTest.cutoff
    private var shownThisLaunch = false
    private var timer: Timer?

    /// Checks at launch (after the window has appeared) and every 30 seconds after.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.check() }
        }
    }

    private func check() {
        let past = Date() >= Self.cutoff
        if past != isPast { isPast = past }
        if past && !shownThisLaunch {
            shownThisLaunch = true
            showDialog()
        }
    }

    /// Shown once per launch (or once when the time passes while running).
    func showDialog() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "The EAS test period has ended"
        alert.informativeText = "EACapture is no longer needed, so you can uninstall it now. Uninstalling removes the app and all of its files, including any recordings."
        alert.addButton(withTitle: "Uninstall…")
        alert.addButton(withTitle: "Remind Me Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Uninstaller.confirmAndUninstall(engine: Engine.shared)
        }
    }
}

/// Replaces the EAS notice once the test period is over.
struct EndedNotice: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Label {
                Text("The EAS test period has ended. EACapture is no longer needed, so you can uninstall it now.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
            }
            .foregroundColor(.orange)
            Spacer()
            Button("Uninstall…") { Uninstaller.confirmAndUninstall(engine: Engine.shared) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

/// Reminder shown at the bottom of the window about the national EAS test.
struct EASNotice: View {
    /// 2:20 p.m. Eastern on November 17, 2026 (EST, UTC-5) = 19:20 UTC.
    private static let testTime: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 17; c.hour = 14; c.minute = 20
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }()

    /// e.g. "November 17, 2026, around 11:20 a.m. PT" in the viewer's own time zone.
    private static var whenText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.amSymbol = "a.m."
        f.pmSymbol = "p.m."
        f.dateFormat = "MMMM d, yyyy"
        let day = f.string(from: testTime)
        f.dateFormat = "h:mm a v"
        return "\(day), around \(f.string(from: testTime))"
    }

    var body: some View {
        Label {
            Text("EACapture needs to be running before, during, and after the EAS test for it to be effective. The EAS test will occur on \(Self.whenText).")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.bubble.fill")
        }
        .foregroundColor(.blue)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
    }
}

struct SettingsView: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Engine.Key.preserve) private var preserve = false
    @AppStorage(Engine.Key.preserveDir) private var preserveDir = Engine.defaultPreserveDir
    @AppStorage(Engine.Key.autoStart) private var autoStart = true
    @AppStorage(Engine.Key.showMenuBar) private var showMenuBar = true
    @AppStorage(Engine.Key.keepAwake) private var keepAwake = true

    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title2).bold()

            GroupBox("Recordings") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Preserve recordings", isOn: $preserve)
                        .onChange(of: preserve) { _ in engine.settingChangedNeedingRestart() }
                    Text("Keep a copy of every recording on this Mac. Normally each recording is deleted once it has uploaded.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(preserveDir)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                        Button("Show") {
                            try? FileManager.default.createDirectory(atPath: preserveDir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(URL(fileURLWithPath: preserveDir))
                        }
                    }
                    .disabled(!preserve)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("General") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Start capturing when EACapture opens", isOn: $autoStart)
                    Toggle("Keep this Mac awake while capturing", isOn: $keepAwake)
                        .onChange(of: keepAwake) { _ in engine.updateKeepAwake() }
                    Toggle("Show menu bar icon", isOn: $showMenuBar)
                    Toggle("Open at login", isOn: Binding(
                        get: { loginOn },
                        set: { newValue in
                            do {
                                if newValue { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                            }
                            loginOn = SMAppService.mainApp.status == .enabled
                        }
                    ))
                    if let loginError {
                        Text(loginError).font(.caption).foregroundColor(.red)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Log") {
                HStack {
                    Text("Clear the log window. The most recent line is kept.")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Purge Log") { engine.purgeLog() }
                }
                .padding(6)
            }

            if engine.needsRestart {
                HStack {
                    Label("Restart capturing to apply your changes.", systemImage: "arrow.clockwise")
                        .foregroundColor(.orange)
                    Spacer()
                    Button("Restart Now") { engine.restart() }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where to keep copies of recordings."
        if panel.runModal() == .OK, let url = panel.url {
            preserveDir = url.path
            engine.settingChangedNeedingRestart()
        }
    }
}

// MARK: - Uninstall

@MainActor
enum Uninstaller {
    private static let bundleID = "local.eacapture.mac"

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Our own naming for preserved recordings: 20261113-024000Z_name.dbg
    private static func isPreservedName(_ name: String) -> Bool {
        name.range(of: #"^\d{8}-\d{6}Z_"#, options: .regularExpression) != nil
    }

    private static func summary(of dir: URL, only filter: ((String) -> Bool)? = nil) -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return (0, 0) }
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            if let filter, !filter(url.lastPathComponent) { continue }
            count += 1
            bytes += Int64(v?.fileSize ?? 0)
        }
        return (count, bytes)
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func confirmAndUninstall(engine: Engine) {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        let dataDir = engine.dataDir
        let home = fm.homeDirectoryForCurrentUser

        // An older Terminal-launcher copy of this app, if present.
        let oldCopy = home.appendingPathComponent("Applications/EACapture.app")
        let oldCopyIsOurs = oldCopy.path != appURL.path
            && (Bundle(url: oldCopy)?.bundleIdentifier == bundleID)

        // A preserve folder outside ~/eacapture is the user's own: only our files go.
        var customPreserve: URL? = nil
        if let p = UserDefaults.standard.string(forKey: Engine.Key.preserveDir), !p.isEmpty {
            let url = URL(fileURLWithPath: p)
            if !url.path.hasPrefix(dataDir.path + "/") && fm.fileExists(atPath: p) { customPreserve = url }
        }

        let data = summary(of: dataDir)
        var lines: [String] = []
        lines.append("• The app: \(appURL.path)")
        if oldCopyIsOurs { lines.append("• The older copy: \(oldCopy.path)") }
        lines.append("• All captures and data in \(dataDir.path) (\(data.count) files, \(sizeText(data.bytes))), including preserved recordings kept there")
        if let customPreserve {
            let s = summary(of: customPreserve, only: isPreservedName)
            lines.append("• Preserved recordings in \(customPreserve.path) (\(s.count) files, \(sizeText(s.bytes))); the folder itself and any other files are kept")
        }
        lines.append("• EACapture's settings and its “Open at login” entry")

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Uninstall EACapture?"
        alert.informativeText = "If you uninstall EACapture, all captures and components will be deleted too. This cannot be undone.\n\nThis will permanently delete:\n"
            + lines.joined(separator: "\n")
            + "\n\nHomebrew PHP and any source files are not touched."
        alert.addButton(withTitle: "Cancel")
        let uninstall = alert.addButton(withTitle: "Uninstall")
        uninstall.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        perform(engine: engine, appURL: appURL, dataDir: dataDir,
                oldCopy: oldCopyIsOurs ? oldCopy : nil, customPreserve: customPreserve)
    }

    private static func perform(engine: Engine, appURL: URL, dataDir: URL, oldCopy: URL?, customPreserve: URL?) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Stop capturing and remove the login item first.
        engine.shutdown()
        try? SMAppService.mainApp.unregister()

        // Preserved recordings in a user-chosen folder: only files we named.
        if let dir = customPreserve,
           let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in names where isPreservedName(name) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }

        // Things that can't be deleted while the app is running are finished by
        // a detached shell once this process has exited.
        var targets: [String] = []
        if appURL.pathExtension == "app" { targets.append(appURL.path) }
        if let oldCopy, oldCopy.pathExtension == "app" { targets.append(oldCopy.path) }
        if dataDir.lastPathComponent == "eacapture" { targets.append(dataDir.path) }
        targets.append(home.appendingPathComponent("Library/Preferences/\(bundleID).plist").path)
        targets.append(home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState").path)
        targets.append(home.appendingPathComponent("Library/Caches/\(bundleID)").path)
        targets.append(home.appendingPathComponent("Library/HTTPStorages/\(bundleID)").path)

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        pkill -f \(shellQuote(appURL.path + "/Contents/Resources/eacapture.php")) 2>/dev/null
        sleep 0.5
        rm -rf \(targets.map(shellQuote).joined(separator: " "))
        defaults delete \(bundleID) 2>/dev/null
        killall cfprefsd 2>/dev/null
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()

        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        NSApp.terminate(nil)
    }
}

struct MenuContent: View {
    @ObservedObject var engine: Engine
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var endOfTest = EndOfTest.shared

    var body: some View {
        Text("EACapture – \(engine.healthTitle)")
        if endOfTest.isPast { Text("EAS test period has ended – you can uninstall") }
        if engine.nextCapture != "—" { Text("Next capture: \(engine.nextCapture)") }
        Divider()
        Button("Show Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(engine.running ? "Stop" : "Start") {
            engine.running ? engine.stop() : engine.start()
        }
        Divider()
        Button("Uninstall EACapture…") { Uninstaller.confirmAndUninstall(engine: engine) }
        Button("Quit EACapture") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let autoStart = UserDefaults.standard.object(forKey: Engine.Key.autoStart) as? Bool ?? true
        if autoStart { Engine.shared.start() }
        EndOfTest.shared.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.shutdown()
    }
}

@main
struct EACaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine.shared
    @AppStorage(Engine.Key.showMenuBar) private var showMenuBar = true

    var body: some Scene {
        Window("EACapture", id: "main") {
            ContentView(engine: engine)
        }
        .commands {
            // Same action as the menu bar item, for when the menu bar icon is hidden.
            CommandGroup(after: .appSettings) {
                Button("Uninstall EACapture…") { Uninstaller.confirmAndUninstall(engine: engine) }
            }
        }
        MenuBarExtra("EACapture", systemImage: "antenna.radiowaves.left.and.right", isInserted: $showMenuBar) {
            MenuContent(engine: engine)
        }
    }
}
