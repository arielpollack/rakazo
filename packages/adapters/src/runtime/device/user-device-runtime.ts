import type {
  AdapterContext,
  AgentRunRequest,
  AgentRuntime,
  AgentRuntimeEvent,
} from "@rakazo/adapter-kit";
import { redactSecrets } from "@rakazo/core";
import type { PrismaClient } from "@rakazo/db";
import { runAsSystem } from "@rakazo/db";
import { bestEffort } from "@rakazo/logging";
import { UserDeviceOfflineError } from "../../computers/host/user-device-gateway.js";
import type { UserDeviceAgentLink } from "../../computers/host/user-device-protocol.js";
import { agentRunForDevice, answerDeviceCall } from "./agent-run-wire.js";

export const OWNER_ONLY_DEVICE_MESSAGE =
  "This bot works on its owner's own computer, so it works only in their own chats.";

/** A run its owner started by writing in the bot's own chat, not a channel, routine or bot. */
export function ownerChatRun(run: { trigger: string; userId: string }, botUserId: string) {
  return (run.trigger === "user" || run.trigger === "follow_up") && run.userId === botUserId;
}

/** The owner's device a run's turns go to, or null when they run here. */
export type AgentRunPlacement = (runId: string) => Promise<{
  userId: string;
  deviceId: string;
  deviceName: string;
  ownerChat: boolean;
} | null>;

export function userDeviceAgentPlacement(prisma: PrismaClient): AgentRunPlacement {
  return async (runId) => {
    const run = await runAsSystem("find where a run's turns run", () =>
      prisma.run.findUnique({
        where: { id: runId },
        select: {
          trigger: true,
          userId: true,
          bot: {
            select: {
              userId: true,
              computer: { select: { deviceId: true, device: { select: { name: true } } } },
            },
          },
        },
      }),
    );
    const computer = run?.bot.computer;
    if (!run || !computer?.deviceId || !computer.device) return null;
    return {
      userId: run.bot.userId,
      deviceId: computer.deviceId,
      deviceName: computer.device.name,
      ownerChat: ownerChatRun(run, run.bot.userId),
    };
  };
}

/**
 * Runs a bot's turns on its owner's device when the bot lives there: the device runs the whole
 * agent loop and calls the model itself, and reaches back here only for what the server holds
 * (tools over server data, steering, checkpoints, usage). Every other turn runs here.
 */
export class UserDeviceAgentRuntime implements AgentRuntime {
  private readonly running = new Map<string, AbortController>();

  constructor(
    private readonly inner: AgentRuntime,
    private readonly devices: UserDeviceAgentLink,
    private readonly placement: AgentRunPlacement,
  ) {}

  describe() {
    return this.inner.describe();
  }

  async abort(runId: string): Promise<void> {
    this.running.get(runId)?.abort(new Error("Stopped"));
    await this.inner.abort(runId);
  }

  async *run(
    request: AgentRunRequest,
    context: Partial<AdapterContext> = {},
  ): AsyncIterable<AgentRuntimeEvent> {
    const placed = await this.placement(request.runId);
    if (!placed) {
      yield* this.inner.run(request, context);
      return;
    }
    if (!placed.ownerChat) throw new Error(OWNER_ONLY_DEVICE_MESSAGE);
    const controller = new AbortController();
    this.running.set(request.runId, controller);
    const signal = context.signal
      ? AbortSignal.any([context.signal, controller.signal])
      : controller.signal;
    const secrets = request.secrets?.filter(Boolean) ?? [];
    try {
      const session = await this.devices
        .agentSession(placed.userId, placed.deviceId, agentRunForDevice(request), signal)
        .catch((error: unknown) => {
          if (error instanceof UserDeviceOfflineError)
            throw new UserDeviceOfflineError(`${placed.deviceName} is offline.`, { cause: error });
          throw error;
        });
      for await (const frame of session.frames) {
        if ("call" in frame) {
          const { call } = frame;
          // Calls run beside the stream: a long tool must not hold up the turn's events.
          void bestEffort(
            "answer a call from a turn on a computer",
            answerDeviceCall(request, call).then(
              (value) => session.reply(call.id, { value: value ?? null }),
              (error: unknown) =>
                session.reply(call.id, {
                  error: error instanceof Error ? error.message : String(error),
                }),
            ),
          );
          continue;
        }
        yield redactEvent(frame.event as AgentRuntimeEvent, secrets);
      }
    } finally {
      this.running.delete(request.runId);
    }
  }
}

/** The device never sees the run's secret values, so what it asks is redacted here. */
function redactEvent(event: AgentRuntimeEvent, secrets: readonly string[]): AgentRuntimeEvent {
  if (!secrets.length) return event;
  if (event.type === "ask")
    return {
      ...event,
      text: redactSecrets(event.text, secrets),
      ...(event.detail !== undefined ? { detail: redactSecrets(event.detail, secrets) } : {}),
    };
  if (event.type === "takeover") return { ...event, reason: redactSecrets(event.reason, secrets) };
  return event;
}
