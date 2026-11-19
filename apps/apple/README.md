# Rakazo Native

A SwiftUI client for an existing Rakazo server. One multiplatform target builds **directly for macOS** and for iPhone/iPad; it does not use Mac Catalyst. The Mac preview has its own app container and Keychain identity (`dev.rakazo.nativeclient.macpreview`). It does not replace the original Rakazo or the previous Catalyst app, import their accounts, or run a server or model on your device. The iOS app keeps its existing identity (`dev.rakazo.nativeclient`).

## Try it

- From the repository root, `open apps/apple/RakazoNative.xcodeproj`. Run the commands below from `apps/apple`; no JavaScript dependencies are needed to build the native client.
- **Mac:** open **Rakazo Mac** from your user Applications folder. For development, use the `RakazoMac` scheme with **My Mac**, or run `./Tools/run-mac.sh` to build and open a Release copy from the checkout. Requires macOS 14 or later. The local build is ad-hoc signed, not a notarized distribution.
- **iPhone or iPad:** open `RakazoNative.xcodeproj`, select the `RakazoNative` scheme and a simulator, then Run. For a physical device, select your own signing team in Xcode. The deployment target is iOS 17 or newer. The generated project is included; XcodeGen is only needed after changing `project.yml`.
- **Without a server:** choose **Explore a sample workspace → Agent walkthrough** to read computer and helper updates, answer a question, and react to a message. Or press **⌘K**, type **Chief**, press Return, and send a message. The sample is local, not model output. Choose **Account → Connect a server** to leave it.
- **With a server:** enter the origin of your Rakazo deployment and use the sign-in method it supports. Use HTTPS outside loopback. The native app stores the session in the device-only Keychain, not the password. The ad-hoc Mac build has no provisioned Keychain access group: choose **Continue for this session** to sign in until quit. No token is written to preferences and the browser does not receive it.

### Try the sample integrations and computers

| Start in the sample workspace | What to try |
| --- | --- |
| **Mac: Connect apps → Discover** | Click **Connect Slack** on its card, then **Start sample authorization → Check connection**. Cancel leaves it unconnected. Click elsewhere on a card for details. |
| **Mac: Apps → Gmail** | Review available tools and both sample accounts. Rename or disconnect one, or review the named accounts before disconnecting Gmail. |
| **Mac: My integrations → Agentic Brain** | Edit its connection, credentials and advanced settings; save and reopen. Reconnect, test, choose individual bot tools, or remove after confirmation. |
| **Mac: Plugins · Skills · +** | Open Linear and add or remove its skills separately from its connector. Write a skill, read a packaged skill, or use **+** to import a repository or configure a custom source. |
| **Connect apps → MCP servers** | Open **Linear**, choose which bots can use it and save. Inspect GitHub’s error, Notion’s sign-in requirement and Files’ installation state. Add a server from the public catalog. |
| **Integrations walkthrough** | Review Slack’s connection request from chat. Approve or dismiss the bot’s request to use Linear; its grant is visible under **Agent access**. |
| **Computer walkthrough → Review bot screen…** | Opening the screen only watches. **Take control**, change the checklist title or mark it reviewed, then **I’m done**. The bot reports what you changed. Closing without finishing releases control but leaves the request pending. **Profile → Computer → View bot screen** lets you request another review. |
| **Computer walkthrough → Review computer access…** | This is the opposite direction: the bot asks to read a note on a **simulated Mac**. Decline, or enable both simulated permissions and authorize the read. On Mac, **Profile → Computer → Computer access…** also lets you revoke it. The desktop note is separate from the bot’s checklist. |

The catalog is shipped in the app; the sample never contacts a provider, installs an MCP package, or reads a local file, screen or account. Existing sample workspaces gain the walkthroughs without a reset. The [parity ledger](PARITY.md) documents the public data sources and live limitations.

## Native workflows

| Surface | What you can do |
| --- | --- |
| Workspace | Switch spaces, create bots, groups and private spaces; search chats and message history, read a match in context, and jump back to the live conversation; pin or mark a conversation unread. |
| Conversation | Send, react, reply or quote a passage, mark unread, watch the active bot work and write, answer a question, stop a run, and transfer attachments. Tool progress is transient; actionable cards remain. AI-recipient disclosures appear before sending when required. |
| Inspector | Edit bot profiles and group membership, inspect computer status, and list pages and routines. Create a paused daily routine, edit its prompt, activate or pause it, read run history, or delete it. |
| Activity and settings | Open the chat behind a run. Review a connector, authorize in the provider’s browser, check its status, inspect tools, rename or revoke an account. Change appearance and sign out. |

