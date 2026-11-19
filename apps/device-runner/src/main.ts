// Runs on a person's own computer, started by the Rakazo app. It keeps the device link to their
// server open, runs the commands bots send, and runs the whole turn of bots that live here.
// The app writes one JSON line on stdin, { serverUrl, token, root }, and keeps stdin open:
// when it closes, the app is gone and so is this process.
import { createInterface } from "node:readline";
import {
  createDeviceAgentRuntime,
  deviceModelProviders,
} from "@rakazo/adapters/device-agent-runtime";
import { startUserDeviceClient } from "@rakazo/adapters/user-device-client";
import { z } from "zod";
import { loginShellEnvironment, mergeShellEnvironment } from "./shell-environment.js";

const config = z.object({
  serverUrl: z.string().url(),
  token: z.string().min(1),
  root: z.string().min(1),
});

/** One line to the app; it reads these to show state. */
function report(line: string) {
  process.stdout.write(`${line}\n`);
}

const lines = createInterface({ input: process.stdin });
const first = await new Promise<string | undefined>((resolve) => {
  lines.once("line", resolve);
  lines.once("close", () => resolve(undefined));
});
const parsed = config.safeParse(first ? JSON.parse(first) : undefined);
if (!parsed.success) {
  report("error invalid configuration");
  process.exit(2);
}

mergeShellEnvironment(process.env, await loginShellEnvironment());

const client = startUserDeviceClient({
  serverUrl: parsed.data.serverUrl,
  token: parsed.data.token,
  root: parsed.data.root,
  // The app starts this only while the person allows bots to use this computer.
  authorize: async () => true,
  agent: createDeviceAgentRuntime(),
  modelProviders: () => deviceModelProviders(parsed.data.root),
  onRevoked: (reason) => {
    report(`revoked ${reason ?? ""}`.trim());
    process.exit(3);
  },
});
report("started");

const stop = () => {
  client.close();
  process.exit(0);
};
lines.on("close", stop);
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
