import SwiftUI
import IntentCore

private let bg = Color(red: 0.07, green: 0.07, blue: 0.08)
private let card = Color(white: 0.13)
private let accent = Color(red: 0.36, green: 0.62, blue: 1.0)

// MARK: - Full-screen lock view

struct LockView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer(minLength: 16)
                Text("What are you here for?")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.white)
                if let st = model.status {
                    Text("Today: \(st.todayMinutes) min · \(st.todaySessions) session\(st.todaySessions == 1 ? "" : "s")")
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.55))
                }

                if !model.daemonReachable {
                    Text("Waiting for the Intent Mode daemon…")
                        .foregroundColor(.orange)
                }
                if let b = model.status?.bedtimeNotice {
                    Text("🌙 \(b)").font(.system(size: 15, weight: .medium)).foregroundColor(Color(red: 0.7, green: 0.75, blue: 1))
                }
                if let n = model.status?.notice {
                    Text(n).foregroundColor(.orange).multilineTextAlignment(.center)
                }

                if let st = model.status {
                    if st.pendingModeId != nil {
                        PendingStartView(model: model, status: st)
                    } else if st.escapeStage == "challenge" {
                        ChallengeView(model: model, status: st)
                    } else if st.escapeStage == "waiting" {
                        EscapeWaitView(model: model, status: st)
                    } else if let id = model.selectedMode, let mode = st.modes.first(where: { $0.id == id }), mode.escapeHatch {
                        EscapeReasonEntry(model: model, mode: mode, minWords: st.escapeReasonMinWords)
                    } else if let id = model.selectedMode, let mode = st.modes.first(where: { $0.id == id }) {
                        IntentEntry(model: model, mode: mode, minWords: mode.intentMinWords)
                    } else {
                        ModeGrid(model: model, modes: st.modes)
                        NotesBox(model: model, notes: st.notes)
                    }
                }

                if let e = model.errorText {
                    Text(e).foregroundColor(Color(red: 1, green: 0.45, blue: 0.45)).multilineTextAlignment(.center)
                }
                if let i = model.infoText {
                    Text(i).foregroundColor(.green).multilineTextAlignment(.center)
                }
                Spacer()
                Footer(model: model)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 40).padding(.vertical, 28)
            if model.showWeek {
                Color.black.opacity(0.6).ignoresSafeArea()
                WeekView(model: model)
            }
        }
    }
}

struct ModeGrid: View {
    @ObservedObject var model: AppModel
    let modes: [ModeStatus]

    /// Only modes you can start right now; corner modes (Maintenance) live in the footer.
    private var visible: [ModeStatus] { modes.filter { $0.available && !$0.corner } }

    var body: some View {
        VStack(spacing: 8) {
            if visible.isEmpty {
                Text("Nothing is available right now.").font(.system(size: 15)).foregroundColor(.white.opacity(0.6)).padding(.vertical, 20)
            }
            ForEach(visible) { m in
                Button {
                    model.errorText = nil
                    model.infoText = nil
                    model.intentText = ""
                    model.selectedMode = m.id
                } label: {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(m.name).font(.system(size: 20, weight: .medium))
                                if m.openWeb {
                                    Text("OPEN WEB").font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.35)))
                                }
                            }
                            if let d = m.description { Text(d).font(.system(size: 13)).opacity(0.65) }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(m.minutes) min").font(.system(size: 15, weight: .medium))
                            Text(m.available ? usage(m) : (m.unavailableReason ?? "Unavailable"))
                                .font(.system(size: 12)).opacity(0.65)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(card))
                    .opacity(m.available ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!m.available)
            }
        }
    }

    private func usage(_ m: ModeStatus) -> String {
        var parts: [String] = []
        if let l = m.dailyLimit { parts.append("\(max(0, l - m.usedToday)) of \(l) left today") }
        if let w = m.weeklyLimit { parts.append("\(max(0, w - m.usedThisWeek)) of \(w) this week") }
        return parts.isEmpty ? "no limit" : parts.joined(separator: " · ")
    }
}

