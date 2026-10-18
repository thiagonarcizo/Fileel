import AppKit
import SwiftUI

// onboarding is optional, replayable from the menu bar, and never adds a dock presence
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private init() {
        let rect = NSRect(x: 0, y: 0, width: 920, height: 610)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Fileel"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        guard let window else { return }
        let host = NSHostingView(rootView: OnboardingView(finish: { [weak self] in self?.close() }))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 920, height: 610)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        window?.contentView = nil
    }
}

private struct OnboardingView: View {
    var finish: () -> Void
    @State private var step = 0
    @State private var mode: MenuMode = .convert
    @State private var appeared = false
    @State private var feedbackHovered: String?
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage("soundsEnabled") private var sounds = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        ["A small gesture.\nA better file.", "Three shortcuts.\nOne fluid motion.", "A little detail.\nYour kind of Mac."][step]
    }
    private var message: String {
        ["Convert, edit, and send files on their way.\nFileel lives quietly in your menu bar.",
         "Drag a file, hold a shortcut, and drop it\non the operation you need.",
         "Feel each selection with your trackpad.\nKeep the sound as quiet as you like."][step]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                FoldMark().frame(width: 19, height: 22)
                Text("Fileel").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(step + 1) OF 3").font(.system(size: 10, weight: .medium)).tracking(1.4).foregroundStyle(.secondary)
            }.padding(.top, 48)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 23) {
                    Text(title).font(.system(size: 43, weight: .medium, design: .serif)).tracking(-1.3).lineSpacing(-2)
                        .fixedSize(horizontal: false, vertical: true).id(title)
                        .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
                    Text(message).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    if step == 1 { shortcutButtons }
                    if step == 2 { feedbackControls }
                    if step == 0 {
                        Label("Local to your Mac", systemImage: "lock.shield")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }.frame(width: 405, alignment: .leading)
                Spacer(minLength: 0)
                OnboardingArtwork(step: step, mode: mode, appeared: appeared)
                    .frame(width: 350, height: 360).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 12)
            Divider()
            HStack(spacing: 16) {
                if step > 0 { Button("Back") { move(-1) }.buttonStyle(.plain).foregroundStyle(.secondary) }
                else { Button("Skip Introduction", action: finish).buttonStyle(.plain).foregroundStyle(.secondary) }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Capsule().fill(index == step ? Color.accentColor : Color.primary.opacity(0.12)).frame(width: 6, height: 6)
                    }
                }.accessibilityLabel("Step \(step + 1) of 3")
                Spacer()
                Button(step == 2 ? "Start Using Fileel" : "Continue") {
                    if step == 2 { finish() } else { move(1) }
                }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: [])
            }.padding(.vertical, 25)
        }
        .padding(.horizontal, 48)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { appeared = true } }
    }

    private var shortcutButtons: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                ForEach(MenuMode.allCases) { item in
                    Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { mode = item } } label: {
                        VStack(spacing: 7) {
                            Text(item == .convert ? "⇧" : item == .tools ? "⌘" : "⌃").font(.system(size: 24))
                            Text(item.rawValue).font(.system(size: 11, weight: .medium))
                        }.frame(width: 83, height: 66)
                            .background(mode == item ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(mode == item ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("\(item.defaultKey), \(item.rawValue)")
                }
            }
            Text("Release the key to keep the menu open.\nDrop in the center to cancel.").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            Button("Try with a File…") {
                AppModel.shared.chooseFiles()
                if !AppModel.shared.files.isEmpty { WorkspaceWindowController.shared.show() }
            }.controlSize(.small)
        }
    }

    private var feedbackControls: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle("Trackpad haptics", isOn: $haptics)
            Toggle("Selection sounds", isOn: $sounds)
            VStack(alignment: .leading, spacing: 9) {
                Text("Move across these options to try it").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(["JPG", "PNG", "PDF"], id: \.self) { format in
                        Button { SelectionFeedback.play() } label: {
                            Text(format).font(.system(size: 12, weight: .medium))
                                .frame(width: 68, height: 38)
                                .background(feedbackHovered == format ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                                .foregroundStyle(feedbackHovered == format ? Color.accentColor : .primary)
                        }.buttonStyle(.plain)
                            .onHover { entered in
                                if entered { feedbackHovered = format; SelectionFeedback.play() }
                                else if feedbackHovered == format { feedbackHovered = nil }
                            }
                            .accessibilityLabel("Test selection feedback, \(format)")
                    }
                }
            }
            Text("No microphone, camera, or screen recording access is needed for drag shortcuts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: 300)
    }
    private func move(_ direction: Int) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { step = min(2, max(0, step + direction)) }
    }
}

// reuse the real radial renderer so the introduction shows the same shapes and labels as the app
private struct OnboardingArtwork: View {
    let step: Int
    let mode: MenuMode
    let appeared: Bool
    @StateObject private var wheel = WheelPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if step == 2 {
                RoundedRectangle(cornerRadius: 26).fill(Color.primary.opacity(0.04)).frame(width: 270, height: 195)
                VStack(spacing: 24) {
                    FoldMark().frame(width: 60, height: 68)
                    HStack(spacing: 8) {
                        Circle().fill(Color.primary.opacity(0.14)).frame(width: 9, height: 9)
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.10)).frame(width: 90, height: 6)
                        Spacer()
                        FoldMark().frame(width: 14, height: 16).padding(8).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    }.frame(width: 220)
                }
            } else {
                WheelAppearance(state: wheel).scaleEffect(0.69).frame(width: 337, height: 337)
                if step == 0 {
                    Image(systemName: "doc.fill").font(.system(size: 42)).foregroundStyle(.tint)
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                        .offset(x: appeared || reduceMotion ? 0 : -65, y: appeared || reduceMotion ? 0 : 65)
                }
            }
        }
        .task(id: mode) {
            wheel.expanded = true
            wheel.showHubLabels = step != 0
            wheel.mode = mode
            wheel.filename = "Your file"
            wheel.operations = Catalog.operations(for: [URL(fileURLWithPath: "/Example.png")], mode: mode)
            wheel.highlighted = step == 0 ? nil : 0
        }
        .onChange(of: step) { _, step in wheel.highlighted = step == 0 ? nil : 0; wheel.showHubLabels = step != 0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: step)
    }
}