This is **not full Rakazo feature parity**. [The parity ledger](PARITY.md) separates native interactions, web handoffs, unimplemented surfaces and verification. Web handoffs require the deployment’s web UI and a separate browser session; they do not embed React or a WebView. The sample does not perform real integrations or retain uploaded file bytes. Attachment reads are capped at 24 MB and also respect server upload limits.

## Interface

Rakazo Desktop 0.12.0 is the reference for the product and its visual identity. REA’s bound-window inspection and native computer use were used to compare the running app, not to recover implementation code. Telegram for Mac was a reference **only for interaction**: an inset, floating conversation list and a chat that stays put while you browse or search. In light mode, one white canvas extends from the title bar through the chat and behind the floating sidebar. Dark mode uses the same layout with the system background.

Bot artwork comes from the original mobile avatar components and motion data. The checked-in `AvatarEngine` asset projects them into native Canvas layers without a WebView, a substitute mascot or an extra mask. To regenerate it, run `node Tools/Avatars/compile.mjs /path/to/rakazo` against the reference source with its JS dependencies installed.

**⌘K opens a modal command menu over the workspace**, including from the composer. Type to find conversations, pages (connected servers), or actions. Use ↑/↓ and Return to choose, or Escape to dismiss without changing the draft. The visible sidebar search is separate and still searches message history. Without a keyboard, use **Command menu** in the workspace menu.

To try the private-space flow, choose **⌘K → New private space**, enter a name and press Return. If there are tools to choose from, select what the new space can use and choose **Continue**. Only tools available in all spaces start checked; with no eligible tools, the new space opens immediately. On Mac the name sheet fits its content, and only a long list of tools scrolls.

On Mac, drag the floating panel’s outside edge to resize it or double-click to reset. In a narrow window it opens over the chat; selecting a conversation or clicking outside dismisses it. Use `⌘B` for the sidebar, `⌘N` for a new bot, `⌘1`–`⌘9` to choose a chat, and `⌘,` for Settings. Conversation details open in an inspector when there is room and in a content-fitting sheet otherwise. On a wide iPad, drag the sidebar grip or double-tap to reset it. iPhone and narrow iPad windows use a navigation stack with the system back gesture.

`App/Design.swift` defines the layout and semantic colors. Your bubbles and the enabled Send button take the selected bot’s color with white text in both appearances, following [Rakazo’s shared color rule](../../packages/core/src/avatars/bot-avatar-colors.ts). Groups, photo avatars and white bots use the neutral theme colors. Increase Contrast deepens bright accents further. Bot replies and sidebar selections stay neutral. iOS uses Dynamic Type; sidebar motion respects Reduce Motion and VoiceOver can adjust its width.

On Mac, hover over or keyboard-focus a sent or received bubble to reveal its actions beside the text. React opens a popover; More opens the system menu. Right-click for **Select text…** to quote a passage. Drag Finder files anywhere in the open chat, or use the paperclip. Releasing stages files beside the draft; only **Send** posts them. A failed file is identified inline without discarding the other attachments.

## Where to make changes

`App/Connection.swift`, `App/Models.swift`, `App/WorkspaceStore.swift` and `App/Timeline.swift` share authentication, API models, workspace state, chat history and streaming without importing a UI framework. Chat rendering, command results, bot profiles, connections and routines also have one implementation. `App/Shell.swift` routes the shared workspace; `App/Platform/` owns the two navigation layouts and the few controls that need AppKit or UIKit, including keyboard handling in the command menu and native text selection for quotes. Add a new message type or server operation once; split the view only when the interaction differs by platform.

## Verification

