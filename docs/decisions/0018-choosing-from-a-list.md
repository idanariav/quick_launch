# 0018. Actions can ask the user to choose from a list

Status: Proposed
Date: 2026-10-21

## Context
Clarity's "Search & complete tasks" (PLAN M11) needs a list of open tasks in the launcher, filtered as you type, where ⏎ completes the selected task and ⌘⏎ opens it in Clarity.

Making each task a command doesn't work:
- hundreds of tasks would flood global search, Recent, Favorites and the settings page;
- tasks change constantly, so their ids aren't stable enough for history, favorites or settings.

ARCHITECTURE §10 anticipated "module-contributed launcher providers and views". The question is the contract. Modules depend only on core, so a module can't call the launcher; it needs a core protocol the launcher implements. Forms already work this way: `FormPresenting`, which the launcher implements and the executor uses.

## Decision
- **An action asks the user to pick something during its run,** the same way the executor asks for parameters with a form:

  ```swift
  let choice = try await invocation.choose(ChoiceList(
      title: "Open tasks", placeholder: "Search tasks",
      items: tasks.map { ChoiceItem(id: $0.id, title: $0.title, subtitle: $0.project) },
      primary: "Complete", secondary: "Open in Clarity"))
  switch choice.action {
  case .primary: …   // ⏎
  case .secondary: … // ⌘⏎
  }
  ```

  - **Core** gets `ChoiceList`, `ChoiceItem` (id, title, subtitle, optional icon) and `Choice` (the item id and which action).
  - **Protocol:** `ChoicePresenting` declares `present(_:) async throws -> Choice`. It throws `CancellationError` on Esc or dismissal, so the run ends quietly as for a dismissed form.
  - **The executor** passes its presenter into each `Invocation` as `choose(_:)`. Any action can then ask, with no wiring in the composition root. Tests use a fake.
  - **The launcher implements it,** as with forms:
    - it opens or keeps the window in a new `choice` mode;
    - the search field filters the items with the same fuzzy matcher and number keys (⌘1–9, §n);
    - the window shows the action names as hints.
- **What a list is not:**
  - Its items aren't commands. They aren't recorded in history, can't be favorites and don't appear in Settings or `quicklaunch list`.
  - The command that opens the list (e.g. `clarity/tasks`) is an ordinary command, with all of that.
- **Static items:** the action fetches the items, then shows them, and filtering is local. A list that queries per keystroke (a remote search) can be added later as a variant; nothing here rules it out.
- **The result is the action's own work.** After the choice, the action completes the task or opens the link, and reports through `invocation.result` as usual: a HUD "Completed …", or output to the panel.
- **From a hotkey or link,** choosing opens the launcher, as a form does when values are missing. Over the control socket with `wait`, the reply comes once the user has chosen and the action finished.

## Consequences
- Any module can offer pick-then-act flows: Clarity tasks, Claude sessions to resume, windows to focus, clipboard history. None of them needs launcher changes.
- The launcher gains a mode, rendered by the app target. The `Launcher` model grows, but the fuzzy matcher and number-key logic are reused.
- Only one list or form shows at a time. A new one replaces what's showing and cancels that run, as a new form does today.
