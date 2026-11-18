# New private space · Mac design review

[Review the three boards](Private-space-review.pdf)

1. **09 · Before.** The shipping 0.12.0 dialog is 384 × 209 CSS pixels in an isolated fixture workspace. Beside it is the reported native Mac sheet. The shared native sheet currently reserves up to 490 points even for one field.
2. **10 · Proposal.** One leading-aligned name field, followed immediately by Cancel and Create space. The sheet takes its height from its content, not the parent window. The four states show focus, a valid name, submission, and a recoverable error. The depicted blue is the example macOS system accent, not a fixed brand color.
3. **11 · After creation.** Open the space directly when it has no available tools to choose from. Otherwise offer the [release’s existing tool-selection step](https://github.com/elie222/rakazo/blob/8b3dcd596dedc63021d98373107ab06665b0ad41/apps/web/src/pages/shell/dialogs.tsx), preselecting only items already available in all spaces. Cap the list, not the entire dialog; Continue stays visible. The native app does not implement this step yet.

On opening, focus the field. Match the release’s 60-character limit. Ignore blank or whitespace-only names; Return submits a valid name unless text is being composed. Escape cancels before submission. While creating, disable resubmission and dismissal. On failure keep the entered name, show the error by the field, and allow retry. On success do not repeat creation to retry tool selection.

The sheet is a proposal for approval, not an installed change. Apply the fit-to-content pattern to other short forms as they are reviewed rather than shrinking long, scrollable screens indiscriminately.
