import Foundation
import Observation
import QLCore

/// Shows the macro editor's window; implemented by the app (decision 0028).
@MainActor
public protocol MacroEditorPresenting: AnyObject {
    func show()
}

/// The macro editor's state and behavior (decision 0028). The file is its model: macros
/// and their steps are read from the loaded config's `actions:`, and each change is
/// written at once to `preferences.yaml` through the checked save. Macros in
/// `config.yaml` are listed read-only.
@MainActor @Observable
public final class MacroEditor {
    public struct Entry: Identifiable, Equatable {
        /// The macro's name: its key under `actions:` and its command's title.
        public let id: String
        /// Saved in `preferences.yaml`; one in `config.yaml` is read-only here.
        public let isEditable: Bool
    }

    public enum StepKind: Equatable {
        /// `command:` with optional `args:`.
        case command(CommandID, arguments: [String: String])
        /// `wait:`, as written.
        case wait(String)
        /// Anything else (e.g. an inline action written by hand), kept as written.
        case custom(String)
    }

    public struct Step: Identifiable, Equatable {
        /// Its position in the list.
        public let id: Int
        public let kind: StepKind
    }

    /// A command a step can run.
    public struct CommandChoice: Identifiable, Equatable {
        public let id: CommandID
        public let title: String
        public let subtitle: String?
        public let icon: CommandIcon?
        public let parameters: [CommandParameter]
    }

    public private(set) var selection: String?
    /// The name field; `commitName()` renames the macro.
    public var name = ""
    /// What went wrong with the last change, e.g. a name that's taken.
    public private(set) var problem: String?
    /// A value that couldn't be saved, by step.
    public private(set) var stepProblems: [Int: String] = [:]
    /// Every command a step can run, loaded when the window opens.
    public private(set) var commandChoices: [CommandChoice] = []

    public weak var window: (any MacroEditorPresenting)?

    @ObservationIgnored private let catalog: CommandCatalog
    // Not observation-ignored: views read the config through it.
    private var store: ConfigStore!

    static let macroType = "\(MacroModule.moduleID).\(MacroModule.runType)"

    public init(catalog: CommandCatalog) {
        self.catalog = catalog
    }

    /// Breaks the editor → store → loader → module → editor cycle; called once by the
    /// composition root.
    public func attach(store: ConfigStore) {
        self.store = store
    }

    // MARK: - Showing

    public func open() async {
        window?.show()
        if selection == nil || !macros.contains(where: { $0.id == selection }) { select(macros.first?.id) }
        await loadChoices()
        await catalog.refresh()
        await loadChoices()
    }

    /// The window closed.
    public func closed() {
        commitName()
    }

    public func select(_ name: String?) {
        if name != selection { commitName() }
        selection = name
        self.name = name ?? ""
        problem = nil
        stepProblems = [:]
    }