/// "Note for later": jot a thought down instead of opening a session for it.
struct NotesBox: View {
    @ObservedObject var model: AppModel
    let notes: [NoteItem]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact {
                HStack {
                    TextField("Note for later — e.g. \"look up car rentals in Lisbon\"", text: $model.noteText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.addNote() }
                    Button("Save") { model.addNote() }.disabled(model.noteText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(notes.prefix(compact ? 5 : 30)) { n in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").opacity(0.6)
                    Text(n.text).font(.system(size: compact ? 11 : 13)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { model.deleteNote(n.id) } label: { Image(systemName: "xmark.circle.fill").opacity(0.5) }
                        .buttonStyle(.plain)
                        .help("Done — delete this note")
                }
                .foregroundColor(.white)
            }
        }
        .padding(compact ? 0 : 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(compact ? Color.clear : card))
    }
}

/// The pause between pressing Start and an open-web session opening.
struct PendingStartView: View {
    @ObservedObject var model: AppModel
    let status: DaemonStatus

    var body: some View {
        VStack(spacing: 14) {
            Text("\(status.pendingModeName ?? "Session") opens in \(status.pendingReadyIn ?? 0) s")
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
            if let intent = status.pendingIntent {
                Text("“\(intent)”")
                    .font(.system(size: 15)).foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center).lineLimit(4)
            }
            Text("Still the right thing to do? You can cancel without using up a session.")
                .font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
            Button("Cancel") { model.cancelPendingStart() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(card))
    }
}

struct IntentEntry: View {
    @ObservedObject var model: AppModel
    let mode: ModeStatus
    let minWords: Int

    var body: some View {
        let words = TextUtil.wordCount(model.intentText)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(mode.name) · \(mode.minutes) minutes")
                .font(.system(size: 22, weight: .medium)).foregroundColor(.white)
            Text(mode.startDelaySeconds > 0
                 ? "Type exactly what you're going to look for — at least \(minWords) words, then press Return. After that there's a \(mode.startDelaySeconds)-second pause. Pasting is turned off."
                 : "Type exactly what you're going to do — at least \(minWords) words, then press Return. Pasting is turned off.")
                .font(.system(size: 14)).foregroundColor(.white.opacity(0.7))
            NoPasteTextEditor(text: $model.intentText, onSubmit: {
                if TextUtil.wordCount(model.intentText) >= minWords && !model.busy { model.startSession() }
                else { NSSound.beep() }
            })
                .frame(height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("\(words) / \(minWords) words")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundColor(words >= minWords ? .green : .white.opacity(0.6))
                Spacer()
                Button("Back") {
                    model.selectedMode = nil
                    model.errorText = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Start \(mode.minutes)-minute session") { model.startSession() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(words < minWords || model.busy)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(card))
    }
}

/// Shown on every screen during a test install.
struct TestBanner: View {
    @ObservedObject var model: AppModel
    var compact = false

    var body: some View {
        if let ends = model.status?.testEndsAt {
            let left = Int(Date(timeIntervalSince1970: ends).timeIntervalSince(model.now))
            HStack(spacing: 10) {
                Text(compact ? "TEST · off in \(formatRemaining(left))"
                             : "TEST MODE — switches itself off in \(formatRemaining(left)), or when you restart the Mac.")
                    .font(.system(size: compact ? 11 : 13, weight: .medium))
                Spacer(minLength: 4)
                Button(compact ? "Stop test" : "Stop test now") { model.stopTest() }
                    .controlSize(compact ? .small : .regular)
                    .disabled(model.busy)
            }
            .foregroundColor(.black)
            .padding(.horizontal, 12).padding(.vertical, compact ? 4 : 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow))
        }
    }
}

struct Footer: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            TestBanner(model: model)
            if model.status?.lockdownActive == true || !(model.status?.pending.isEmpty ?? true) {
                LockdownBar(model: model)
            }
            if model.showEmergency {
                VStack(spacing: 8) {
                    Text("Emergency off (dev build): removes all enforcement until you turn it back on with\nsudo intentmode emergency-off --undo")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)
                    HStack {
                        TextField("Admin name", text: $model.adminUser).frame(width: 160)
                        SecureField("Admin password", text: $model.adminPassword).frame(width: 200)
                        Button("Turn everything off") { model.emergencyOff() }.disabled(model.adminPassword.isEmpty || model.busy)
                        Button("Cancel") { model.showEmergency = false; model.adminPassword = "" }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.18)))
            }
            HStack(spacing: 16) {
                if model.wifiActive {
                    Text("Menu bar unlocked for Wi-Fi — \(formatRemaining(Int((model.wifiUntil ?? Date()).timeIntervalSince(model.now))))")
                        .foregroundColor(accent)
                    Button("Done") { model.wifiUntil = nil }
                } else {
                    Button("Join Wi-Fi…") { model.wifiUntil = Date().addingTimeInterval(120) }
                        .help("Shows the menu bar for 2 minutes so you can pick a network from the Wi-Fi menu.")
                }
                Button("This week") { model.openWeek() }
                Spacer()
                ForEach(model.status?.modes.filter { $0.corner && $0.available } ?? []) { m in
                    let update = model.status?.macUpdateAvailable == true && m.id == "maintenance"
                    Button {
                        model.errorText = nil
                        model.intentText = ""
                        model.selectedMode = m.id
                    } label: {
                        Text(update ? "\(m.name) · update available" : m.name)
                            .font(.system(size: 11, weight: update ? .semibold : .regular))
                            .foregroundColor(update ? .white : .white.opacity(0.6))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(update ? Color.red : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(update ? (model.status?.macUpdateName ?? "A macOS update is available") : (m.description ?? ""))
                }
                if model.status?.chromePolicyMissing == true {
                    ChromeWarning(model: model)
                }
                if model.status?.devBuild == true && !model.showEmergency && model.status?.testEndsAt == nil
                    && model.status?.lockdownActive != true {
                    Button("Emergency off…") { model.showEmergency = true }
                        .foregroundColor(.red.opacity(0.8))
                }
                Text("Intent Mode \(model.status?.version ?? "")\(model.status?.devBuild == true ? " · dev" : "")")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
            }
        }
    }
}

