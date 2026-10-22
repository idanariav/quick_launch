import QLCore
import SwiftUI

/// A field for one command parameter's value, used by the settings inspector and the
/// macro editor (decision 0028): a picker for yes/no and choices, a menu for several
/// choices, a text field otherwise. An empty text means the default. Pickers and the menu
/// commit at once; a text field commits on ⏎.
struct ParameterField<Label: View>: View {
    let parameter: CommandParameter
    @Binding var text: String
    let commit: (String) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        switch parameter.kind {
        case .boolean:
            Picker(selection: committing) {
                defaultOption
                Text("Yes").tag("true")
                Text("No").tag("false")
            } label: { label() }
        case .choice(let options):
            Picker(selection: committing) {
                defaultOption
                ForEach(options, id: \.self) { Text($0).tag($0) }
            } label: { label() }
        case .multiChoice(let options):
            LabeledContent {
                MultiChoiceMenu(options: options, text: Binding(
                    get: { text.isEmpty ? parameter.defaultValue ?? "" : text },
                    set: { text = $0; commit($0) }
                ))
            } label: { label() }
        case .text, .integer, .duration, .date:
            TextField(text: $text, prompt: Text(parameter.defaultValue ?? parameter.hint ?? "")) { label() }
                .onSubmit { commit(text) }
        }
    }

    private var committing: Binding<String> {
        Binding(get: { text }, set: { text = $0; commit($0) })
    }

    private var defaultOption: some View {
        Text("Default\(parameter.defaultValue.map { " (\($0))" } ?? "")").tag("")
    }
}
