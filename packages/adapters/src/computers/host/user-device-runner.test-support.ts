import type { HostComputerFrame } from "./host-computer-protocol.js";
import { createHostComputerRunner } from "./host-computer-runner.js";
import type { UserDeviceGateway } from "./user-device-protocol.js";

/**
 * A paired computer for tests: requests reach the real host runner the desktop app answers with,
 * in this process, so the wire values are the ones a device sends.
 */
export function runnerUserDeviceGateway(root: string): UserDeviceGateway {
  const runner = createHostComputerRunner({ root });
  runner.setEnabled(true);
  return {
    async connected() {
      return { deviceId: "runner-device", name: "Runner Mac", platform: process.platform };
    },
    async pairedSince() {
      return new Date(0);
    },
    async *request<T>(_userId: string, request: unknown, signal: AbortSignal): AsyncIterable<T> {
      const call = runner.begin();
      if (!call) throw new Error("runner busy");
      const frames: HostComputerFrame<T>[] = [];
      const abort = () => call.abort();
      signal.addEventListener("abort", abort, { once: true });
      try {
        const outcome = await call.run(request, {
          open() {},
          write(frame) {
            frames.push(frame as HostComputerFrame<T>);
          },
        });
        if (outcome !== "finished") throw new Error(`runner ${outcome}`);
      } finally {
        call.end();
        signal.removeEventListener("abort", abort);
      }
      for (const frame of frames) {
        if ("error" in frame) throw new Error(frame.error);
        if ("heartbeat" in frame) continue;
        if ("done" in frame) return;
        yield frame.value;
      }
      throw new Error("runner ended without a done frame");
    },
  };
}