/// Lock-down status, the one-time turn-off, and changes waiting for their delay.
struct LockdownBar: View {
    @ObservedObject var model: AppModel
    @State private var confirmTurnOff = false
    @State private var showKeep = false
    @State private var keepText = ""

    private func hm(_ s: Int) -> String { "\(s / 3600) h \((s / 60) % 60) min" }

    var body: some View {
        let st = model.status
        VStack(alignment: .leading, spacing: 6) {
            if st?.lockdownActive == true {
                HStack(spacing: 10) {
                    Text("🔒 Lock-down").font(.system(size: 12, weight: .semibold))
                    if let d = st?.lockdownDisableIn {
                        Text("turns off in \(hm(d))").font(.system(size: 12))
                        Button("Keep it on") { model.send(IPCRequest(cmd: "lockdown_disable_cancel")) { _ in } }.controlSize(.small)
                    } else if st?.lockdownEscapeAvailable == true {
                        Spacer()
                        if confirmTurnOff {
                            Text("Uses your one-time turn-off. Sure?").font(.system(size: 11))
                            Button("Yes, turn off in \(Int(st?.lockdownDisableHours ?? 24)) h") {
                                confirmTurnOff = false
                                model.send(IPCRequest(cmd: "lockdown_disable_request")) { r in if !r.ok { model.errorText = r.error } }
                            }.controlSize(.small)
                            Button("No") { confirmTurnOff = false }.controlSize(.small)
                        } else {
                            Button("Turn off (one-time, \(Int(st?.lockdownDisableHours ?? 24)) h)…") { confirmTurnOff = true }.controlSize(.small)
                            Button("Keep lock-down…") { showKeep.toggle() }.controlSize(.small)
                        }
                    }
                }
                if showKeep && st?.lockdownEscapeAvailable == true {
                    HStack {
                        TextField("Type: I will keep using Intent Mode as intended", text: $keepText)
                            .textFieldStyle(.roundedBorder)
                        Button("Confirm — remove the turn-off for good") {
                            model.send(IPCRequest(cmd: "lockdown_keep", reason: keepText)) { r in
                                if r.ok { showKeep = false; keepText = ""; model.infoText = r.message } else { model.errorText = r.error }
                            }
                        }
                        .disabled(keepText != "I will keep using Intent Mode as intended")
                    }
                }
            }
            ForEach(st?.pending ?? []) { p in
                HStack {
                    Text("⏳ \(p.description) — applies in \(hm(p.dueIn))").font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Button("Cancel") { model.send(IPCRequest(cmd: "pending_cancel", noteId: p.id)) { _ in } }.controlSize(.mini)
                }
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
    }
}

/// Small corner button: the Chrome policy profile isn't installed.
struct ChromeWarning: View {
    @ObservedObject var model: AppModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Text("⚠︎ Chrome").font(.system(size: 11)).foregroundColor(.orange)
        }
        .buttonStyle(.plain)
        .help("The Chrome filter profile isn't installed")
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chrome filter profile not installed").font(.headline)
                Text("Without it Chrome can use its own secure DNS, Incognito and any extension, and its adult-site filter is off.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("To install: start **Maintenance**, then click **Install Chrome profile** in the timer window and approve it in System Settings.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(width: 320)
        }
    }
}

