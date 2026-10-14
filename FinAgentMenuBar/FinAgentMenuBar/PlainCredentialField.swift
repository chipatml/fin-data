//
//  PlainCredentialField.swift
//  FinAgentMenuBar
//
//  Credential editor that does not rewrite hyphens or quotes, and that a
//  button can read synchronously. SwiftUI SecureField in a menu-bar window
//  often leaves the binding empty until focus ends, so a blank secret keeps
//  the previously saved value.
//

import AppKit
import SwiftUI

/// Live NSTextField values, keyed by form field. Weak so a dismissed field
/// does not stay in memory; the button reads it on the click, before dismiss.
@MainActor
final class PlainCredentialFieldRegistry: ObservableObject {
    private var fields: [String: WeakField] = [:]

    func register(_ field: NSTextField, for key: String) {
        fields[key] = WeakField(field)
    }

    func unregister(key: String, field: NSTextField) {
        if fields[key]?.field === field {
            fields.removeValue(forKey: key)
        }
    }

    /// The string the control will submit, or nil if that field is not on screen.
    func value(for key: String) -> String? {
        guard let field = fields[key]?.field else { return nil }
        return PlainCredentialFieldReader.string(from: field)
    }

    private struct WeakField {
        weak var field: NSTextField?
        init(_ field: NSTextField) { self.field = field }
    }
}

enum PlainCredentialFieldReader {
    /// Prefers the field editor when it holds real characters. A secure field
    /// editor full of bullets is the echo mask, so the control's stringValue
    /// (after validateEditing) is the password.
    static func string(from field: NSTextField) -> String {
        if let editor = field.currentEditor() as? NSTextView {
            let edited = editor.string
            if !edited.isEmpty && !isBulletMask(edited) {
                return edited
            }
        }
        field.validateEditing()
        return field.stringValue
    }

    static func isBulletMask(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x2022 || scalar.value == 0x25CF
        }
    }
}

/// Single-line AppKit field with smart quotes, smart dashes, spelling, and
/// text replacement turned off on the field and on its field editor.
struct PlainCredentialField: NSViewRepresentable {
    let key: String
    let placeholder: String
    let isSecure: Bool
    @Binding var text: String
    var registry: PlainCredentialFieldRegistry

    func makeCoordinator() -> Coordinator {
        Coordinator(key: key, text: $text, registry: registry)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = isSecure ? PlainNSSecureTextField() : PlainNSTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.allowsEditingTextAttributes = false
        field.importsGraphics = false
        field.isAutomaticTextCompletionEnabled = false
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.translatesAutoresizingMaskIntoConstraints = false
        registry.register(field, for: key)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        registry.register(field, for: key)
        if let editor = field.currentEditor() as? NSTextView {
            Self.disableSubstitutions(on: editor)
        }
        // The binding matches what this field last published. Do not write it
        // back or the insertion point jumps. An environment switch or a clear
        // after save changes the binding from outside and must update the field.
        guard context.coordinator.lastPublished != text else { return }
        context.coordinator.lastPublished = text
        if field.stringValue != text {
            field.stringValue = text
        }
        if let editor = field.currentEditor() as? NSTextView {
            let masked = PlainCredentialFieldReader.isBulletMask(editor.string)
            if (text.isEmpty || !masked) && editor.string != text {
                editor.string = text
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 288, height: 24)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.registry.unregister(key: coordinator.key, field: nsView)
        nsView.delegate = nil
    }

    static func disableSubstitutions(on editor: NSTextView) {
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.enabledTextCheckingTypes = []
        editor.smartInsertDeleteEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let key: String
        var text: Binding<String>
        let registry: PlainCredentialFieldRegistry
        var lastPublished: String

        init(key: String, text: Binding<String>, registry: PlainCredentialFieldRegistry) {
            self.key = key
            self.text = text
            self.registry = registry
            self.lastPublished = text.wrappedValue
        }

        func controlTextDidChange(_ notification: Notification) {
            publish(notification)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            publish(notification)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let editor = (notification.object as? NSTextField)?.currentEditor() as? NSTextView else { return }
            PlainCredentialField.disableSubstitutions(on: editor)
        }

        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
            if let editor = fieldEditor as? NSTextView {
                PlainCredentialField.disableSubstitutions(on: editor)
            }
            return true
        }

        private func publish(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let value = PlainCredentialFieldReader.string(from: field)
            lastPublished = value
            text.wrappedValue = value
        }
    }
}

private final class PlainNSTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            PlainCredentialField.disableSubstitutions(on: editor)
        }
        return accepted
    }
}

private final class PlainNSSecureTextField: NSSecureTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            PlainCredentialField.disableSubstitutions(on: editor)
        }
        return accepted
    }
}
