import { getEnvApiKey } from "@earendil-works/pi-ai/compat";
import { checkClaudeCode } from "../../providers/cli-model/claude-code/cli.js";
import { CLAUDE_CODE_PROVIDER_ID } from "../../providers/cli-model/claude-code/provider-id.js";
import { listPiCatalog } from "../pi/models/pi-models.js";

/**
 * The model providers this computer can call with its own sign-ins: a key or a cloud sign-in in
 * its environment, or a coding CLI signed in here. Runs on the person's computer.
 */
export async function deviceModelProviders(
  cwd: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<string[]> {
  const values = Object.fromEntries(
    Object.entries(env).filter((pair): pair is [string, string] => pair[1] !== undefined),
  );
  const catalog = new Set(listPiCatalog().map((entry) => entry.provider));
  const signedIn = [...catalog].filter((provider) => getEnvApiKey(provider, values) !== undefined);
  const cli = await checkClaudeCode(cwd).then(
    () => true,
    () => false,
  );
  return cli ? [...signedIn, CLAUDE_CODE_PROVIDER_ID] : signedIn;
}