// MARK: - Open session (escape hatch)

struct EscapeReasonEntry: View {
    @ObservedObject var model: AppModel
    let mode: ModeStatus
    let minWords: Int

    var body: some View {
        let words = TextUtil.wordCount(model.escapeReasonText)
        VStack(alignment: .leading, spacing: 10) {
            Text("\(mode.name) · step 1 of 3").font(.system(size: 22, weight: .medium)).foregroundColor(.white)
            Text("Why do you need open access, and why can't another mode do it? At least \(minWords) words, then press Return. Next: retype a random text exactly, then a 10-minute wait.")
                .font(.system(size: 13)).foregroundColor(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            NoPasteTextEditor(text: $model.escapeReasonText, onSubmit: {
                if words >= minWords && !model.busy { model.requestEscape(modeId: mode.id) } else { NSSound.beep() }
            })
            .frame(height: 130).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("\(words) / \(minWords) words").font(.system(size: 13).monospacedDigit())
                    .foregroundColor(words >= minWords ? .green : .white.opacity(0.6))
                Spacer()
                Button("Back") { model.selectedMode = nil; model.errorText = nil }.keyboardShortcut(.cancelAction)
                Button("Continue") { model.requestEscape(modeId: mode.id) }.disabled(words < minWords || model.busy)
            }
        }
        .padding(20).background(RoundedRectangle(cornerRadius: 14).fill(card))
    }
}

struct ChallengeView: View {
    @ObservedObject var model: AppModel
    let status: DaemonStatus

