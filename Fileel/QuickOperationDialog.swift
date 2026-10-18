import AppKit

// one-field tasks stay close to finder instead of opening the general file workspace
@MainActor
enum QuickOperationDialog {
    static func rename(_ files: [URL]) -> [URL]? {
        guard let first = files.first else { return nil }
        let directory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let initial = directory ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
        let dialog = InputDialog(title: files.count == 1 ? "Rename File" : "Rename \(files.count) Files",
                                 message: "File extensions are kept. Multiple files are numbered automatically.",
                                 label: "Name", value: initial, action: "Rename")
        dialog.validate = { name, _ in
            do {
                let targets = try FileActions.renameTargets(files, baseName: name)
                return .success(targets.prefix(2).map(\.lastPathComponent).joined(separator: "\n"))
            } catch { return .failure(error) }
        }
        return dialog.submit { name, _ in try FileActions.rename(files, baseName: name) }
    }

    static func showIfSupported(files: [URL], operation: FileOperation) -> Bool {
        guard case .tool(let tool) = operation,
              [.shiftSubtitles, .speedSubtitles, .protectPDF, .encryptArchive].contains(tool) else { return false }
        let password = [.protectPDF, .encryptArchive].contains(tool)
        let speed = tool == .speedSubtitles
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 3
        formatter.usesGroupingSeparator = false
        let dialog = InputDialog(title: operation.title.replacingOccurrences(of: "…", with: ""),
                                 message: password ? "Save a protected copy. The original stays unchanged." : "Save an adjusted copy. The original stays unchanged.",
                                 label: password ? "Password" : speed ? "Speed multiplier" : "Offset in seconds",
                                 value: password ? "" : formatter.string(from: speed ? 1 : 0) ?? "0",
                                 action: "Save Copy", secure: password)
        dialog.validate = { value, confirmation in
            if password {
                guard !value.isEmpty else { return .failure(FileelError.message("Enter a password.")) }
                guard value == confirmation else { return .failure(FileelError.message("The passwords must match.")) }
                return .success("Keep this password to open the saved copy.")
            }
            guard let number = number(value, formatter: formatter),
                  !speed || number > 0 else {
                return .failure(FileelError.message(speed ? "Enter a speed greater than zero." : "Enter an offset in seconds."))
            }
            return .success(speed ? "1× keeps the original timing. 2× plays twice as fast." : "Positive values delay subtitles. Negative values move them earlier.")
        }
        let options: OperationOptions? = dialog.submit { value, _ in
            var options = AppModel.shared.defaults()
            if password { options.password = value }
            else if speed { options.speed = number(value, formatter: formatter)! }
            else { options.offset = number(value, formatter: formatter)! }
            return options
        }
        if let options { AppModel.shared.run(operation, inputs: files, options: options) }
        return true
    }

    // accept the user's decimal separator while rejecting partially parsed input
    private static func number(_ text: String, formatter: NumberFormatter) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: formatter.decimalSeparator, with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
}

// keep validation beside the field and retain what was typed when a rename collides
@MainActor
private final class InputDialog: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    let field: NSTextField
    let confirmation: NSSecureTextField?
    let feedback = NSTextField(wrappingLabelWithString: "")
    var validate: ((String, String) -> Result<String, Error>)?

    init(title: String, message: String, label: String, value: String, action: String, secure: Bool = false) {
        field = secure ? NSSecureTextField(string: value) : NSTextField(string: value)
        confirmation = secure ? NSSecureTextField(string: "") : nil
        super.init()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.addArrangedSubview(NSTextField(labelWithString: label))
        stack.addArrangedSubview(field)
        field.setAccessibilityLabel(label)
        field.delegate = self
        if let confirmation {
            stack.addArrangedSubview(NSTextField(labelWithString: "Confirm password"))
            stack.addArrangedSubview(confirmation)
            confirmation.setAccessibilityLabel("Confirm password")
            confirmation.delegate = self
            field.nextKeyView = confirmation
        }
        feedback.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        feedback.textColor = .secondaryLabelColor
        stack.addArrangedSubview(feedback)
        for view in stack.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        feedback.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    private func refresh() {
        switch validate?(field.stringValue, confirmation?.stringValue ?? "") {
        case .success(let hint):
            feedback.stringValue = hint
            feedback.textColor = .secondaryLabelColor
            alert.buttons.first?.isEnabled = true
        case .failure(let error):
            feedback.stringValue = error.localizedDescription
            feedback.textColor = .systemRed
            alert.buttons.first?.isEnabled = false
        case nil: break
        }
    }

    func submit<T>(_ action: (String, String) throws -> T) -> T? {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            do { return try action(field.stringValue, confirmation?.stringValue ?? "") }
            catch {
                feedback.stringValue = error.localizedDescription
                feedback.textColor = .systemRed
            }
        }
        return nil
    }
}
