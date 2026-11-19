import type { PrismaClient } from "@rakazo/db";
import { describe, expect, it, vi } from "vitest";
import { findRunRecoveryBlockers } from "./run-recovery.js";

describe("run recovery blockers", () => {
  it("lets a background helper start while the bot's own turn holds the computer", async () => {
    const now = new Date();
    // A live turn's own lease, not a takeover hold.
    const expiresAt = new Date(now.getTime() + 60_000);
    const prisma = {
      computerExecutionLease: {
        findMany: vi.fn(async () => [
          { computerId: "computer", botId: "bot", runId: "chat-turn", expiresAt },
        ]),
      },
    } as unknown as PrismaClient;
    const run = (id: string, trigger: string) => ({
      id,
      botId: "bot",
      status: "queued",
      trigger,
      bot: { computerId: "computer" },
    });
    const blockers = await findRunRecoveryBlockers(
      prisma,
      [run("next-turn", "user"), run("helper", "helper")],
      now,
    );
    expect([...blockers]).toEqual([]);
  });

  it("holds queued runs of a bot whose computer is its owner's offline device", async () => {
    const prisma = {
      computerExecutionLease: { findMany: vi.fn(async () => []) },
      userDeviceConnection: { findMany: vi.fn(async () => [{ deviceId: "online-mac" }]) },
    } as unknown as PrismaClient;
    const run = (id: string, status: string, deviceId: string | null) => ({
      id,
      botId: id,
      status,
      trigger: "user",
      bot: { computerId: `computer-${id}`, computer: { deviceId } },
    });
    const blockers = await findRunRecoveryBlockers(
      prisma,
      [
        run("waits", "queued", "offline-mac"),
        run("starts", "queued", "online-mac"),
        run("server", "queued", null),
        // An expired lease is recovered; claiming it puts it back to wait for the device.
        run("expired", "running", "offline-mac"),
      ],
      new Date(),
    );
    expect([...blockers]).toEqual([["waits", null]]);
  });
});
