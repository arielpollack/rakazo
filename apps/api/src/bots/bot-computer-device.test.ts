import type { Actor } from "@rakazo/contracts";
import { BOT_BUSY_ERROR_CODE } from "@rakazo/contracts";
import { ClientError } from "@rakazo/core";
import { describe, expect, it } from "vitest";
import type { RouterContext } from "../routes/context.js";
import { requireOwnDevice, setBotComputerDevice } from "./bot-computer-device.js";

const actor = { userId: "owner", spaceId: "space" } as Actor;

function context(activeRun: { id: string } | null) {
  const released: unknown[] = [];
  const ctx = {
    repos: {
      getBot: async () => ({ id: "bot", userId: "owner", computer: { deviceId: null } }),
    },
    deps: {
      prisma: {
        userDevice: { findFirst: async () => ({ id: "mac" }) },
        bot: {
          updateMany: async (args: unknown) => {
            released.push(args);
            return { count: 1 };
          },
        },
        run: { findFirst: async () => activeRun },
      },
    },
  } as unknown as Pick<RouterContext, "deps" | "repos">;
  return { ctx, released };
}

describe("moving a bot to its owner's computer", () => {
  it("refuses while the bot works or waits, with a code the app answers by offering to stop it", async () => {
    const { ctx, released } = context({ id: "run" });
    const refusal = await setBotComputerDevice(ctx, actor, { botId: "bot", deviceId: "mac" }).then(
      () => undefined,
      (error: unknown) => error,
    );
    expect(refusal).toBeInstanceOf(ClientError);
    expect(refusal).toMatchObject({ kind: "BAD_REQUEST", code: BOT_BUSY_ERROR_CODE });
    // The move's claim is released, so moving again after stopping is allowed.
    expect(released).toHaveLength(2);
  });

  it("creates a bot on a computer only when it is the person's own, still paired", async () => {
    const lookups: unknown[] = [];
    const deps = (found: { id: string } | null) =>
      ({
        prisma: {
          userDevice: {
            findFirst: async (args: unknown) => {
              lookups.push(args);
              return found;
            },
          },
        },
      }) as unknown as Pick<RouterContext["deps"], "prisma">;
    await expect(requireOwnDevice(deps({ id: "mac" }), actor, "mac")).resolves.toBeUndefined();
    await expect(requireOwnDevice(deps(null), actor, "other")).rejects.toMatchObject({
      kind: "NOT_FOUND",
    });
    expect(lookups[1]).toMatchObject({
      where: { id: "other", userId: "owner", revokedAt: null },
    });
  });
});
