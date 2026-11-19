import { z } from "zod";
import type { HostComputerRequest } from "./host-computer-protocol.js";
import { hostComputerRequest } from "./host-computer-protocol.js";

export const userDeviceRevokeReason = z.enum(["session-ended"]);
/** Carries the revoke reason on a refused connection, which has no message to put it in. */
export const USER_DEVICE_REVOKED_HEADER = "x-rakazo-device-revoked";
export type UserDeviceRevokeReason = z.infer<typeof userDeviceRevokeReason>;

/**
 * The model providers a computer signs in to by itself, comma-separated, sent with every connect
 * so the server never sees it online without them. Empty means none; absent leaves them as they were.
 */
export const USER_DEVICE_MODELS_HEADER = "x-rakazo-device-models";
const modelProviders = z
  .string()
  .max(4096)
  .transform((value) => [...new Set(value.split(",").filter(Boolean))])
  .pipe(z.array(z.string().max(64)).max(64));

/** What a connect said about its model providers; undefined when it said nothing usable. */
export function deviceModelProvidersHeader(value: string | string[] | undefined) {
  return modelProviders.safeParse(value).data;
}

const messageId = z.string().min(1).max(64);

/**
 * One agent turn for a bot that runs on the device: the turn's request without its callbacks,
 * secrets or the server's model credentials. The device runs the loop and the model itself.
 */
export const userDeviceAgentRun = z.object({
  botId: z.string().min(1).max(256),
  runId: z.string().min(1).max(256),
  request: z.record(z.string(), z.unknown()),
});
export type UserDeviceAgentRun = z.infer<typeof userDeviceAgentRun>;

/** What a turn on the device asks the server to do: run a tool, save a checkpoint, and so on. */
export const userDeviceAgentCall = z.object({
  id: z.string().min(1).max(64),
  name: z.enum([
    "executeTool",
    "onToolCompleted",
    "claimSteering",
    "onCheckpoint",
    "onModelChange",
    "resolveModel",
    "resolveFallbackModel",
    "onUsage",
  ]),
  args: z.array(z.unknown()).max(8),
});
export type UserDeviceAgentCall = z.infer<typeof userDeviceAgentCall>;

export const userDeviceServerMessage = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("request"),
    id: messageId,
    request: hostComputerRequest,
  }),
  z.object({ type: z.literal("agent"), id: messageId, run: userDeviceAgentRun }),
  /** The server's answer to one call an agent turn made. */
  z.object({
    type: z.literal("reply"),
    id: messageId,
    callId: z.string().min(1).max(64),
    value: z.unknown().optional(),
    error: z.string().optional(),
  }),
  z.object({ type: z.literal("cancel"), id: messageId }),
  // "session-ended": the sign-in that paired it ended, so the next sign-in pairs again.
  z.object({ type: z.literal("revoked"), reason: userDeviceRevokeReason.optional() }),
]);

/**
 * One HostComputerFrame per message, tagged with the request id. An agent turn also sends
 * `{ call: UserDeviceAgentCall }` frames, each answered by a `reply` message.
 */
export const userDeviceClientMessage = z.discriminatedUnion("type", [
  z.object({ type: z.literal("frame"), id: z.string().min(1).max(64), frame: z.unknown() }),
]);
export type UserDeviceClientMessage = z.infer<typeof userDeviceClientMessage>;

export interface UserDevice {
  deviceId: string;
  name: string;
  platform: string;
  /** Only its screen is offered: commands there already run as the bot's own computer. */
  screenOnly?: boolean;
}

/** How runs reach the requesting user's connected device, from any API or worker process. */
export interface UserDeviceGateway {
  connected(userId: string): Promise<UserDevice | null>;
  /** When the oldest device still paired was paired, connected or not; null when none is. */
  pairedSince(userId: string): Promise<Date | null>;
  /**
   * Streams HostComputerFrame values for one request. Throws when the device is offline,
   * revoked, or disconnects mid-request; a command is never retried after a lost response.
   * Pass `deviceId` to keep every request of one operation on the same computer.
   */
  request<T>(
    userId: string,
    request: HostComputerRequest,
    signal: AbortSignal,
    deviceId?: string,
  ): AsyncIterable<T>;
}

/** One agent turn running on a device: what it streams, and how the server answers its calls. */
export interface UserDeviceAgentSession {
  frames: AsyncIterable<{ event: unknown } | { call: UserDeviceAgentCall }>;
  reply(callId: string, outcome: { value?: unknown; error?: string }): Promise<void>;
}

/** Runs agent turns on a user's device, from any API or worker process. */
export interface UserDeviceAgentLink {
  agentSession(
    userId: string,
    deviceId: string,
    run: UserDeviceAgentRun,
    signal: AbortSignal,
  ): Promise<UserDeviceAgentSession>;
}
