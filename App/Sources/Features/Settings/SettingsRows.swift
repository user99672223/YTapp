import SwiftUI

/// One value a settings choice can take, with the text shown for it.
struct ChoiceOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String

    var id: Value { value }
}

/// A settings row that shows the current value and opens a list of every value, with a checkmark
/// on the current one. Used instead of navigation-style Pickers: on tvOS their list doesn't mark
/// which value is selected.
struct ChoiceRow<Value: Hashable>: View {
    let title: String
    let options: [ChoiceOption<Value>]
    /// Shown under the list of values, to explain them while choosing.
    let footer: String?
    @Binding var selection: Value

    init(_ title: String, selection: Binding<Value>, options: [ChoiceOption<Value>], footer: String? = nil) {
        self.title = title
        self._selection = selection
        self.options = options
        self.footer = footer
    }

    var body: some View {
        NavigationLink {
            ChoiceList(title: title, options: options, selection: $selection, footer: footer)
        } label: {
            LabeledContent(title, value: currentLabel)
        }
    }

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? String(describing: selection)
    }
}

/// The list behind a ChoiceRow: choosing a value saves it and goes back to Settings.
struct ChoiceList<Value: Hashable>: View {
    let title: String
    let options: [ChoiceOption<Value>]
    let footer: String?
    @Binding var selection: Value
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Value?

    init(title: String, options: [ChoiceOption<Value>], selection: Binding<Value>, footer: String? = nil) {
        self.title = title
        self.options = options
        self._selection = selection
        self.footer = footer
    }

    var body: some View {
        List {
            if let footer {
                Section {
                    rows
                } footer: {
                    Text(footer)
                }
            } else {
                rows
            }
        }
        .navigationTitle(title)
        // Start on the current value, like the system's own settings lists.
        .defaultFocus($focused, selection)
    }

    private var rows: some View {
        ForEach(options) { option in
            Button {
                selection = option.value
                dismiss()
            } label: {
                HStack(spacing: Theme.Spacing.titleToContent) {
                    Text(option.label)
                    Spacer(minLength: 0)
                    if option.value == selection {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                }
            }
            .focused($focused, equals: option.value)
            .accessibilityAddTraits(option.value == selection ? .isSelected : [])
        }
    }
}

/// A read-only row, a name and its value, like the rows of the Apple TV's own Settings → General →
/// About: nothing happens when it's pressed, but it can be highlighted like every other row. A
/// tvOS list scrolls only by moving focus, so rows nothing can highlight (after a list's last
/// control, for example) could never be scrolled into view, and a screen where nothing can be
/// highlighted hands Menu to tvOS, which leaves the app instead of going back.
struct InfoRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        Button {} label: {
            LabeledContent(title, value: value)
        }
    }
}

/// Label for a destructive button in a settings list. The system's destructive red turns pale
/// pink on the white row of a focused button and can't be read; this stays red when the row isn't
/// focused and turns dark red when it is.
struct DestructiveRowLabel: View {
    let title: String
    @Environment(\.isFocused) private var isFocused

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .foregroundStyle(isFocused ? Color(red: 0.7, green: 0.05, blue: 0.05) : Color.red)
    }
}

/// The Apple TV's own Match Frame Rate switch (Settings → Video and Audio → Match Content). tvOS
/// ignores an app's request for another refresh rate unless it's on, whatever Tube's setting is.
enum AppleTVFrameRateMatching {
    /// This tvOS has no display manager for apps (see `DisplayCriteriaController`).
    case unavailable
    case off
    case on

    /// Read again whenever it's shown: the switch is changed outside the app.
    @MainActor
    static var current: AppleTVFrameRateMatching {
        guard DisplayCriteriaController.isAvailable else { return .unavailable }
        return DisplayCriteriaController.isMatchingEnabled ? .on : .off
    }
}
