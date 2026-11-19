import type {
  AdapterContext,
  CommandRequest,
  ComputerActionRequest,
  ComputerInput,
  ComputerRef,
  ControlLeaseRef,
  PortableFile,
  ProcessEvent,
  SandboxProvider,
  ScreenRequest,
  TerminalRequest,
  UnreferencedMachine,
  WorkspaceDirectoryRequest,
  WorkspaceExportLimits,
} from "@rakazo/adapter-kit";
import type { PrismaClient } from "@rakazo/db";
import { runAsSystem } from "@rakazo/db";
import { USER_DEVICE_COMPUTER_KIND } from "../../providers/computer/user-device/user-device-computer.js";
import type { UserDeviceHomeOwner } from "../../providers/computer/user-device/user-device-sandbox.js";
import { UserDeviceSandbox } from "../../providers/computer/user-device/user-device-sandbox.js";
import { cancelComputerRunWork, providerKeepsHome } from "../computer-idle.js";
import { manageComputerWorkspaceDirectories } from "../computer-workspace.js";
import type { UserDeviceGateway } from "../host/user-device-protocol.js";

/** The deployment's sandbox inside a device router, for code that needs the configured one. */
export function routedSandboxInner(sandbox: SandboxProvider): SandboxProvider {
  return sandbox instanceof UserDeviceRoutedSandbox ? sandbox.inner : sandbox;
}

/** Reads which device a home runs on from its computer record. */
export function userDeviceHomeOwner(prisma: PrismaClient): UserDeviceHomeOwner {
  return async (homeKey) => {
    const computer = await runAsSystem("find the device a computer runs on", () =>
      prisma.computer.findUnique({
        where: { homeKey },
        select: {
          userId: true,
          deviceId: true,
          device: { select: { name: true, revokedAt: true } },
        },
      }),
    );
    if (!computer?.deviceId || !computer.device || computer.device.revokedAt) return null;
    return {
      userId: computer.userId,
      deviceId: computer.deviceId,
      deviceName: computer.device.name,
    };
  };
}

/**
 * Sends computers whose home is on their owner's paired device over the device link, and every
 * other computer to the deployment's sandbox.
 */
export class UserDeviceRoutedSandbox implements SandboxProvider {
  readonly pageBrowser?: SandboxProvider["pageBrowser"];
  // Optional members exist only when the deployment's sandbox has them: callers probe for them.
  readonly isStopped?: SandboxProvider["isStopped"];
  readonly inspectBackgroundWork?: SandboxProvider["inspectBackgroundWork"];
  readonly readStoppedFile?: SandboxProvider["readStoppedFile"];
  readonly deleteMachine?: (machine: UnreferencedMachine, signal: AbortSignal) => Promise<void>;
  private readonly device: UserDeviceSandbox;

  constructor(
    readonly inner: SandboxProvider,
    devices: UserDeviceGateway,
    private readonly owner: UserDeviceHomeOwner,
  ) {
    this.device = new UserDeviceSandbox(devices, owner);
    const { isStopped, inspectBackgroundWork, readStoppedFile, deleteMachine } = inner;
    if (isStopped)
      this.isStopped = (computer, context) =>
        computer.kind === USER_DEVICE_COMPUTER_KIND
          ? Promise.resolve(false)
          : isStopped.call(inner, computer, context);
    if (inspectBackgroundWork)
      this.inspectBackgroundWork = (computer, computerId, context) =>
        computer.kind === USER_DEVICE_COMPUTER_KIND
          ? Promise.resolve("unknown" as const)
          : inspectBackgroundWork.call(inner, computer, computerId, context);
    if (readStoppedFile)
      this.readStoppedFile = (computer, ...rest) =>
        computer.kind === USER_DEVICE_COMPUTER_KIND
          ? Promise.resolve(undefined)
          : readStoppedFile.call(inner, computer, ...rest);
    if (deleteMachine)
      this.deleteMachine = (machine, signal) => deleteMachine.call(inner, machine, signal);
    if (inner.pageBrowser) {
      this.pageBrowser = (computer, request, context) =>
        computer.kind === USER_DEVICE_COMPUTER_KIND || !inner.pageBrowser
          ? Promise.resolve({
              ok: false,
              uncertain: false,
              fallback: "computer_act",
              error: "Page browser is unavailable on this computer.",
            })
          : inner.pageBrowser(computer, request, context);
    }
  }

  private route(computer: Pick<ComputerRef, "kind">): SandboxProvider {
    return computer.kind === USER_DEVICE_COMPUTER_KIND ? this.device : this.inner;
  }

  private async onDevice(homeKey: string | undefined) {
    return homeKey ? (await this.owner(homeKey)) !== null : false;
  }

  describe() {
    return this.inner.describe();
  }

  ownsReference(computer: Pick<ComputerRef, "kind" | "providerRef">) {
    return this.route(computer).ownsReference?.(computer) ?? true;
  }

