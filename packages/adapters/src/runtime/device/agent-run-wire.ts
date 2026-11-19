import type {
  AgentRunModel,
  AgentRunRequest,
  AgentRuntime,
  AgentRuntimeEvent,
} from "@rakazo/adapter-kit";
import type {
  UserDeviceAgentCall,
  UserDeviceAgentRun,
} from "../../computers/host/user-device-protocol.js";

/** The request callbacks a turn on a device reaches back to the server for. */
const CALLBACKS = [
  "executeTool",
  "onToolCompleted",
  "claimSteering",
  "onCheckpoint",
  "onModelChange",
  "resolveModel",
  "resolveFallbackModel",
  "onUsage",
] as const satisfies readonly UserDeviceAgentCall["name"][];

type WireRequest = Omit<
  AgentRunRequest,
  (typeof CALLBACKS)[number] | "secrets" | "yieldSignal" | "model" | "computerModel"
> & {
  model: AgentRunModel;
  computerModel?: AgentRunModel;
  /** Which callbacks the server's request has, so the device offers only those. */
  callbacks: Array<(typeof CALLBACKS)[number]>;
};

/**
 * The model as a device may see it: which model, never the server's credential for it. The
 * device calls the model with its own sign-in for that provider.
 */
export function deviceModel(model: AgentRunModel): AgentRunModel {
  const { apiKey, headers, accountId, gatewayId, callObserver, oauth, ...rest } = model;
  return rest;
}

/** A turn for a device: no callbacks, no secret values, no server model credentials. */
export function agentRunForDevice(request: AgentRunRequest): UserDeviceAgentRun {
  const {
    onUsage,
    executeTool,
    onToolCompleted,
    claimSteering,
    onCheckpoint,
    onModelChange,
    resolveModel,
    resolveFallbackModel,
    secrets,
    yieldSignal,
    model,
    computerModel,
    ...rest
  } = request;
  const present = {
    executeTool,
    onToolCompleted,
    claimSteering,
    onCheckpoint,
    onModelChange,
    resolveModel,
    resolveFallbackModel,
    onUsage,
  };
  const wire: WireRequest = {
    ...rest,
    model: deviceModel(model),
    ...(computerModel ? { computerModel: deviceModel(computerModel) } : {}),
    callbacks: CALLBACKS.filter((name) => present[name] !== undefined),
  };
  return {
    botId: request.botId,
    runId: request.runId,
    request: JSON.parse(JSON.stringify(wire)) as Record<string, unknown>,
  };
}

/** Runs one call a device's turn made, against the server's own request. */
export async function answerDeviceCall(
  request: AgentRunRequest,
  call: UserDeviceAgentCall,
): Promise<unknown> {
  const [a, b, c, d] = call.args as unknown[];
  switch (call.name) {
    case "executeTool": {
      if (!request.executeTool) throw new Error("This turn runs no tools");
      return request.executeTool(
        a as string,
        b as Record<string, unknown>,
        c as string,
        (d ?? undefined) as Parameters<NonNullable<AgentRunRequest["executeTool"]>>[3],
      );
    }
    case "onToolCompleted":
      await request.onToolCompleted?.(
        a as Parameters<NonNullable<AgentRunRequest["onToolCompleted"]>>[0],
      );
      return null;
    case "claimSteering":
      return (await request.claimSteering?.(a as string[])) ?? [];
    case "onCheckpoint":
      await request.onCheckpoint?.(() => a as string, b as string);
      return null;
    case "onModelChange":
      await request.onModelChange?.(a as string, b as string, c as boolean | undefined);
      return null;
    case "resolveModel": {
      if (!request.resolveModel) throw new Error("This turn cannot change its model");
      return deviceModel(await request.resolveModel(a as string, b as string));
    }
    case "resolveFallbackModel": {
      if (!request.resolveFallbackModel) throw new Error("This turn has no backup model");
      return deviceModel(
        await request.resolveFallbackModel(a as string, b as string, (c ?? undefined) as string),
      );
    }
    case "onUsage":
      await request.onUsage?.(a as Parameters<NonNullable<AgentRunRequest["onUsage"]>>[0]);
      return null;
  }
}

/** Plain JSON for a value crossing to the server: an Error keeps only its message. */
function wireValue(value: unknown): unknown {
  if (value instanceof Error) return { message: value.message };
  return value;
}

/**
 * Runs a turn the server sent, here on the device: the loop and the model run locally, and each
 * callback the server's request had becomes a call back to the server.
 */
export function runAgentOnDevice(
  runtime: AgentRuntime,
  run: UserDeviceAgentRun,
  bridge: {
    call(name: UserDeviceAgentCall["name"], args: unknown[]): Promise<unknown>;
    signal: AbortSignal;
  },
): AsyncIterable<AgentRuntimeEvent> {
  const sent: Record<string, unknown> = run.request;
  const { callbacks, ...wire } = sent as unknown as WireRequest;
  const has = new Set(callbacks);
  const call = (name: UserDeviceAgentCall["name"], args: unknown[]) =>
    bridge.call(name, args.map(wireValue));
  const request: AgentRunRequest = {
    ...wire,
    ...(has.has("executeTool")
      ? {
          executeTool: (name, args, executionId, route) =>
            call("executeTool", [name, args, executionId, route ?? null]),
        }
      : {}),
    ...(has.has("onToolCompleted")
      ? {
          onToolCompleted: async (completion) => {
            await call("onToolCompleted", [{ ...completion, error: wireValue(completion.error) }]);
          },
        }
      : {}),
    ...(has.has("claimSteering")
      ? {
          claimSteering: async (seenIds) =>
            (await call("claimSteering", [seenIds])) as Awaited<
              ReturnType<NonNullable<AgentRunRequest["claimSteering"]>>
            >,
        }
      : {}),
    ...(has.has("onCheckpoint")
      ? {
          onCheckpoint: async (capture, executionId) => {
            await call("onCheckpoint", [capture(), executionId]);
          },
        }
      : {}),
    ...(has.has("onModelChange")
      ? {
          onModelChange: async (provider, modelId, computerMode) => {
            await call("onModelChange", [provider, modelId, computerMode ?? null]);
          },
        }
      : {}),
    ...(has.has("resolveModel")
      ? {
          resolveModel: async (provider, modelId) =>
            (await call("resolveModel", [provider, modelId])) as AgentRunModel,
        }
      : {}),
    ...(has.has("resolveFallbackModel")
      ? {
          resolveFallbackModel: async (provider, modelId, connectionId) =>
            (await call("resolveFallbackModel", [
              provider,
              modelId,
              connectionId ?? null,
            ])) as AgentRunModel,
        }
      : {}),
    ...(has.has("onUsage")
      ? {
          onUsage: async (event) => {
            await call("onUsage", [event]);
          },
        }
      : {}),
  };
  return runtime.run(request, { signal: bridge.signal, runId: run.runId, botId: run.botId });
}