The compatibility target is [Rakazo v0.12.0](https://github.com/elie222/rakazo/tree/v0.12.0), commit `8b3dcd596dedc63021d98373107ab06665b0ad41`. Choose an available simulator with `xcrun simctl list devices available`.

**Do not run the macOS UI test scheme in an active desktop session:** XCTest sends input to the logged-in desktop. Use a dedicated disposable macOS login/VM for Mac UI actions. The Mac build, model test below and iOS simulator tests do not need to drive Mac apps.

`bash Tools/test-chat-interactions.sh` checks hover controls on both sides of a conversation, replies, dropping files into the focused composer and sending a multiline message. It uses an offscreen Mac window, a private drag pasteboard, temporary files and an in-memory sample workspace. It does not need Accessibility permission or an account.

```sh
# A throwaway upstream release API, Postgres, and scripted worker; no production keys.
# Requires Docker, curl, jq and Xcode. The container port binds only to 127.0.0.1.
./Tools/with-upstream.sh xcodebuild -scheme RakazoNative \
  -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO \
  -only-testing:RakazoUITests/WorkspaceTests test

# Tablet layout, without a server.
xcodebuild -scheme RakazoNative -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:RakazoUITests/TabletTests -parallel-testing-enabled NO test

# Native transport and byte-for-byte attachment round trip, without a simulator.
mkdir -p .build
swiftc App/Models.swift App/Connection.swift Tools/ServerSmoke.swift -o .build/server-smoke
./Tools/with-upstream.sh .build/server-smoke

# Render the packaged avatar families and exercise all eight poses. --server also checks
# a live turn and reads back the settled Mac chat pixels against a disposable worker.
bash Tools/test-chat-activity.sh --server

# Switch between short and multi-screen histories and verify the newest bubble is painted.
# Also check mixed message formats and chat switching on a disposable release server.
# The fixture puts 510 background deliveries after a bot's saved conversation; no desktop input.
files=(App/*.swift App/Platform/*.swift)
swiftc -whole-module-optimization ${files:#App/RakazoApp.swift} Tools/ChatHistorySmoke.swift -o .build/chat-history-smoke
.build/chat-history-smoke
./Tools/with-upstream.sh --chat-history .build/chat-history-smoke --release-server

# Offline tests: no account, provider, Docker, device input or mounted environment file.
core=(App/{Models,Connection,Sample,SampleComputer,IntegrationLibrary,WorkspaceStore,PrivateSpace,MarketplaceCatalog,ManagedIntegrations,ManagedServers}.swift)
swiftc "${core[@]}" \
  Tools/SampleFlowSmoke.swift -o .build/sample-smoke
.build/sample-smoke App/sample-catalog.json

# Space creation, retry and selection: offline, then saved choices on the real local release.
swiftc "${core[@]}" \
  Tools/PrivateSpaceSmoke.swift -o .build/private-space-smoke
.build/private-space-smoke
./Tools/with-upstream.sh .build/private-space-smoke --release-server

# Native Mac layout and quick-connect state checks; zsh, no visible windows or desktop input.
out=.build/marketplace/native; mkdir -p "$out"; cp App/sample-catalog.json "$out/"
ditto Design/Marketplace-assets/Brandmarks "$out/Brandmarks"
files=(App/*.swift App/Platform/*.swift)
swiftc -whole-module-optimization ${files:#App/RakazoApp.swift} Tools/MarketRenderSmoke.swift -o "$out/market-render"
"$out/market-render" "$out"

# Real release API, disposable account: read the marketplace and verify MCP grant and revoke.
swiftc "${core[@]}" \
  Tools/IntegrationServerSmoke.swift -o .build/integration-server-smoke
./Tools/with-upstream.sh .build/integration-server-smoke

# Sample feature journeys on a disposable simulator; substitute its UUID.
xcodebuild -scheme RakazoNative -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -only-testing:RakazoUITests/WorkspaceTests/testSampleConnectionsAndServerAccess \
  -only-testing:RakazoUITests/WorkspaceTests/testSampleComputerTakeoverAndHostConsent \
  -only-testing:RakazoUITests/WorkspaceTests/testSampleConnectionRequestsFromChat \
  -only-testing:RakazoUITests/WorkspaceTests/testPrivateSpaceCancelCreateAndSelectTools \
  -parallel-testing-enabled NO test
```

The server-backed iPhone test signs in, creates a bot, sends a message, receives a worker reply without manual refresh, relaunches, and checks persisted history. The worker is upstream’s scripted test runtime, not a live commercial model. Set `RAKAZO_TEST_PORT` if the default loopback port is occupied. Test accounts and volumes are discarded on exit. No hosted account, paid provider, live OAuth grant, or outbound email delivery is required or verified by these tests.

The icon and avatar outlines derive from [Rakazo](https://github.com/elie222/rakazo). Upstream license and notice are in `ThirdParty/`. The Swift implementation has no external runtime package dependencies.