  async provisionKind(homeKey?: string): Promise<ComputerRef["kind"]> {
    if (await this.onDevice(homeKey)) return USER_DEVICE_COMPUTER_KIND;
    return (await this.inner.provisionKind?.(homeKey)) ?? this.inner.describe().id;
  }

  async provision(
    request: Parameters<SandboxProvider["provision"]>[0],
    context: AdapterContext,
  ): Promise<ComputerRef> {
    if (await this.onDevice(request.botId)) return this.device.provision(request, context);
    return this.inner.provision(request, context);
  }

  async isRunning(computer: ComputerRef, context: AdapterContext): Promise<boolean> {
    return this.route(computer).isRunning?.(computer, context) ?? false;
  }

  async hasMountedHome(computer: ComputerRef, context: AdapterContext): Promise<boolean> {
    return this.route(computer).hasMountedHome?.(computer, context) ?? false;
  }

  async environment(computer: ComputerRef, context: AdapterContext) {
    return this.route(computer).environment?.(computer, context);
  }

  prepare(computer: ComputerRef, context: AdapterContext) {
    return this.route(computer).prepare(computer, context);
  }

  execute(
    computer: ComputerRef,
    request: CommandRequest,
    context: AdapterContext,
  ): AsyncIterable<ProcessEvent> {
    return this.route(computer).execute(computer, request, context);
  }

  workspaceDirectories(
    computer: ComputerRef,
    request: WorkspaceDirectoryRequest,
    context: AdapterContext,
  ) {
    return manageComputerWorkspaceDirectories(this.route(computer), computer, request, context);
  }

  cancelRunWork(computer: ComputerRef, computerId: string, runId: string, context: AdapterContext) {
    return cancelComputerRunWork(this.route(computer), computer, computerId, runId, context);
  }

  connectScreen(computer: ComputerRef, request: ScreenRequest, context: AdapterContext) {
    return this.route(computer).connectScreen(computer, request, context);
  }

  connectTerminal(computer: ComputerRef, request: TerminalRequest, context: AdapterContext) {
    const provider = this.route(computer);
    if (!provider.connectTerminal)
      return Promise.reject(new Error("terminal is unavailable on this computer"));
    return provider.connectTerminal(computer, request, context);
  }

  setScreenControl(
    computer: ComputerRef,
    interactive: boolean,
    context: AdapterContext,
    controlToken?: string,
  ) {
    return (
      this.route(computer).setScreenControl?.(computer, interactive, context, controlToken) ??
      Promise.resolve()
    );
  }

  sendInput(
    computer: ComputerRef,
    input: ComputerInput,
    lease: ControlLeaseRef,
    context: AdapterContext,
  ) {
    return this.route(computer).sendInput(computer, input, lease, context);
  }

  observe(computer: ComputerRef, context: AdapterContext) {
    return this.route(computer).observe(computer, context);
  }

  act(computer: ComputerRef, request: ComputerActionRequest, context: AdapterContext) {
    return this.route(computer).act(computer, request, context);
  }

  listFiles(computer: ComputerRef, path: string, context: AdapterContext) {
    return this.route(computer).listFiles(computer, path, context);
  }

  readFile(
    computer: ComputerRef,
    path: string,
    context: AdapterContext,
    options?: { maxBytes?: number },
  ) {
    return this.route(computer).readFile(computer, path, context, options);
  }

  writeFile(computer: ComputerRef, file: PortableFile, context: AdapterContext) {
    return this.route(computer).writeFile(computer, file, context);
  }

  exportWorkspace(computer: ComputerRef, context: AdapterContext, limits?: WorkspaceExportLimits) {
    return this.route(computer).exportWorkspace(computer, context, limits);
  }

  importWorkspace(
    computer: ComputerRef,
    files: AsyncIterable<PortableFile>,
    context: AdapterContext,
  ) {
    return this.route(computer).importWorkspace(computer, files, context);
  }

  snapshot(computer: ComputerRef, context: AdapterContext) {
    return this.route(computer).snapshot(computer, context);
  }

  billsWhileRunning(computer: Pick<ComputerRef, "kind">): boolean {
    return this.route(computer).billsWhileRunning?.(computer) ?? false;
  }

  keepsHome(computer: ComputerRef) {
    return providerKeepsHome(this.route(computer), computer);
  }

  keepAlive(computer: ComputerRef) {
    return this.route(computer).keepAlive?.(computer) ?? Promise.resolve();
  }

  releaseScreen(computer: ComputerRef, context: AdapterContext) {
    return this.route(computer).releaseScreen?.(computer, context) ?? Promise.resolve();
  }

  stop(computer: ComputerRef, context: AdapterContext, options?: { discardUnsaved?: boolean }) {
    return this.route(computer).stop(computer, context, options);
  }

  destroy(computer: ComputerRef, context: AdapterContext) {
    return this.route(computer).destroy(computer, context);
  }
}
