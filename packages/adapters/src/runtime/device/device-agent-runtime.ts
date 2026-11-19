import type { AgentRuntime } from "@rakazo/adapter-kit";
import { registerClaudeCodeProvider } from "../../providers/cli-model/claude-code/provider.js";
import { CLAUDE_CODE_PROVIDER_ID } from "../../providers/cli-model/claude-code/provider-id.js";
import { PiAgentRuntime } from "../pi/pi-runtime.js";
import { createRuntimeModels } from "../pi/pi-runtime-models.js";
import { withRuntimeModels } from "../pi/pi-runtime-scope.js";

export { deviceModelProviders } from "./device-model-providers.js";

/**
 * The runtime a person's own computer runs its bots' turns on: the server's Pi harness, calling
 * models with this computer's sign-ins. That includes coding CLIs signed in here, which the
 * server offers only to its operator; on their own computer every person is the operator.
 */
export function createDeviceAgentRuntime(options: { sessionRoot?: string } = {}): AgentRuntime {
  const pi = new PiAgentRuntime({ sessionRoot: options.sessionRoot });
  return {
    describe: () => pi.describe(),
    abort: (runId) => pi.abort(runId),
    run(request, context) {
      if (request.model.provider !== CLAUDE_CODE_PROVIDER_ID) return pi.run(request, context);
      const models = registerClaudeCodeProvider(createRuntimeModels(), {
        modelId: request.model.id,
        accessCheck: async () => undefined,
      });
      return withRuntimeModels(pi, models).run(request, context);
    },
  };
}
