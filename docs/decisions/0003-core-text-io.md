# 0003. Text input/output is a core pipeline, not per feature

Status: Accepted
Date: 2026-10-20

## Context
M1 put `input: selection` and `output: replace_selection` on the Claude skill action only. A shell text transform, a translation integration or any future text tool would need the same plumbing: capture the selection (through Accessibility, or a ⌘C fallback that restores the pasteboard), then paste the result back into the original app. Each would re-implement it, slightly differently.

## Decision
`InputSource` and `OutputTarget` are core vocabulary. An action type declares support and defaults with `ActionIO`. Core reads `input:` and `output:` from the action spec, rejects them on types that don't support text, resolves the input before running, and hands the action an `OutputSink`. Both are core-owned enums rather than registries: they are a small, stable vocabulary, and new targets are added deliberately.

## Consequences
- Selection capture and paste-back are written once and every text-capable action gets them.
- Text-capable actions receive `Invocation.input` and write to `Invocation.output`; they never touch the pasteboard themselves.
- Adding an output target (e.g. a notification) is a core change that every text action benefits from.
