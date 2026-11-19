import { USER_DEVICE_COMPUTER_KIND } from "@rakazo/adapters";
import type { Actor, Bot } from "@rakazo/contracts";
import { ACTIVE_RUN_STATUSES, ClientError, computerUsingRuns } from "@rakazo/core";
import { computerScopeKey, IsolationError, runAsSystem } from "@rakazo/db";
import type { RouterContext } from "../routes/context.js";

/**
 * Moves a bot between the server's computers and its owner's paired device. Only the owner can,
 * since the bot then runs commands on their machine; the bot must not be working meanwhile.
 */
export async function setBotComputerDevice(
  { deps, repos }: Pick<RouterContext, "deps" | "repos">,
  actor: Actor,
  input: { botId: string; deviceId: string | null },
): Promise<Bot> {
  const bot = await repos.getBot(actor, input.botId);
  if (!bot.computer) throw new IsolationError();
  if (bot.userId !== actor.userId)
    throw new ClientError("FORBIDDEN", "Only the bot's owner can choose where it runs");
  const current = bot.computer.deviceId ?? null;
  if (current === input.deviceId)
    return (await repos.listBots(actor)).find((entry) => entry.id === bot.id)!;
  if (input.deviceId) {
    const deviceId = input.deviceId;
    const device = await runAsSystem("check the computer a bot will run on", () =>
      deps.prisma.userDevice.findFirst({
        where: { id: deviceId, userId: actor.userId, revokedAt: null },
        select: { id: true },
      }),
    );
    if (!device) throw new ClientError("NOT_FOUND", "That computer is no longer connected");
  }
  const claimed = await deps.prisma.bot.updateMany({
    where: { id: bot.id, computerSwitching: false },
    data: { computerSwitching: true },
  });
  if (claimed.count !== 1) throw new ClientError("CONFLICT", "The bot is already moving");
  try {
    const active = await deps.prisma.run.findFirst({
      where: { botId: bot.id, status: { in: [...ACTIVE_RUN_STATUSES] }, ...computerUsingRuns() },
      select: { id: true },
    });
    if (active) throw new ClientError("BAD_REQUEST", "Stop the bot first");
    if (input.deviceId)
      return await repos.setBotComputerDevice(actor, bot.id, {
        id: input.deviceId,
        kind: USER_DEVICE_COMPUTER_KIND,
      });
    // Back to the server: the private computer it had there, otherwise the Space's.
    const dedicated = await deps.prisma.computer.findUnique({
      where: {
        scopeKey: computerScopeKey({
          mode: "dedicated",
          spaceId: actor.spaceId,
          userId: bot.userId,
          botId: bot.id,
        }),
      },
      select: { id: true },
    });
    return await repos.setBotComputer(
      actor,
      bot.id,
      dedicated ? "dedicated" : "team",
      deps.sandbox.describe().id,
    );
  } finally {
    await deps.prisma.bot.updateMany({ where: { id: bot.id }, data: { computerSwitching: false } });
  }
}
