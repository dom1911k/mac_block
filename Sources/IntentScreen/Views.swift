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
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                Text("What are you here for?")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundColor(.white)

                if !model.daemonReachable {
                    Text("Waiting for the Intent Mode daemon…")
                        .foregroundColor(.orange)
                }
                if let n = model.status?.notice {
                    Text(n).foregroundColor(.orange).multilineTextAlignment(.center)
                }

                if let st = model.status {
                    if st.pendingModeId != nil {
                        PendingStartView(model: model, status: st)
                    } else if let id = model.selectedMode, let mode = st.modes.first(where: { $0.id == id }) {
                        IntentEntry(model: model, mode: mode, minWords: mode.intentMinWords)
                    } else {
                        ModeGrid(model: model, modes: st.modes)
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
            .padding(40)
        }
    }
}

struct ModeGrid: View {
    @ObservedObject var model: AppModel
    let modes: [ModeStatus]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(modes) { m in
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
                    .padding(.horizontal, 20).padding(.vertical, 14)
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
                 ? "Type exactly what you're going to look for — at least \(minWords) words. After Start there's a \(mode.startDelaySeconds)-second pause. Pasting is turned off."
                 : "Type exactly what you're going to do — at least \(minWords) words. Pasting is turned off.")
                .font(.system(size: 14)).foregroundColor(.white.opacity(0.7))
            NoPasteTextEditor(text: $model.intentText)
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
                Spacer()
                if model.status?.devBuild == true && !model.showEmergency && model.status?.testEndsAt == nil {
                    Button("Emergency off…") { model.showEmergency = true }
                        .foregroundColor(.red.opacity(0.8))
                }
                Text("Intent Mode \(model.status?.version ?? "")\(model.status?.devBuild == true ? " · dev" : "")")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
            }
        }
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
                NoPasteTextEditor(text: $model.extensionReason, fontSize: 12)
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
