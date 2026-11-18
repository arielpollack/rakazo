# Integrations marketplace · design review

[Try the quick-connect prototype](Marketplace-preview.html) · [Review PDF](Marketplace-review.pdf) · [Original dialog pixels](Marketplace-assets/rakazo-0.12-installed-renderer.png)

The approved gallery and quick-connect flow are implemented in the native Mac target. Compare **01** (original) with **02** (approved gallery). **08** follows a direct connection from the card through provider confirmation, cancellation or retry. **04** shows the optional Slack detail. **03** is dark appearance, **05** shows compact search, **06** is accounts and server health, and **07** is MCP browsing. The HTML prototype remains an offline design reference; it never contacts providers or saves credentials.

## What is worth showing?

| Public directory reviewed | What it shows while browsing | Decision for Rakazo |
| --- | --- | --- |
| [Linear Integrations](https://linear.app/integrations) | Workflow categories; a listing links to details and pairs its name with a publisher and a specific job. | Link the provider name to its detail. Describe what the bot can do; show authorship only when the source supplies it. |
| [Notion Connections](https://www.notion.com/connections) | Connection type, purpose, developer, and sometimes ratings and usage. Type and category are separate filters. | Distinguish Apps, Plugins and MCP servers from categories like Communication and Design. Do not invent ratings or popularity. |
| [Vercel Marketplace](https://vercel.com/marketplace) | A few featured entries lead with a category and a use case. The directory separates native and external integrations. | Spotlight one concrete workflow. Keep all categories searchable rather than making the spotlight a prerequisite. |

## Proposed interaction

- **Discover:** search across names, providers, and descriptions. Choosing a type narrows results; category is a separate filter. Hide the spotlight while searching. At narrower widths, collapse the collection sidebar into a navigation button and reduce the column count rather than shrinking text.
- **Two paths on a card:** the entire card opens details, including its padding, logo, description and connected status. The separate setup button starts **Connect Slack**, **Install Figma** or **Add Asana server** without opening details. Hover tints the surface and strengthens the border; keyboard focus outlines the same surface. Neither action depends on hover.
- **Authorization:** both entry points use the same provider flow and state. A card action skips the listing, not consent or required configuration. Replace its button with **Waiting for Slack…** while pending; disable repeated attempts. Cancel restores the button, failure leaves a retry, and only a confirmed account becomes **Connected**. In every case preserve catalog filters, scroll and focus. No bot grant or computer access is implied.
- **Optional exploration:** details include sample tools, an example prompt and the same action if still available. Back returns focus to the card. Cancelling setup returns focus to its button; after successful setup the card announces its status and takes focus. Keyboard order on an available card is details, then setup.
- **My integrations:** connected app accounts are separate from configured servers. An account can be healthy even when a server for the same provider needs repair. Each status has text and a symbol; server details are where to repair, reconnect, or manage assignments. Empty accounts link back to Discover; empty search offers Clear filters.
- **Native Mac:** system font and semantic colors, type-to-search, adaptive columns, and separately labeled detail and setup controls. Connection status is announced after refreshing workspace data. The design’s bot-template and add-custom shortcuts are not part of this marketplace release.

## Evidence and artwork

The before image is the **unmodified renderer shipped with Rakazo Desktop 0.12.0**, rendered against a disposable local workspace. The catalog and the two connected accounts are fixtures; this is not a capture of a personal session. The [matching release source](https://github.com/elie222/rakazo/blob/8b3dcd596dedc63021d98373107ab06665b0ad41/apps/web/src/pages/PluginsOverlay.tsx) supplies the baseline navigation and feature structure. The featured GitHub release workflow and the account/server states come from the Rakazo sample data. Slack’s tool examples are based on identifiers in the release source, not a live account or an exhaustive list of permissions.

The proposal uses recognizable provider marks from the [pinned SVG collection](https://github.com/gilbarbara/logos/tree/b9edc65f8946027cb5e2fe6c772e914cf3649fba/logos): the flat Google marks, Slack, GitHub, Notion, Figma, Linear, and Asana. The [board assets](Marketplace-assets/Brandmarks) preserve the SVG viewboxes and include transparent margins. GitHub and Linear have single-color dark-appearance variants. No app-icon mask, colored tile, or cover crop is applied. Provider trademarks belong to their respective owners.

For the next Rakazo screen: capture the shipping UI, put it beside the proposed Mac flow in Pencil, and obtain design approval before changing Swift. Then compare the implemented screen against the approved frames.
