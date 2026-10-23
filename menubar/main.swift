// SuperCaffeinate: a menu bar item that mirrors ~/bin/supercaffeinate.
//
// State model matches the script exactly. /tmp/supercaffeinate.state holds
// the "caffeinate -ims" pid, the previous screensaver idleTime, the lid
// watcher pid, the auto-off deadline in epoch seconds (line 4, 0 or missing
// when there is no timer), the mode (line 5, "claude" or empty) and the Claude
// grace in seconds (line 6). The script's is_on() is "file exists AND kill -0
// pid succeeds", so a state file whose pid is dead is neither on nor off, it
// is broken, and this app says so instead of guessing.
//
// Health (sudoers rule, stale pmset disablesleep, watcher alive, Claude
// sessions) comes from `supercaffeinate check`, run when the menu opens and
// once at launch. Script failures and warnings are captured from stderr and
// shown in the menu and as a notification instead of being dropped.

import AppKit
import UserNotifications

let statePath = "/tmp/supercaffeinate.state"
// Written by the script's auto-off path just before it turns off; read and
// deleted here when the off transition is seen, so the notification can say why.
let offReasonPath = "/tmp/supercaffeinate.offreason"
let scriptPath = NSHomeDirectory() + "/bin/supercaffeinate"
let setupPath = NSHomeDirectory() + "/bin/supercaffeinate-setup"

enum CaffState: Equatable {
    case off
    case on(pid: pid_t, since: Date?, deadline: Date?, mode: String, grace: Int, watcherAlive: Bool)
    case broken(pid: pid_t)
}

// Cheap poll: one stat plus one kill(pid, 0) per pid. No subprocesses on the tick.
func readState() -> CaffState {
    var st = stat()
    guard stat(statePath, &st) == 0 else { return .off }

    guard let text = try? String(contentsOfFile: statePath, encoding: .utf8) else { return .off }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let first = lines.first, let pid = pid_t(first), pid > 0 else {
        return .off
    }

    // The state file is written the moment the script turns on, so its
    // modification time is when the current session started.
    let since = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))

    // Line 4: auto-off deadline, absent or 0 when the session is indefinite.
    var deadline: Date?
    if lines.count > 3, let secs = TimeInterval(lines[3]), secs > 0 {
        deadline = Date(timeIntervalSince1970: secs)
    }
    let mode = lines.count > 4 ? lines[4] : ""
    let grace = lines.count > 5 ? (Int(lines[5]) ?? 900) : 900

    // Line 3: the lid watcher. If it died the display hold, lid blackout,
    // timer and Claude checks are all gone even though caffeinate is alive.
    var watcherAlive = false
    if lines.count > 2, let wpid = pid_t(lines[2]), wpid > 0 {
        watcherAlive = kill(wpid, 0) == 0
    }

    if kill(pid, 0) == 0 {
        return .on(pid: pid, since: since, deadline: deadline, mode: mode, grace: grace, watcherAlive: watcherAlive)
    }
    return .broken(pid: pid)
}

// Runs an executable and returns stdout, stderr and the exit code. Only used
// when the menu is about to open or an action runs, never on a poll tick.
func capture(_ path: String, _ args: [String]) -> (out: String, err: String, status: Int32) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do {
        try proc.run()
    } catch {
        return ("", "could not run \(path): \(error.localizedDescription)", 127)
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            proc.terminationStatus)
}

func ioreg(_ args: [String]) -> String {
    capture("/usr/sbin/ioreg", args).out
}

func lidClosed() -> Bool {
    ioreg(["-r", "-k", "AppleClamshellState", "-d", "1"]).contains("\"AppleClamshellState\" = Yes")
}

// Same test as the script's external_display_online: the DCP AV service proxy
// with Location External exists only while an external display is connected.
// In that case the script skips the lid-closed blank (clamshell mode).
func externalDisplayOnline() -> Bool {
    ioreg(["-r", "-c", "DCPAVServiceProxy", "-d", "1"]).contains("\"Location\" = \"External\"")
}

