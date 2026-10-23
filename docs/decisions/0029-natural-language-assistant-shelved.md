# 0029. A natural-language assistant layer with a local model: tried and shelved

Status: Rejected
Date: 2026-10-22

## Context
The user explored a local model layer above QuickLaunch that turns a request into a command run. "What are my tasks for the next three days" would run `clarity/view/next_three_days`, and "switch focus to work" would run `shortcuts/work`. The candidate was Cactus Needle 3: a small (8–29 MB file) on-device tool-calling model with a C engine for macOS. Its weights are Apache-2.0. Each command, with its typed parameters, maps directly to a tool schema, so the catalog was a natural fit.

A spike on 2026-10-22 measured it outside the app. It exported the real catalog with `quicklaunch list --json` (264 commands), wrote test phrases with expected commands and arguments, and scored the model's choice and arguments.

What it found:

- **The model is fast; changing its tool set isn't.** A query takes about 50 ms. Loading a new tool set takes 135–200 ms, and that happens on every query once candidates are picked per query.
- **The full catalog doesn't fit.** The engine takes about 32 KB of tool JSON (169 of the 264 commands). So a retrieval step (embeddings plus keyword ranking) has to pick a shortlist first.
- **Choosing the command was the weak part.**
  - On the full catalog, the best setup picked the right command 58% of the time. Even with the right command guaranteed among 8 candidates, it was right only 64% of the time.
  - Cut to 63 hand-picked commands with hand-written descriptions, it was right 61% of the time untuned. After a local LoRA fine-tune on 357 generated examples it was right 66% of the time.
  - That fine-tuned model got 37 of 55 answerable requests right. Taking the retrieval step's top-ranked command, with no model, got 36. The model added almost nothing to choosing.
- **Its confidence score didn't help.** Wrong answers often scored 0.8 or more. Local fine-tuning also drops the confidence head; only Cactus's cloud fine-tuning keeps it.
- **Filling arguments worked well:** durations, dates in QuickLaunch's own forms (`tomorrow`, `fri`, `+3d`), times, text and Clarity projects. Errors remained, such as a duration of `60` or a tag repeated.
- **Training cost:** 55 minutes of CPU for 3 epochs (JAX has no usable Mac GPU backend, and the trainer has no MLX path). It was still undertrained. The vendor's data generator calls a cloud API, so the spike wrote its training data locally instead.
- **Privacy:** the Python wrapper sends anonymous usage counts unless `NEEDLE_TELEMETRY=0` is set.
- **Apple's on-device Foundation Models** could not be compared, because Apple Intelligence was off on the test machine. A backend built on it would also only work for users who have it on.

## Decision
Don't build an assistant layer now. A launcher action that is wrong about a third of the time is worse than typing a few letters into fuzzy search. Fine-tuning didn't close the gap at a reasonable cost.

No code, extension point or dependency was added. The spike's scripts lived outside the repository and weren't kept.

## Consequences
If this comes back, the spike points to what to try first:

- **Metadata any backend needs:**
  - a `description` on commands: Shortcuts only say "Run shortcut", so nothing links "focus" to them; hand-written descriptions raised retrieval noticeably;
  - a per-command opt-in, like `external` (decision 0016), so only a chosen set is offered; fewer candidates helped every setup;
  - `quicklaunch list --json` exporting both, plus whether a command takes text input.
- **Better candidates for the model:**
  - Apple Foundation Models, compared on the same test set with Apple Intelligence on;
  - splitting the work: retrieval chooses the command, and a small model only fills that command's arguments, which Needle did well.
- **Needle only with more effort:** longer fine-tuning, or Cactus's cloud fine-tuning, which keeps the confidence score but uploads the command list and training phrases.
