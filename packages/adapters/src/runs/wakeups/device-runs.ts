import type { JobPublisher } from "@rakazo/adapter-kit";
import type { PrismaClient } from "@rakazo/db";
import { runAsSystem } from "@rakazo/db";
import { wakeRun } from "./wake-run.js";

/** Starts the runs that waited for this device to connect: bots that run on it, queued and due. */
export async function wakeRunsWaitingForDevice(
  deps: { prisma: PrismaClient; jobs: Pick<JobPublisher, "enqueue"> },
  deviceId: string,
): Promise<void> {
  const now = new Date();
  // Called when a device connects, outside any request or job; waking a run writes to it too.
  await runAsSystem("start runs waiting for a user device", async () => {
    const runs = await deps.prisma.run.findMany({
      where: {
        status: "queued",
        bot: { computer: { deviceId } },
        OR: [{ wakeAt: null }, { wakeAt: { lte: now } }],
      },
      select: { id: true },
    });
    await Promise.all(runs.map((run) => wakeRun(deps.jobs, run.id)));
  });
}
