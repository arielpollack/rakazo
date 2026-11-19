import type { PrismaClient } from "@rakazo/db";
import { describe, expect, it, vi } from "vitest";
import {
  CLAUDE_CODE_CATALOG_PROVIDER,
  CLAUDE_CODE_PROVIDER_ID,
} from "../../providers/cli-model/claude-code/provider-id.js";
import { listPiCatalog } from "../pi/models/pi-models.js";
import { deviceBotModels, deviceModelChoices, validateDeviceModelChange } from "./device-models.js";

const cliReady = vi.hoisted(() => ({ value: false }));
vi.mock("../../providers/cli-model/claude-code/cli.js", () => ({
  checkClaudeCode: async () => {
    if (!cliReady.value) throw new Error("not installed");
  },
}));

const { deviceModelProviders } = await import("./device-model-providers.js");

const cloud = "google-vertex";
const cloudModel = listPiCatalog().find((entry) => entry.provider === cloud)!;
const cliModel = listPiCatalog().find((entry) => entry.provider === CLAUDE_CODE_CATALOG_PROVIDER)!;

function devicePrisma(modelProviders: string[]) {
  return {
    userDevice: { findUnique: async () => ({ name: "Studio Mac", modelProviders }) },
  } as unknown as PrismaClient;
}

describe("models on a person's own computer", () => {
  it("offers the catalog of each provider the computer signs in to, and a CLI's models under its own id", () => {
    const choices = deviceModelChoices([cloud, CLAUDE_CODE_PROVIDER_ID]);
    expect(choices.some((entry) => entry.provider === cloud && entry.id === cloudModel.id)).toBe(
      true,
    );
    expect(
      choices.some(
        (entry) => entry.provider === CLAUDE_CODE_PROVIDER_ID && entry.id === cliModel.id,
      ),
    ).toBe(true);
    expect(choices.some((entry) => entry.provider === CLAUDE_CODE_CATALOG_PROVIDER)).toBe(false);
    expect(deviceModelChoices([])).toEqual([]);
  });

  it("puts a CLI signed in here first, and a bot without a model there uses its default", async () => {
    const prisma = devicePrisma([cloud, CLAUDE_CODE_PROVIDER_ID]);
    const choices = deviceModelChoices([cloud, CLAUDE_CODE_PROVIDER_ID]);
    expect(choices[0]?.provider).toBe(CLAUDE_CODE_PROVIDER_ID);

    const fresh = await deviceBotModels(prisma, "device-1", { provider: null, id: null });
    expect(fresh.current?.provider).toBe(CLAUDE_CODE_PROVIDER_ID);
    expect(fresh.deviceName).toBe("Studio Mac");

    const elsewhere = await deviceBotModels(prisma, "device-1", { provider: "x", id: "y" });
    expect(elsewhere.current).toEqual(fresh.current);

    const own = await deviceBotModels(prisma, "device-1", { provider: cloud, id: cloudModel.id });
    expect(own.current).toMatchObject({ provider: cloud, id: cloudModel.id });

    const none = await deviceBotModels(devicePrisma([]), "device-1", { provider: null, id: null });
    expect(none.current).toBeUndefined();
  });

  it("offers one form of each model where a provider routes it several ways", () => {
    const routed = "amazon-bedrock";
    const ids = deviceModelChoices([routed]).map((entry) => entry.id);
    const catalogIds = listPiCatalog()
      .filter((entry) => entry.provider === routed)
      .map((entry) => entry.id);
    const global = catalogIds.find((id) => id.startsWith("global."))!;
    const plain = global.slice("global.".length);
    expect(ids).toContain(global);
    expect(ids).not.toContain(plain);
    expect(ids.some((id) => /^(us|eu|apac|jp|au|ca|us-gov)\./.test(id))).toBe(false);
    // A model with no preferred form keeps its plain id.
    const plainOnly = catalogIds.find(
      (id) =>
        !/^(global|us|eu|apac|jp|au|ca|us-gov)\./.test(id) && !catalogIds.includes(`global.${id}`),
    );
    expect(plainOnly).toBeDefined();
    expect(ids).toContain(plainOnly);
  });

  it("allows only models the computer signs in to", async () => {
    const prisma = devicePrisma([cloud]);
    const current = { provider: null, model: null };
    await expect(
      validateDeviceModelChange(prisma, "device-1", {
        provider: cloud,
        model: cloudModel.id,
        current,
      }),
    ).resolves.toMatchObject({ ok: true, provider: cloud, model: cloudModel.id });
    await expect(
      validateDeviceModelChange(prisma, "device-1", {
        provider: CLAUDE_CODE_PROVIDER_ID,
        model: cliModel.id,
        current,
      }),
    ).resolves.toEqual({ ok: false, error: "That model isn't signed in on Studio Mac." });
    await expect(
      validateDeviceModelChange(prisma, "device-1", { provider: null, model: null, current }),
    ).resolves.toMatchObject({ ok: true });
  });

  it("keeps a bot's saved model when nothing about it changes", async () => {
    const saved = { provider: "elsewhere", model: "old" };
    await expect(
      validateDeviceModelChange(devicePrisma([]), "device-1", { ...saved, current: saved }),
    ).resolves.toMatchObject({ ok: true, provider: "elsewhere", model: "old" });
  });

  it("finds providers signed in through the environment and a signed-in CLI", async () => {
    const env = {
      GOOGLE_CLOUD_API_KEY: "placeholder",
      PATH: "/usr/bin",
    };
    cliReady.value = false;
    expect(await deviceModelProviders("/tmp", env)).toEqual([cloud]);
    cliReady.value = true;
    expect(await deviceModelProviders("/tmp", env)).toEqual([cloud, CLAUDE_CODE_PROVIDER_ID]);
    expect(await deviceModelProviders("/tmp", { PATH: "/usr/bin" })).not.toContain(cloud);
  });
});