// `supercaffeinate check` as a dictionary (sudoers, screenblank, sleepdisabled,
// state, watcher, mode, grace, claude_sessions, claude_active).
func readHealth() -> [String: String] {
    var h: [String: String] = [:]
    for line in capture(scriptPath, ["check"]).out.split(separator: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        h[String(line[..<eq])] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
    }
    return h
}

// Seconds to "7h 42m", "8h", "45m" (minutes rounded up), or "30s" under a
// minute. Same wording as the script's fmt_duration.
func formatDuration(_ secs: Int) -> String {
    if secs < 60 { return "\(max(secs, 0))s" }
    let mins = (secs + 59) / 60
    let h = mins / 60
    let m = mins % 60
    if h > 0 && m > 0 { return "\(h)h \(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}

// Whole minutes from now until the next occurrence of HH:MM local time.
func minutesUntilNext(hour: Int, minute: Int) -> Int {
    let cal = Calendar.current
    let now = Date()
    var target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    if target <= now { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
    return max(1, Int((target.timeIntervalSince(now) / 60).rounded(.up)))
}

// Duration presets in the Turn On For submenu: title and the script argument.
let presets: [(String, String)] = [
    ("30 minutes", "30m"),
    ("1 hour", "1h"),
    ("2 hours", "2h"),
    ("4 hours", "4h"),
    ("8 hours", "8h"),
]

final class Controller: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var state: CaffState = .off
    var timer: Timer?
    var busy = false
    // False until the first poll has seeded the state, so launching the app
    // never posts a notification for a switch it did not see happen.
    var seeded = false
    // Last failure or warning from the script, shown in the menu until the
    // next clean run.
    var lastProblem: String?
    // Health from `supercaffeinate check`, refreshed when the menu opens.
    var health: [String: String] = [:]

    override init() {
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        refresh(force: true)
        let t = Timer(timeInterval: 2.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc func tick() {
        refresh(force: false)
    }

    func refresh(force: Bool) {
        let new = readState()
        if !force && new == state { return }
        let old = state
        state = new
        if seeded {
            notifyTransition(from: old, to: new)
        }
        seeded = true
        applyIcon()
        log(describe(new))
    }

    // Notifications are posted from here rather than by the script's
    // osascript call, so they carry this app's icon. The script skips its own
    // notification while this app is running.
    func startNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                FileHandle.standardError.write(Data("notification authorization error: \(error)\n".utf8))
            } else {
                self.log("notification authorization granted=\(granted)")
            }
        }
    }

    // One health pass at launch, off the main thread: a missing sudoers rule
    // or a stale disablesleep after a reboot is worth a banner right away.
    func startupHealthCheck() {
        DispatchQueue.global(qos: .utility).async {
            let h = readHealth()
            DispatchQueue.main.async {
                self.health = h
                if h["sudoers"] == "missing" {
                    self.post("Setup needed: lid close can still sleep the Mac. Run supercaffeinate-setup.")
                }
                if h["state"] == "off" && h["sleepdisabled"] == "1" {
                    self.post("Sleep is still disabled from an earlier session. Use Restore Normal Sleep.")
                }
            }
        }
    }

    func notifyTransition(from old: CaffState, to new: CaffState) {
        switch (old, new) {
        case (.on, .on), (.off, .off), (.broken, .broken), (.off, .broken):
            return
        case (_, .on(_, let since, let deadline, let mode, _, _)):
            if mode == "claude" {
                post("ON while Claude runs")
            } else if let deadline = deadline, let since = since {
                let secs = Int(deadline.timeIntervalSince1970 - since.timeIntervalSince1970)
                post("ON for " + formatDuration(secs))
            } else {
                post("ON")
            }
        case (_, .off):
            var reason = ""
            if let text = try? String(contentsOfFile: offReasonPath, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { reason = " (\(trimmed))" }
                try? FileManager.default.removeItem(atPath: offReasonPath)
            }
            post("OFF" + reason)
        case (.on, .broken):
            return
        }
    }

    func post(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "supercaffeinate"
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                FileHandle.standardError.write(Data("notification post error: \(error)\n".utf8))
            }
        }
        log("notify " + body)
    }

    // Show the banner even while this app is frontmost (for example while the
    // Turn On For... alert is up).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    // One line per state change on stdout. Under the LaunchAgent that lands in
    // /tmp/supercaffeinate-menubar.out, which makes "what does the app think
    // the state is" answerable without clicking anything.
    func log(_ message: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        FileHandle.standardOutput.write(Data((fmt.string(from: Date()) + " " + message + "\n").utf8))
    }

    func describe(_ s: CaffState) -> String {
        switch s {
        case .off: return "state=off icon=cup.and.saucer"
        case .on(let pid, _, let deadline, let mode, _, let watcher):
            let timer = deadline.map { " deadline=\(Int($0.timeIntervalSince1970))" } ?? ""
            let m = mode.isEmpty ? "" : " mode=\(mode)"
            return "state=on pid=\(pid)\(timer)\(m) watcher=\(watcher ? "alive" : "dead") icon=cup.and.saucer.fill"
        case .broken(let pid): return "state=broken pid=\(pid) icon=exclamationmark.triangle"
        }
    }

    func applyIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        let describe: String
        switch state {
        case .on(_, _, _, _, _, let watcher):
            symbol = watcher ? "cup.and.saucer.fill" : "exclamationmark.triangle"
            describe = watcher ? "supercaffeinate is on" : "supercaffeinate is on but its watcher died"
        case .off:
            symbol = "cup.and.saucer"
            describe = "supercaffeinate is off"
        case .broken:
            symbol = "exclamationmark.triangle"
            describe = "supercaffeinate state file is stale"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: describe)
        image?.isTemplate = true
        button.image = image
        button.toolTip = describe
    }

    // Menu contents are rebuilt each time it opens, so nothing is ever stale
    // and the ioreg and check subprocesses only run on a real open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh(force: true)
        health = readHealth()
        menu.removeAllItems()

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let sessions = Int(health["claude_sessions"] ?? "") ?? 0

        switch state {
        case .on(_, let since, let deadline, let mode, let grace, let watcherAlive):
            if mode == "claude" {
                let act = health["claude_active"] == "yes" ? "active" : "idle"
                menu.addItem(disabled("Awake while Claude runs: \(sessions) session\(sessions == 1 ? "" : "s"), \(act)"))
                menu.addItem(disabled("Turns off after \(formatDuration(grace)) idle"))
            } else if let deadline = deadline {
                menu.addItem(disabled("Awake, " + remaining(until: deadline) + " (until " + fmt.string(from: deadline) + ")"))
            } else {
                // No timer: the infinity sign marks an indefinite session.
                let when = since.map { ", since " + fmt.string(from: $0) } ?? ""
                menu.addItem(disabled("Awake \u{221E}" + when))
            }
            if !lidClosed() {
                menu.addItem(disabled("Lid open: display held awake"))
            } else if externalDisplayOnline() {
                menu.addItem(disabled("Lid closed: showing on external display"))
            } else {
                menu.addItem(disabled("Lid closed: screen black, system running"))
            }
            if !watcherAlive {
                menu.addItem(disabled("\u{26A0} Watcher died: lid, timer and Claude checks are off"))
            }
        case .off:
            menu.addItem(disabled("Off"))
            if health["sleepdisabled"] == "1" {
                menu.addItem(disabled("\u{26A0} Sleep still disabled from an earlier session"))
            }
        case .broken(let pid):
            menu.addItem(disabled("Broken: state file says pid \(pid), not running"))
        }

        if health["sudoers"] == "missing" {
            menu.addItem(disabled("\u{26A0} Setup needed: lid close can still sleep the Mac"))
        }
        if health["screenblank"] == "missing" {
            menu.addItem(disabled("\u{26A0} screenblank missing: run install.sh"))
        }
        if let problem = lastProblem {
            menu.addItem(disabled("Last run: " + problem))
        }

        menu.addItem(.separator())

        var actions: [NSMenuItem] = []
        switch state {
        case .on(_, _, _, _, _, let watcherAlive):
            actions.append(NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: ""))
            if !watcherAlive {
                actions.append(NSMenuItem(title: "Repair (Off, then On Again)", action: #selector(repair), keyEquivalent: ""))
            }
        case .off:
            actions.append(NSMenuItem(title: "Turn On", action: #selector(turnOn), keyEquivalent: ""))
            let forItem = NSMenuItem(title: "Turn On For", action: nil, keyEquivalent: "")
            forItem.submenu = presetMenu()
            actions.append(forItem)
            let claudeTitle = sessions > 0
                ? "Turn On While Claude Runs (\(sessions) running)"
                : "Turn On While Claude Runs"
            actions.append(NSMenuItem(title: claudeTitle, action: #selector(turnOnClaude), keyEquivalent: ""))
            if health["sleepdisabled"] == "1" {
                actions.append(NSMenuItem(title: "Restore Normal Sleep", action: #selector(turnOff), keyEquivalent: ""))
            }
        case .broken:
            actions.append(NSMenuItem(title: "Clean Up (Turn Off)", action: #selector(turnOff), keyEquivalent: ""))
        }
        if health["sudoers"] == "missing" {
            actions.append(NSMenuItem(title: "Run Setup in Terminal...", action: #selector(runSetup), keyEquivalent: ""))
        }
        for action in actions {
            action.target = self
            action.isEnabled = !busy
            menu.addItem(action)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func presetMenu() -> NSMenu {
        let sub = NSMenu()
        for (title, arg) in presets {
            let mi = NSMenuItem(title: title, action: #selector(turnOnPreset(_:)), keyEquivalent: "")
            mi.representedObject = arg
            mi.target = self
            mi.isEnabled = !busy
            sub.addItem(mi)
        }
        // Evening starts overshoot an 8h timer; morning is the natural end.
        let morning = NSMenuItem(title: "Until 7:00 AM", action: #selector(turnOnUntilMorning), keyEquivalent: "")
        morning.target = self
        morning.isEnabled = !busy
        sub.addItem(morning)
        sub.addItem(.separator())
        let custom = NSMenuItem(title: "Custom...", action: #selector(turnOnFor), keyEquivalent: "")
        custom.target = self
        custom.isEnabled = !busy
        sub.addItem(custom)
        return sub
    }

    // "7h 42m left", minutes rounded up so it never reads 0m while still on.
    func remaining(until deadline: Date) -> String {
        let secs = Int(deadline.timeIntervalSinceNow)
        if secs <= 0 { return "turning off" }
        // Whole minutes here, even under a minute, so it never reads 0m.
        return formatDuration(max(secs, 60)) + " left"
    }

    func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc func turnOn() { run(["on"]) }
    @objc func turnOff() { run(["off"]) }
    @objc func turnOnClaude() { run(["on", "claude"]) }

    @objc func turnOnPreset(_ sender: NSMenuItem) {
        guard let arg = sender.representedObject as? String else { return }
        run(["on", arg])
    }

    @objc func turnOnUntilMorning() {
        run(["on", "\(minutesUntilNext(hour: 7, minute: 0))m"])
    }

    // Watcher died but caffeinate lives: turn off, then back on with the same
    // mode and whatever time was left, so the lid and timer handling return.
    @objc func repair() {
        guard case .on(_, _, let deadline, let mode, let grace, _) = state else { return }
        var onArgs = ["on"]
        if mode == "claude" {
            onArgs += ["claude", "\(grace)s"]
        } else if let deadline = deadline {
            let left = Int(deadline.timeIntervalSinceNow)
            if left < 60 {
                run(["off"])
                return
            }
            onArgs.append("\(left)s")
        }
        runSequence([["off"], onArgs])
    }

    // supercaffeinate-setup needs an interactive sudo prompt, so it runs in a
    // Terminal window rather than here.
    @objc func runSetup() {
        let cmd = "tell application \"Terminal\"\nactivate\ndo script \"'" + setupPath + "'\"\nend tell"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = capture("/usr/bin/osascript", ["-e", cmd])
            if r.status != 0 {
                DispatchQueue.main.async {
                    self.lastProblem = "could not open Terminal: " + r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.post(self.lastProblem!)
                }
            }
        }
    }

    // Asks for a number of hours. Empty or 0 means indefinite; anything else
    // must be a number greater than 0 and at most 1000, or the alert comes
    // back with an error line and nothing runs.
    @objc func turnOnFor() {
        let prompt = "Enter hours, or leave blank for indefinite. It turns itself off when the time is up."
        // NSAlert sizes the accessory view from its frame and does not run
        // autolayout inside it, so every subview gets an explicit frame.
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))

        let label = NSTextField(labelWithString: "Hours")
        label.font = NSFont.systemFont(ofSize: 13)
        label.frame = NSRect(x: 0, y: 3, width: 50, height: 18)
        row.addSubview(label)

        let field = NSTextField(frame: NSRect(x: 56, y: 0, width: 200, height: 24))
        field.font = NSFont.systemFont(ofSize: 13)
        field.placeholderString = "e.g. 8"
        field.isEditable = true
        field.isSelectable = true
        row.addSubview(field)

        var error: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "Turn On For..."
            alert.informativeText = error.map { prompt + "\n" + $0 } ?? prompt
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = row
            alert.layout()
            alert.window.makeFirstResponder(field)

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                run(["on"])
                return
            }
            guard let hours = Double(text), hours.isFinite, hours >= 0, hours <= 1000 else {
                error = "\"\(text)\" is not a valid number of hours (0 to 1000)."
                continue
            }
            if hours == 0 {
                run(["on"])
                return
            }
            let minutes = Int((hours * 60).rounded())
            if minutes < 1 {
                error = "That is under a minute. Enter at least 0.02 hours."
                continue
            }
            run(["on", "\(minutes)m"])
            return
        }
    }

    func run(_ args: [String]) { runSequence([args]) }

    // The script can take a moment (sudo pmset, pkill sweeps), so it never
    // runs on the main thread. A non-zero exit (lock held, bad argument) or a
    // "warning:" line on stderr (sudo -n pmset failed) becomes a notification
    // and a menu line instead of vanishing. Several commands run back to back
    // for repair; the sequence stops at the first failure.
    func runSequence(_ commands: [[String]]) {
        if busy { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var problem: String?
            for args in commands {
                let r = capture(scriptPath, args)
                let errLines = r.err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                if r.status != 0 {
                    let why = errLines.first ?? "exit \(r.status)"
                    problem = "\(args.joined(separator: " ")) failed: \(why)"
                    break
                }
                if let warn = errLines.first(where: { $0.hasPrefix("warning:") }) {
                    problem = String(warn.dropFirst("warning:".count)).trimmingCharacters(in: .whitespaces)
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.lastProblem = problem
                if let p = problem { self.post(p) }
                self.refresh(force: true)
            }
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()

// --dump-menu builds the menu exactly as a click would and prints it, so the
// menu can be checked without clicking anything. Submenu items are indented.
if CommandLine.arguments.contains("--dump-menu") {
    controller.menuNeedsUpdate(controller.menu)
    func dump(_ m: NSMenu, indent: String) {
        for mi in m.items {
            if mi.isSeparatorItem {
                print(indent + "---")
                continue
            }
            print(indent + mi.title + (mi.isEnabled || mi.submenu != nil ? "" : " (disabled)"))
            if let sub = mi.submenu { dump(sub, indent: indent + "    ") }
        }
    }
    dump(controller.menu, indent: "")
    exit(0)
}

controller.startNotifications()
controller.startupHealthCheck()
app.run()
