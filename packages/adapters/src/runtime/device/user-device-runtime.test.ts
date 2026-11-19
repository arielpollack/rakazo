import type { AgentRunRequest, AgentRuntime, AgentRuntimeEvent } from "@rakazo/adapter-kit";
import { deferred } from "@rakazo/core/test-async";
import { describe, expect, it, vi } from "vitest";
import { UserDeviceOfflineError } from "../../computers/host/user-device-gateway.js";
import type {
  UserDeviceAgentCall,
  UserDeviceAgentLink,
  UserDeviceAgentRun,
} from "../../computers/host/user-device-protocol.js";
import { runAgentOnDevice } from "./agent-run-wire.js";
import type { AgentRunPlacement } from "./user-device-runtime.js";
import { OWNER_ONLY_DEVICE_MESSAGE, UserDeviceAgentRuntime } from "./user-device-runtime.js";

const onDevice: AgentRunPlacement = async () => ({
  userId: "owner",
  deviceId: "mac",
  deviceName: "Studio Mac",
  ownerChat: true,
});

/** A device whose loop calls one tool, then asks with the secret in its detail. */
const deviceLoop: AgentRuntime = {
  describe: () => ({ id: "device-loop", capabilities: {} }) as ReturnType<AgentRuntime["describe"]>,
  abort: async () => undefined,
  async *run(request) {
    const result = await request.executeTool?.("shell", { command: "uname" }, "exec-1");
    yield { type: "text", text: `ran: ${JSON.stringify(result)}` };
    yield { type: "ask", text: "Use it?", detail: "token s3cret-value" };
  },
};

/** Runs the device side in-process, as the real link would carry it. */
function link(runtime: AgentRuntime, seen: UserDeviceAgentRun[] = []): UserDeviceAgentLink {
  return {
    async agentSession(_userId, _deviceId, run, signal) {
      seen.push(run);
      const replies = new Map<string, (outcome: { value?: unknown; error?: string }) => void>();
      const frames: Array<{ event: unknown } | { call: UserDeviceAgentCall }> = [];
      let wake = deferred();
      let finished = false;
      const push = (frame: (typeof frames)[number]) => {
        frames.push(frame);
        wake.resolve();
      };
      void (async () => {
        let next = 0;
        const events = runAgentOnDevice(runtime, run, {
          signal,
          call: (name, args) =>
            new Promise((resolve, reject) => {
              next += 1;
              const id = `call-${next}`;
              replies.set(id, (outcome) =>
                outcome.error ? reject(new Error(outcome.error)) : resolve(outcome.value),
              );
              push({ call: { id, name, args } });
            }),
        });
        for await (const event of events) push({ event });
        finished = true;
        wake.resolve();
      })();
      return {
        frames: (async function* () {
          while (true) {
            const frame = frames.shift();
            if (frame) {
              yield frame;
              continue;
            }
            if (finished) return;
            wake = deferred();
            await wake.promise;
          }
        })(),
        reply: async (callId, outcome) => replies.get(callId)?.(outcome),
      };
    },
  };
}

function request(overrides: Partial<AgentRunRequest> = {}): AgentRunRequest {
  return {
    botId: "bot",
    threadId: "thread",
    runId: "run",
    prompt: "hi",
    instructions: "be brief",
    history: [],
    tools: [],
    model: {
      provider: "google-vertex",
      id: "gemini",
      apiKey: "server-key",
      headers: { authorization: "server" },
      projectId: "project",
    },
    secrets: ["s3cret-value", "deployment-key"],
    executeTool: vi.fn(async () => ({ stdout: "Darwin" })),
    ...overrides,
  };
}

async function collect(events: AsyncIterable<AgentRuntimeEvent>) {
  const out: AgentRuntimeEvent[] = [];
  for await (const event of events) out.push(event);
  return out;
}

const server: AgentRuntime = {
  describe: () => ({ id: "server", capabilities: {} }) as ReturnType<AgentRuntime["describe"]>,
  abort: async () => undefined,
  async *run() {
    yield { type: "text", text: "from the server" };
  },
};

describe("turns of a bot on its owner's computer", () => {
  it("run on the device without the server's credentials, secrets or callbacks", async () => {
    const seen: UserDeviceAgentRun[] = [];
    const runtime = new UserDeviceAgentRuntime(server, link(deviceLoop, seen), onDevice);
    const turn = request();

    const events = await collect(runtime.run(turn));

    const sent = JSON.stringify(seen[0]);
    expect(sent).not.toContain("server-key");
    expect(sent).not.toContain("authorization");
    expect(sent).not.toContain("s3cret-value");
    expect(sent).not.toContain("deployment-key");
    expect(seen[0]?.request).toMatchObject({
      model: { provider: "google-vertex", id: "gemini", projectId: "project" },
      callbacks: ["executeTool"],
    });
    // The tool ran on the server's own request, and its result went back to the device loop.
    expect(turn.executeTool).toHaveBeenCalledWith(
      "shell",
      { command: "uname" },
      "exec-1",
      undefined,
    );
    expect(events).toEqual([
      { type: "text", text: 'ran: {"stdout":"Darwin"}' },
      { type: "ask", text: "Use it?", detail: "token [redacted]" },
    ]);
  });

  it("runs every other turn here", async () => {
    const runtime = new UserDeviceAgentRuntime(server, link(deviceLoop), async () => null);
    expect(await collect(runtime.run(request()))).toEqual([
      { type: "text", text: "from the server" },
    ]);
  });

  it("refuses a turn that is not its owner's own chat", async () => {
    const runtime = new UserDeviceAgentRuntime(server, link(deviceLoop), async () => ({
      ...(await onDevice("run"))!,
      ownerChat: false,
    }));
    await expect(collect(runtime.run(request()))).rejects.toThrow(OWNER_ONLY_DEVICE_MESSAGE);
  });

  it("names the computer when it is offline", async () => {
    const offline: UserDeviceAgentLink = {
      agentSession: async () => {
        throw new UserDeviceOfflineError();
      },
    };
    const runtime = new UserDeviceAgentRuntime(server, offline, onDevice);
    await expect(collect(runtime.run(request()))).rejects.toThrow("Studio Mac is offline.");
  });

  it("gives the device a failed tool's error, and the loop carries on", async () => {
    const turn = request({
      executeTool: vi.fn(async () => {
        throw new Error("permission denied");
      }),
    });
    const loop: AgentRuntime = {
      ...deviceLoop,
      async *run(device) {
        const outcome = await device
          .executeTool?.("shell", {}, "exec-1")
          .catch((error: Error) => `failed: ${error.message}`);
        yield { type: "text", text: String(outcome) };
      },
    };
    const events = await collect(
      new UserDeviceAgentRuntime(server, link(loop), onDevice).run(turn),
    );
    expect(events).toEqual([{ type: "text", text: "failed: permission denied" }]);
  });
});
