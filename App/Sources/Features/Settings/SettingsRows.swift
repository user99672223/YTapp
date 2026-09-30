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
    @Binding var selection: Value

    init(_ title: String, selection: Binding<Value>, options: [ChoiceOption<Value>]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    var body: some View {
        NavigationLink {
            ChoiceList(title: title, options: options, selection: $selection)
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
    @Binding var selection: Value
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Value?

    init(title: String, options: [ChoiceOption<Value>], selection: Binding<Value>) {
        self.title = title
        self.options = options
        self._selection = selection
    }

    var body: some View {
        List {
            ForEach(options) { option in
                Button {
                    selection = option.value
                    dismiss()
                } label: {
                    HStack(spacing: 24) {
                        Text(option.label)
                        Spacer(minLength: 0)
                        if option.value == selection {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .focused($focused, equals: option.value)
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .navigationTitle(title)
        // Start on the current value, like the system's own settings lists.
        .defaultFocus($focused, selection)
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
