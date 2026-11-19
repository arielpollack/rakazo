import type { BackgroundJob } from "@rakazo/adapter-kit";
import type { PrismaClient } from "@rakazo/db";
import { currentDbContext } from "@rakazo/db";
import { describe, expect, it, vi } from "vitest";
import { wakeRunsWaitingForDevice } from "./device-runs.js";

describe("runs waiting for a device", () => {
  it("starts the due queued runs of bots on the device that connected", async () => {
    const findMany = vi.fn(async () => [{ id: "run-1" }, { id: "run-2" }]);
    // Waking a run writes to it, so it needs a database context; a connecting device has none.
    const contexts: Array<string | undefined> = [];
    const enqueue = vi.fn(async (_job: BackgroundJob) => {
      contexts.push(currentDbContext()?.kind);
    });
    const prisma = { run: { findMany } } as unknown as PrismaClient;

    await wakeRunsWaitingForDevice({ prisma, jobs: { enqueue } }, "device-1");

    expect(findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          status: "queued",
          bot: { computer: { deviceId: "device-1" } },
        }),
      }),
    );
    expect(enqueue.mock.calls.map(([job]) => job.payload)).toEqual([
      { runId: "run-1" },
      { runId: "run-2" },
    ]);
    expect(contexts).toEqual(["system", "system"]);
  });
});
