/**
 * The official Claude Code CLI on the server's own host, signed in by the operator with
 * `claude auth login`. Kept apart from the provider so the deployment model can name it
 * without loading the CLI bridge.
 */
export const CLAUDE_CODE_PROVIDER_ID = "claude-code";

export const CLAUDE_CODE_PROVIDER_NAME = "Claude Code";

/** The CLI takes this catalog provider's model ids, so its cards describe the CLI's models. */
export const CLAUDE_CODE_CATALOG_PROVIDER = "anthropic";

/** What the deployment's host credentials are, for the existing "Uses this server's own …" line. */
export const CLAUDE_CODE_CREDENTIAL_SOURCE = "CLI";