    private func loadChoices() async {
        let macros = Set(store.config.actions.filter { $0.value.type.description == Self.macroType }.keys)
        commandChoices = await catalog.allCommands()
            // No macros (decision 0027), and not this window's own command.
            .filter { id, _ in
                !(id.namespace == CommandCatalog.configNamespace && macros.contains(id.name)) && id.namespace != MacroModule.moduleID
            }
            .map { id, command in
                CommandChoice(id: id, title: command.title, subtitle: command.subtitle, icon: command.icon, parameters: command.parameters)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - Reading

    /// Every macro, from both files, sorted by name. On a clash `config.yaml`'s wins.
    public var macros: [Entry] {
        let documents = store.config.actionDocuments
        var entries: [String: Entry] = [:]
        for (name, value) in documents.preferences where Self.isMacro(value) {
            entries[name] = Entry(id: name, isEditable: true)
        }
        for (name, value) in documents.config where Self.isMacro(value) {
            entries[name] = Entry(id: name, isEditable: false)
        }
        return entries.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    public var isEditable: Bool {
        selection.map { name in macros.contains { $0.id == name && $0.isEditable } } ?? false
    }

    /// The selected macro's command, e.g. for its shortcut in Settings.
    public var selectedCommand: CommandID? {
        selection.map { CommandID(namespace: CommandCatalog.configNamespace, name: $0) }
    }

    public var steps: [Step] {
        rawSteps.enumerated().map { Step(id: $0.offset, kind: Self.kind(of: $0.element)) }
    }

    public func choice(_ id: CommandID) -> CommandChoice? {
        commandChoices.first { $0.id == id }
    }

    /// What's wrong with a step as it is, e.g. a required value nobody set; `nil` if nothing.
    public func note(for step: Step) -> String? {
        guard case .command(let id, let arguments) = step.kind, !commandChoices.isEmpty else { return nil }
        guard let choice = choice(id) else { return "There's no such command, or it's switched off." }
        let configured = store.config.commandSettings.argumentLayers(id).reduce(into: arguments) { values, layer in
            for (key, value) in layer.values where values[key] == nil { values[key] = value }
        }
        let missing = choice.parameters.filter { parameter in
            !parameter.isOptional && parameter.defaultValue == nil
                && configured[parameter.id]?.trimmingCharacters(in: .whitespaces).isEmpty != false
        }
        guard !missing.isEmpty else { return nil }
        return "Needs \(missing.map(\.title).joined(separator: ", ")): the macro would stop here."
    }

    // MARK: - Macros

    /// A new macro with no steps, selected.
    public func add() {
        commitName()
        var name = "untitled"
        var number = 2
        while nameIsUsed(name) {
            name = "untitled \(number)"
            number += 1
        }
        let macro = ConfigValue(.map([
            ConfigEntry(key: "type", value: ConfigValue(.scalar(Self.macroType))),
            ConfigEntry(key: "steps", value: ConfigValue(.list([]))),
        ]))
        guard save({ $0.actions[name] = macro }) else { return }
        select(name)
    }

    /// Deletes a macro, with its shortcut, keyword, aliases and favorite, and selects the one after it.
    public func delete(_ name: String) {
        let index = macros.firstIndex { $0.id == name } ?? 0
        let id = CommandID(namespace: CommandCatalog.configNamespace, name: name)
        let deleted = save { preferences in
            preferences.actions[name] = nil
            preferences.commands[id] = nil
            preferences.setFavorite(id, false)
        }
        guard deleted, selection == name else { return }
        selection = nil // nothing to rename any more
        let remaining = macros
        select(remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id)
    }

    /// Renames the selected macro to the name field, if that changed and is allowed. Its
    /// shortcut, keyword, aliases and favorite in `preferences.yaml` move with it.
    public func commitName() {
        guard let old = selection, isEditable else { return }
        let new = name.trimmingCharacters(in: .whitespaces)
        guard new != old else { return }
        if let reason = nameProblem(new) {
            problem = reason
            return
        }
        let oldID = CommandID(namespace: CommandCatalog.configNamespace, name: old)
        let newID = CommandID(namespace: CommandCatalog.configNamespace, name: new)
        let renamed = save { preferences in
            preferences.actions[new] = preferences.actions.removeValue(forKey: old)
            if let settings = preferences.commands.removeValue(forKey: oldID) { preferences.commands[newID] = settings }
            if let index = preferences.favorites?.firstIndex(of: oldID) { preferences.favorites?[index] = newID }
        }
        guard renamed else { return }
        selection = new
        name = new
    }

    /// Why `name` can't be a macro's new name, or nil if it can.
    func nameProblem(_ name: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        if name.isEmpty { return "A macro needs a name." }
        if !name.unicodeScalars.allSatisfy(allowed.contains) { return "Use only letters, digits, spaces, - and _ in the name." }
        if name == "pass_through" { return "“pass_through” is reserved." }
        if nameIsUsed(name) { return "There's already an action named “\(name)”." }
        return nil
    }

    private func nameIsUsed(_ name: String) -> Bool {
        let documents = store.config.actionDocuments
        return documents.config[name] != nil || documents.preferences[name] != nil
    }

    // MARK: - Steps

    public func addCommandStep(_ id: CommandID) {
        saveSteps(rawSteps + [Self.commandStep(id, arguments: [:])])
    }

    public func addWait() {
        saveSteps(rawSteps + [ConfigValue(.map([ConfigEntry(key: "wait", value: ConfigValue(.scalar("1s")))]))])
    }

    public func removeStep(_ index: Int) {
        var steps = rawSteps
        guard steps.indices.contains(index) else { return }
        steps.remove(at: index)
        saveSteps(steps)
    }

    /// Moves the steps at `offsets` to before `destination`, as a list's drag reports it.
    public func moveSteps(from offsets: IndexSet, to destination: Int) {
        var steps = rawSteps
        let moving = offsets.filter(steps.indices.contains).map { steps[$0] }
        for index in offsets.sorted(by: >) where steps.indices.contains(index) { steps.remove(at: index) }
        let target = destination - offsets.filter { $0 < destination }.count
        steps.insert(contentsOf: moving, at: min(max(target, 0), steps.count))
        saveSteps(steps)
    }

    /// An empty text removes the value, so the command's own default (or its settings) applies.
    public func setArgument(_ index: Int, _ parameter: CommandParameter, _ text: String) {
        guard rawSteps.indices.contains(index), case .command(let id, var arguments) = Self.kind(of: rawSteps[index]) else { return }
        let text = text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            do {
                _ = try parameter.parse(text)
            } catch {
                stepProblems[index] = "\(parameter.title): \(error.message)"
                return
            }
        }
        arguments[parameter.id] = text.isEmpty ? nil : text
        var steps = rawSteps
        steps[index] = Self.commandStep(id, arguments: arguments)
        saveSteps(steps)
    }

    public func setWait(_ index: Int, _ text: String) {
        guard rawSteps.indices.contains(index), case .wait = Self.kind(of: rawSteps[index]) else { return }
        let text = text.trimmingCharacters(in: .whitespaces)
        do {
            _ = try Duration(configScalar: text)
        } catch {
            stepProblems[index] = error.message
            return
        }
        var steps = rawSteps
        steps[index] = ConfigValue(.map([ConfigEntry(key: "wait", value: ConfigValue(.scalar(text)))]))
        saveSteps(steps)
    }

    // MARK: - Reading and writing the file

    /// The selected macro's `steps:` as written.
    private var rawSteps: [ConfigValue] {
        guard let selection, let macro = store.config.actionDocuments.config[selection] ?? store.config.actionDocuments.preferences[selection],
              case .list(let steps)? = Self.value(macro, "steps")?.kind else { return [] }
        return steps
    }

    private func saveSteps(_ steps: [ConfigValue]) {
        guard isEditable, let name = selection, case .map(var entries)? = store.config.actionDocuments.preferences[name]?.kind else { return }
        let value = ConfigValue(.list(steps))
        if let index = entries.firstIndex(where: { $0.key == "steps" }) {
            entries[index] = ConfigEntry(key: "steps", value: value)
        } else {
            entries.append(ConfigEntry(key: "steps", value: value))
        }
        if save({ $0.actions[name] = ConfigValue(.map(entries)) }) { stepProblems = [:] }
    }

    /// Saves `change` to `preferences.yaml`; on failure, says why.
    @discardableResult
    private func save(_ change: (inout Preferences) -> Void) -> Bool {
        do {
            try store.updatePreferences(change)
            problem = nil
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    static func isMacro(_ value: ConfigValue) -> Bool {
        if case .scalar(macroType)? = Self.value(value, "type")?.kind { return true }
        return false
    }

    static func kind(of step: ConfigValue) -> StepKind {
        guard case .map(let entries) = step.kind else { return .custom("Custom step") }
        let keys = Set(entries.map(\.key))
        if keys == ["wait"], case .scalar(let text)? = value(step, "wait")?.kind {
            return .wait(text)
        }
        if keys.isSubset(of: ["command", "args"]), case .scalar(let text)? = value(step, "command")?.kind,
           let id = try? CommandID(configScalar: text), let arguments = scalars(value(step, "args")) {
            return .command(id, arguments: arguments)
        }
        switch value(step, "action")?.kind {
        case .scalar(let name)?: return .custom("Action: \(name)")
        case .map?:
            if case .scalar(let type)? = value(step, "action").flatMap({ value($0, "type") })?.kind { return .custom("Action: \(type)") }
        default: break
        }
        if case .scalar(let command)? = value(step, "command")?.kind { return .custom("\(command), with settings made in the file") }
        return .custom("Custom step")
    }

    private static func commandStep(_ id: CommandID, arguments: [String: String]) -> ConfigValue {
        var entries = [ConfigEntry(key: "command", value: ConfigValue(.scalar(id.description)))]
        if !arguments.isEmpty {
            let values = arguments.sorted { $0.key < $1.key }.map { ConfigEntry(key: $0.key, value: ConfigValue(.scalar($0.value))) }
            entries.append(ConfigEntry(key: "args", value: ConfigValue(.map(values))))
        }
        return ConfigValue(.map(entries))
    }

    /// A mapping of single values; an absent one is empty, anything else `nil`.
    private static func scalars(_ value: ConfigValue?) -> [String: String]? {
        guard let value else { return [:] }
        guard case .map(let entries) = value.kind else { return nil }
        var values: [String: String] = [:]
        for entry in entries {
            guard case .scalar(let text) = entry.value.kind else { return nil }
            values[entry.key] = text
        }
        return values
    }

    private static func value(_ map: ConfigValue, _ key: String) -> ConfigValue? {
        guard case .map(let entries) = map.kind else { return nil }
        return entries.first { $0.key == key }?.value
    }
}
