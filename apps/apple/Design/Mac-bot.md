# Mac bot · design review

[Review the boards](Mac-bot-review.pdf). The editable board is the "MB" section of the native Pencil file.

One bot runs on the person's own Mac while it is on. Every device shows whether that Mac is online, and messages wait while it is off.

1. **MB0 · Before.** Offscreen renders of the current native preview: the header says "Bot", the Computer tab is a status notice and a web link, and Settings holds only the account and appearance.
2. **MB1 / MB1d · Online.** A presence dot on the bot's avatar in the sidebar, "MacBook Pro · Online" under the chat title, and the Computer tab's "Runs on" and "Status" rows.
3. **MB2 / MB2d · Offline.** A grey dot, "MacBook Pro · Offline", and "Waiting for MacBook Pro" under the message that is waiting. Stop cancels it.
4. **MB3 · Computer tab.** Unchanged without a Mac; server; choosing the Mac; the confirmation before moving a bot; online; offline with the last-seen time; disabled while the bot works.
5. **MB4 · Settings → This Mac.** Off by default; the consent prompt; connected; keep awake "While bots work", "Always" or "Set hours"; background access turned off in Login Items; the server out of reach.
6. **MB5 · New bot.** "Runs on" appears only once a Mac is set up; the server stays the default.
7. **MB6 · iPhone.** The same dot, subtitle and waiting line.

## New copy

| Copy | Why it is needed |
| --- | --- |
| "MacBook Pro · Online" / "MacBook Pro · Offline" | The owner must see from any device whether the bot can work now. |
| "Waiting for MacBook Pro" | Without it a message sent while the Mac is off looks lost. Shown only on waiting messages. |
| "Runs on" | Chooses between the server and the Mac. Shown only after a Mac is set up. |
| "Run Forge on MacBook Pro?" / "It starts with an empty workspace on this Mac. Files on its current computer stay there." | Moving a bot does not move its files; this is the only warning before that happens. |
| "Available when Forge finishes" | Tooltip on the disabled "Runs on" while the bot works. |
| "This Mac", "Let bots use this Mac", "Status", "Connected", "Offline", "Keep awake", "While bots work", "Always", "Set hours", "From", "Until", "Bots" | The Mac's own switch, its state and the keep-awake schedule. "Bots" names which bots can run commands here. |
| "Allow bots to use this Mac?" / "Bots you run on this Mac can run commands and change files as you." | Consent before any command runs as the person. |
| "Off in Login Items" / "Open Login Items" | Shown only when macOS has stopped the background helper. |

The boards are a proposal for approval, not an installed change.
