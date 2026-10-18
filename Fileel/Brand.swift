import SwiftUI

// the compact mark shares the folded ribbon geometry with the app icon
struct FoldMark: View {
    var body: some View {
        ZStack {
            RibbonFace().fill(.tint)
            RibbonFace(returns: true).fill(.tint)
            RibbonFace(returns: true).fill(.black.opacity(0.22))
        }.accessibilityHidden(true)
    }
}

// normalize the icon's drawing space so small interface marks keep a generous size
private struct RibbonFace: Shape {
    var returns = false
    func path(in rect: CGRect) -> Path {
        let source = returns ? FileelIcon.returns : FileelIcon.silhouette
        let transform = CGAffineTransform(a: rect.width / 456, b: 0, c: 0, d: -rect.height / 518,
                                          tx: -324 * rect.width / 456, ty: 770 * rect.height / 518)
        return Path(source.cgPath).applying(transform)
    }
}

// editorial typography is limited to the welcome area while working controls stay native
struct WelcomeView: View {
    var chooseFiles: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    var receiveFiles: ([URL]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 8) {
                        FoldMark().frame(width: 23, height: 28)
                        Text("Fileel").font(.system(size: 17, weight: .semibold))
                    }
                    Text("Every file.\nA better fit.")
                        .font(.system(size: 46, weight: .medium, design: .serif)).tracking(-1.3).lineSpacing(-2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Convert, edit, and organize files.\nRight here on your Mac.")
                        .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
                    Button("Choose Files…", action: chooseFiles)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                Spacer(minLength: 0)
                PaperComposition().frame(width: 210, height: 245).padding(.top, 32).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 30)
            Spacer(minLength: 28)
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Or take a shortcut.").font(.system(size: 18, weight: .medium, design: .serif))
                    Spacer()
                    Text("DRAG · PRESS · DROP").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                }
                ForEach(Array(MenuMode.allCases.enumerated()), id: \.element) { index, mode in
                    HStack(spacing: 16) {
                        Text(index == 0 ? "⇧" : index == 1 ? "⌘" : "⌃")
                            .font(.system(size: 22, weight: .regular))
                            .frame(width: 42, height: 38)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
                        Text(mode.rawValue).font(.system(size: 13, weight: .medium)).frame(width: 65, alignment: .leading)
                        Text(index == 0 ? "Choose a new format" : index == 1 ? "Give a file a finishing touch" : "Send it on its way")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, 24)
            .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 1) }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 40)
        .background(targeted ? Color.accentColor.opacity(0.07) : Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in receiveFiles(urls); return true } isTargeted: { targeted = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: targeted)
    }
}

// the paper stack echoes the mark using simple shapes rather than decorative stock artwork
private struct PaperComposition: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10))
                .frame(width: 145, height: 182).rotationEffect(.degrees(-13)).offset(x: -18, y: 1)
            RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.20))
                .frame(width: 145, height: 182).rotationEffect(.degrees(7)).offset(x: 13, y: -6)
            VStack(alignment: .leading, spacing: 24) {
                FoldMark().frame(width: 56, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.12)).frame(width: 89, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.08)).frame(width: 62, height: 5)
                }
                Text("A NEW POSSIBILITY").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            }.padding(22).frame(width: 152, height: 195)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 1))
                .rotationEffect(.degrees(-3))
        }
    }
}
