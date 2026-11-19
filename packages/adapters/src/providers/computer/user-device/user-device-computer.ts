import { DEFAULT_COMPUTER_SCREEN } from "@rakazo/core";
import type { ComputerProviderDefinition } from "../../../computers/computer-provider-descriptor.js";

/** The kind of a bot's computer that is its owner's own paired device. */
export const USER_DEVICE_COMPUTER_KIND = "user-device";

/**
 * A bot that runs on its owner's paired computer. The run sandbox wires it to the device link;
 * it is never chosen as a deployment's provider.
 */
export const userDeviceComputer: ComputerProviderDefinition = {
  capabilities: {
    terminal: false,
    inPlaceUpdate: false,
    nativeShell: true,
    runsOnUserMachine: true,
    screen: DEFAULT_COMPUTER_SCREEN,
    serverHomeMount: "never",
    serverOwnsStoredTeamHome: false,
    storedHomeIsBackup: false,
    homeStaysOnMachine: true,
    ownerRunsOnly: true,
  },
  deployment: false,
  async create() {
    throw new Error("A bot reaches its owner's computer through the device link, not a setting");
  },
};