    var body: some View {
        let target = status.escapeChallenge ?? ""
        let typed = model.challengeInput
        VStack(alignment: .leading, spacing: 10) {
            Text("\(status.escapeModeName ?? "Open session") · step 2 of 3").font(.system(size: 22, weight: .medium)).foregroundColor(.white)
            Text("Type this exactly. Pasting is off, and one typo starts you over.")
                .font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
            // Already-typed part in green, the rest in white.
            (Text(String(target.prefix(typed.count))).foregroundColor(.green)
             + Text(String(target.dropFirst(typed.count))).foregroundColor(.white))
                .font(.system(size: 17, design: .monospaced))
                .textSelection(.disabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
            NoPasteTextEditor(text: $model.challengeInput, fontSize: 17, monospaced: true)
                .frame(height: 90).clipShape(RoundedRectangle(cornerRadius: 10))
                .onChange(of: model.challengeInput) { _, new in model.challengeChanged(new) }
            HStack {
                Text("\(typed.count) / \(target.count)").font(.system(size: 13).monospacedDigit()).foregroundColor(.white.opacity(0.6))
                if let m = model.challengeMessage { Text(m).font(.system(size: 13)).foregroundColor(.orange) }
                Spacer()
                Button("Cancel") { model.cancelEscape() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).background(RoundedRectangle(cornerRadius: 14).fill(card))
    }
}

struct EscapeWaitView: View {
    @ObservedObject var model: AppModel
    let status: DaemonStatus

    var body: some View {
        VStack(spacing: 14) {
            Text("\(status.escapeModeName ?? "Open session") · step 3 of 3").font(.system(size: 15)).foregroundColor(.white.opacity(0.6))
            Text("Opens in \(formatRemaining(status.escapeReadyIn ?? 0))")
                .font(.system(size: 30, weight: .semibold).monospacedDigit()).foregroundColor(.white)
            Text("Your reason:").font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.6))
            Text("“\(status.escapeReason ?? "")”").font(.system(size: 16)).foregroundColor(.white)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text("Still worth it? Cancelling doesn't use up one of your open sessions.")
                .font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
            Button("Cancel") { model.cancelEscape() }.keyboardShortcut(.cancelAction)
        }
        .padding(24).frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 14).fill(card))
    }
}

// MARK: - Weekly overview

struct WeekView: View {
    @ObservedObject var model: AppModel

    private func hm(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("This week").font(.system(size: 26, weight: .semibold))
                Spacer()
                Button("Close") { model.showWeek = false }.keyboardShortcut(.cancelAction)
            }
            if let s = model.weekStats {
                HStack(spacing: 28) {
                    stat(hm(s.totalMinutes), "total")
                    stat("\(s.sessionCount)", "sessions")
                    stat("\(s.openSessionsUsed)\(s.openSessionsLimit.map { " / \($0)" } ?? "")", "open sessions")
                    stat(hm(s.lastWeekMinutes), "last week")
                }
                // Minutes per day, Monday to Sunday.
                let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                let peak = max(1, s.perDayMinutes.max() ?? 1)
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(0..<7, id: \.self) { i in
                        VStack(spacing: 4) {
                            Text("\(s.perDayMinutes[i])").font(.system(size: 10).monospacedDigit()).opacity(0.6)
                            RoundedRectangle(cornerRadius: 3).fill(accent)
                                .frame(width: 34, height: max(2, CGFloat(s.perDayMinutes[i]) / CGFloat(peak) * 70))
                            Text(days[i]).font(.system(size: 11)).opacity(0.7)
                        }
                    }
                }
                Divider()
                Text("Per mode").font(.system(size: 14, weight: .semibold))
                ForEach(s.perMode) { m in
                    HStack {
                        Text(m.name)
                        Spacer()
                        Text("\(m.sessions)× · \(hm(m.minutes))").monospacedDigit().opacity(0.8)
                    }.font(.system(size: 13))
                }
                if !s.longest.isEmpty {
                    Text("Longest sessions").font(.system(size: 14, weight: .semibold))
                    ForEach(s.longest) { x in
                        Text("\(x.minutes) min · \(x.modeName) — \(x.intent)").font(.system(size: 12)).lineLimit(1).opacity(0.85)
                    }
                }
                Text("All intents (\(s.sessions.count))\(s.extensions > 0 ? " · \(s.extensions) extended" : "")\(s.openRequestsCancelled > 0 ? " · \(s.openRequestsCancelled) open-session requests cancelled" : "")")
                    .font(.system(size: 14, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(s.sessions) { x in
                            Text("\(Self.day(x.started)) · \(x.modeName) · \(x.minutes) min — \(x.intent)")
                                .font(.system(size: 12)).opacity(0.85).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: 160)
            } else {
                Text("Loading…").opacity(0.6)
            }
        }
        .foregroundColor(.white)
        .padding(24)
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.11)))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 11)).opacity(0.6)
        }
    }

    private static func day(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: Date(timeIntervalSince1970: t))
    }
}

// MARK: - Session timer panel

