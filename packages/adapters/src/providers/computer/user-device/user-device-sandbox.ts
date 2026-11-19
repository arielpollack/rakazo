import type { AdapterContext, ComputerRef } from "@rakazo/adapter-kit";
import { SandboxFileTooLargeError } from "@rakazo/adapter-kit";
import type { HostComputerRequest } from "../../../computers/host/host-computer-protocol.js";
import { hostComputerFileTooLargeLimit } from "../../../computers/host/host-computer-protocol.js";
import { HostComputerSandbox } from "../../../computers/host/host-computer-sandbox.js";
import { UserDeviceOfflineError } from "../../../computers/host/user-device-gateway.js";
import type { UserDeviceGateway } from "../../../computers/host/user-device-protocol.js";
import { USER_DEVICE_COMPUTER_KIND } from "./user-device-computer.js";

/** Whose device a computer's home runs on; null when the home is not on a device. */
export type UserDeviceHomeOwner = (
  homeKey: string,
) => Promise<{ userId: string; deviceId: string; deviceName: string } | null>;

/**
 * A bot's computer on its owner's paired device: the same requests the desktop host answers,
 * carried over the device link from whichever API or worker process runs the bot.
 */
export class UserDeviceSandbox extends HostComputerSandbox {
  constructor(
    private readonly devices: UserDeviceGateway,
    private readonly owner: UserDeviceHomeOwner,
  ) {
    super("", "");
  }

  override describe() {
    return { ...super.describe(), id: USER_DEVICE_COMPUTER_KIND };
  }

  protected override async *request<T>(
    input: HostComputerRequest,
    context: AdapterContext,
  ): AsyncIterable<T> {
    const owner = await this.owner(input.botId);
    if (!owner) throw new UserDeviceOfflineError("This bot no longer runs on a computer of yours.");
    try {
      yield* this.devices.request<T>(
        owner.userId,
        { ...input, runId: context.runId },
        context.signal,
        owner.deviceId,
      );
    } catch (error) {
      if (error instanceof UserDeviceOfflineError)
        throw new UserDeviceOfflineError(`${owner.deviceName} is offline.`, { cause: error });
      const maxBytes =
        error instanceof Error ? hostComputerFileTooLargeLimit(error.message) : undefined;
      if (maxBytes !== undefined) throw new SandboxFileTooLargeError(maxBytes);
      throw error;
    }
  }

  override async provision(input: { botId: string; homePath: string }, context: AdapterContext) {
    const ref = await super.provision(input, context);
    return { ...ref, kind: USER_DEVICE_COMPUTER_KIND } satisfies ComputerRef;
  }

  /** An offline device is not running; starting it again reports the device offline. */
  override async isRunning(computer: ComputerRef, context: AdapterContext) {
    try {
      return await super.isRunning(computer, context);
    } catch (error) {
      if (error instanceof UserDeviceOfflineError) return false;
      throw error;
    }
  }
}
