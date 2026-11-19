import type { PrismaClient } from "@rakazo/db";
import { runAsSystem } from "@rakazo/db";
import { modelProviderDefinition } from "../../models/model-provider-registry.js";
import type { BotModelChangeResult } from "../../models/model-selection.js";
import {
  CLAUDE_CODE_CATALOG_PROVIDER,
  CLAUDE_CODE_PROVIDER_ID,
  CLAUDE_CODE_PROVIDER_NAME,
} from "../../providers/cli-model/claude-code/provider-id.js";
import type { PiCatalogEntry } from "../pi/models/pi-models.js";
import { hiddenCatalogModel, listPiCatalog } from "../pi/models/pi-models.js";

export interface DeviceModelChoice {
  provider: string;
  providerName: string;
  id: string;
  label: string;
  recommended: boolean;
  thinkingLevels: string[];
}

/** Coding CLIs a computer can sign in to, and the catalog whose model ids they take. */
const CLI_PROVIDERS = [
  {
    id: CLAUDE_CODE_PROVIDER_ID,
    name: CLAUDE_CODE_PROVIDER_NAME,
    catalog: CLAUDE_CODE_CATALOG_PROVIDER,
  },
];

/** The models a bot on a computer can use, from the providers that computer reported. */
export function deviceModelChoices(providers: readonly string[]): DeviceModelChoice[] {
  const reported = new Set(providers);
  const catalog = listPiCatalog().filter((entry) => !hiddenCatalogModel(entry));
  const choice = (entry: PiCatalogEntry, provider: string, providerName: string) => ({
    provider,
    providerName,
    id: entry.id,
    label: entry.label,
    recommended: Boolean(entry.recommended),
    thinkingLevels: [...(entry.thinkingLevels ?? [])],
  });
  // A coding CLI signed in here is the person's own setup, so it comes first and is the default.
  const choices: DeviceModelChoice[] = [];
  for (const cli of CLI_PROVIDERS) {
    if (!reported.has(cli.id)) continue;
    for (const entry of catalog)
      if (entry.provider === cli.catalog) choices.push(choice(entry, cli.id, cli.name));
  }
  for (const entry of catalog)
    if (reported.has(entry.provider) && preferredForm(entry, catalog))
      choices.push(choice(entry, entry.provider, entry.providerName));
  return choices;
}

/** One id per model where a provider names it several ways: the preferred route, else the plain id. */
function preferredForm(entry: PiCatalogEntry, catalog: readonly PiCatalogEntry[]): boolean {
  const routes = modelProviderDefinition(entry.provider)?.routingPrefixes;
  if (!routes) return true;
  if (entry.id.startsWith(routes.preferred)) return true;
  if (routes.others.some((prefix) => entry.id.startsWith(prefix))) return false;
  const preferred = routes.preferred + entry.id;
  return !catalog.some((other) => other.provider === entry.provider && other.id === preferred);
}

/** Why a turn on the device cannot start: it reported no model it signs in to. */
export function deviceSignedOutMessage(deviceName: string): string {
  return `${deviceName} isn't signed in to any model.`;
}

/** What a bot on the device uses when it has no model of its own there: the first recommended. */
export function deviceDefaultModel(
  choices: readonly DeviceModelChoice[],
): DeviceModelChoice | undefined {
  return choices.find((entry) => entry.recommended) ?? choices[0];
}

async function reportedDevice(prisma: PrismaClient, deviceId: string) {
  return runAsSystem("read a computer's model providers", () =>
    prisma.userDevice.findUnique({
      where: { id: deviceId },
      select: { name: true, modelProviders: true },
    }),
  );
}

/**
 * The models a bot whose computer is this paired device can use, and the one its next turn
 * uses: its own model when the device signs in to it, otherwise the device's default.
 */
export async function deviceBotModels(
  prisma: PrismaClient,
  deviceId: string,
  own: { provider: string | null; id: string | null },
): Promise<{ deviceName: string; models: DeviceModelChoice[]; current?: DeviceModelChoice }> {
  const device = await reportedDevice(prisma, deviceId);
  const models = deviceModelChoices(device?.modelProviders ?? []);
  const current =
    models.find((entry) => entry.provider === own.provider && entry.id === own.id) ??
    deviceDefaultModel(models);
  return { deviceName: device?.name ?? "This computer", models, current };
}

/**
 * The rules for changing the model of a bot that runs on a paired device: the device calls the
 * model with its own sign-ins, so only models it reported signing in to are allowed.
 */
export async function validateDeviceModelChange(
  prisma: PrismaClient,
  deviceId: string,
  input: {
    provider: string | null;
    model: string | null;
    thinkingLevel?: string | null;
    current?: { provider: string | null; model: string | null };
  },
): Promise<BotModelChangeResult> {
  const { provider, model } = input;
  const thinkingLevel = input.thinkingLevel ?? null;
  const changing = provider !== input.current?.provider || model !== input.current?.model;
  if (!changing && !thinkingLevel) return { ok: true, provider, model, thinkingLevel };
  const device = await reportedDevice(prisma, deviceId);
  const choice =
    provider && model
      ? deviceModelChoices(device?.modelProviders ?? []).find(
          (entry) => entry.provider === provider && entry.id === model,
        )
      : undefined;
  if (!choice) {
    if (!changing) return { ok: true, provider, model, thinkingLevel };
    return {
      ok: false,
      error: `That model isn't signed in on ${device?.name ?? "this computer"}.`,
    };
  }
  if (thinkingLevel && !choice.thinkingLevels.includes(thinkingLevel))
    return { ok: false, error: "Unsupported thinking level" };
  return { ok: true, provider, model, thinkingLevel };
}