struct SessionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let st = model.status
        let remaining = Int(((st?.endsAt).map { Date(timeIntervalSince1970: $0) } ?? model.now).timeIntervalSince(model.now).rounded(.up))
        let warning = st?.warning == true
        VStack(alignment: .leading, spacing: 8) {
            TestBanner(model: model, compact: true)
            HStack {
                Text(st?.modeName ?? "Session").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(formatRemaining(remaining)).font(.system(size: 22, weight: .semibold).monospacedDigit())
            }
            if st?.state == "learn" {
                Text("LEARN MODE — everything is reachable. Stop with:\nsudo intentmode learn stop").font(.system(size: 11))
            }
            if let intent = st?.intent {
                Text(intent).font(.system(size: 11)).opacity(0.75).lineLimit(2)
            }
            if warning {
                Text("Less than \(max(1, remaining / 60 + (remaining % 60 > 0 ? 1 : 0))) min left — wrap up.").font(.system(size: 12, weight: .medium))
            }
            if let idle = st?.idleSeconds, let limit = st?.idleLimitSeconds, limit - idle <= 60 {
                Text("No activity — the session ends in \(max(0, limit - idle)) s. Move the mouse to keep it.")
                    .font(.system(size: 11, weight: .medium))
            }
            if st?.state == "session", st?.modes.first(where: { $0.id == st?.modeId })?.openWeb == true,
               let notes = st?.notes, !notes.isEmpty {
                Text("Your notes:").font(.system(size: 11, weight: .semibold)).opacity(0.8)
                NotesBox(model: model, notes: notes, compact: true)
            }
            if st?.state == "session", st?.chromePolicyMissing == true,
               st?.modes.first(where: { $0.id == st?.modeId })?.id == "maintenance" {
                Button("Install Chrome profile") { model.openChromeProfile() }.controlSize(.small)
            }
            if st?.state == "session" { ExtensionControls(model: model) }
            if let e = model.errorText {
                Text(e).font(.system(size: 11)).foregroundColor(Color(red: 1, green: 0.6, blue: 0.6))
            }
            if st?.state == "session" {
                HStack {
                    Spacer()
                    if model.confirmEnd {
                        Button("Cancel") { model.confirmEnd = false }
                        Button("End now") { model.endSession() }.keyboardShortcut(.defaultAction)
                    } else {
                        Button("End session") { model.confirmEnd = true }
                    }
                }
                .controlSize(.small)
            }
        }
        .foregroundColor(.white)
        .padding(12)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(warning ? Color(red: 0.75, green: 0.38, blue: 0.05) : Color(white: 0.12))
                .opacity(0.96)
        )
    }
}

struct ExtensionControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let st = model.status
        switch st?.extensionState ?? "" {
        case "available":
            Button("+\(st?.extensionMinutes ?? 10) min…") { model.requestExtension() }.controlSize(.small)
        case "waiting":
            Text("Extension: wait \(st?.extensionReadyIn ?? 0) s, then give a reason.").font(.system(size: 11)).opacity(0.8)
        case "ready":
            VStack(alignment: .leading, spacing: 6) {
                Text("Why do you need \(st?.extensionMinutes ?? 10) more minutes? (\(st?.extensionMinReasonWords ?? 5)+ words)")
                    .font(.system(size: 11))
                NoPasteTextEditor(text: $model.extensionReason, fontSize: 12, onSubmit: {
                    if TextUtil.wordCount(model.extensionReason) >= (st?.extensionMinReasonWords ?? 5) && !model.busy { model.confirmExtension() }
                    else { NSSound.beep() }
                })
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button("Add \(st?.extensionMinutes ?? 10) min") { model.confirmExtension() }
                        .disabled(TextUtil.wordCount(model.extensionReason) < (st?.extensionMinReasonWords ?? 5) || model.busy)
                        .controlSize(.small)
                }
            }
        case "used":
            Text("Extended once already.").font(.system(size: 11)).opacity(0.6)
        default:
            EmptyView()
        }
    }
}
