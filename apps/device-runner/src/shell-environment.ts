import { spawn } from "node:child_process";

const READ_TIMEOUT_MS = 10_000;

/**
 * The environment a terminal on this computer would have. An app opened from the Dock starts
 * with almost none of it, yet model sign-ins (a cloud project, a CLI on PATH) live there.
 * Empty when the shell cannot be read in time.
 */
export function loginShellEnvironment(
  shell = process.env.SHELL || "/bin/zsh",
): Promise<Record<string, string>> {
  return new Promise((resolve) => {
    const child = spawn(shell, ["-l", "-i", "-c", "env -0"], {
      stdio: ["ignore", "pipe", "ignore"],
      env: { HOME: process.env.HOME ?? "", USER: process.env.USER ?? "", TERM: "dumb" },
    });
    const chunks: Buffer[] = [];
    const timer = setTimeout(() => child.kill("SIGKILL"), READ_TIMEOUT_MS);
    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
    child.on("error", () => {
      clearTimeout(timer);
      resolve({});
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        resolve({});
        return;
      }
      resolve(parseEnv(Buffer.concat(chunks).toString("utf8")));
    });
  });
}

/** `env -0` output: NUL-separated KEY=value pairs. */
export function parseEnv(output: string): Record<string, string> {
  const env: Record<string, string> = {};
  for (const entry of output.split("\0")) {
    const equals = entry.indexOf("=");
    if (equals > 0) env[entry.slice(0, equals)] = entry.slice(equals + 1);
  }
  return env;
}

/** Fills what this process lacks from the shell's; PATH is the shell's, which finds more. */
export function mergeShellEnvironment(
  target: NodeJS.ProcessEnv,
  shell: Record<string, string>,
): void {
  for (const [key, value] of Object.entries(shell)) {
    if (key === "PATH" || target[key] === undefined) target[key] = value;
  }
}
