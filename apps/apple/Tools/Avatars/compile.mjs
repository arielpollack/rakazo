import { createRequire } from "node:module";
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(process.argv[2] ?? join(here, "../../../.."));
const require = createRequire(join(root, "package.json"));
const { build } = require("esbuild");
const contracts = join(root, "packages/contracts/src");
async function declarations(file, names) {
  const source = await readFile(join(contracts, file), "utf8");
  const selected = source
    .split(/\n(?=(?:export )?(?:const|function|type|interface|import)\s)/)
    .map((chunk) => chunk.trim())
    .filter((chunk) => names.includes(/^(?:export )?(?:const|function)\s+(\w+)/.exec(chunk)?.[1]));
  if (selected.length !== names.length) throw Error(`Upstream avatar contract changed in ${file}`);
  return selected.join("\n");
}
const core = join(root, "packages/core/src");
const avatars = existsSync(join(core, "avatars")) ? join(core, "avatars") : core;
const mobile = join(root, "apps/mobile/components");
const logo = join(
  existsSync(join(mobile, "bots/logo-avatar.tsx")) ? join(mobile, "bots") : mobile,
  "logo-avatar.tsx",
);
const tokens = join(root, "packages/ui-tokens/src/index.ts");
const modules = [
  "avatar-life",
  "avatar-clips",
  "avatar-shape",
  "logo-avatar-activity",
  "logo-avatar-art",
  "logo-avatar-motion",
  "logo-avatar-traits",
  "bot-avatar-colors",
  "bot-avatar-shapes",
];
const result = await build({
  entryPoints: [join(here, "scene.js")],
  write: false,
  bundle: true,
  minify: true,
  target: "safari17",
  format: "iife",
  globalName: "RakazoAvatars",
  jsx: "transform",
  jsxFactory: "makeNode",
  jsxFragment: "Fragment",
  inject: [join(here, "jsx.js")],
  plugins: [
    {
      name: "original-mobile-art",
      setup(builder) {
        builder.onResolve({ filter: /^original-logo$/ }, () => ({ path: logo }));
        builder.onResolve({ filter: /^original-identity$/ }, () => ({
          path: join(
            root,
            "apps/mobile/lib",
            existsSync(join(root, "apps/mobile/lib/bots/bot-avatar.ts"))
              ? "bots/bot-avatar.ts"
              : "bot-avatar.ts",
          ),
        }));
        builder.onResolve({ filter: /^original-messages$/ }, () => ({
          path: "messages",
          namespace: "live-messages",
        }));
        builder.onLoad({ filter: /.*/, namespace: "live-messages" }, async () => ({
          loader: "ts",
          contents: await declarations(
            join(
              "../../core/src",
              existsSync(join(core, "messages/events.ts")) ? "messages/events.ts" : "events.ts",
            ),
            [
              "reduceLiveMessageBlocks",
              "liveMessageText",
              "liveMessageComposing",
              "liveActivityLine",
              "progressMessageText",
              "appendToolCallSegment",
              "appendToolStep",
              "humanizeToolName",
              "appendTextSegment",
              "endsSentence",
              "SENTENCE_END_RE",
            ],
          ),
        }));
        builder.onResolve({ filter: /^avatar-tokens$/ }, () => ({ path: tokens }));
        builder.onResolve({ filter: /^@rakazo\/contracts$/ }, () => ({
          path: "contracts",
          namespace: "avatar-contracts",
        }));
        builder.onLoad({ filter: /.*/, namespace: "avatar-contracts" }, async () => ({
          loader: "ts",
          contents: [
            await declarations(
              existsSync(join(contracts, "bots/bot-avatar.ts"))
                ? "bots/bot-avatar.ts"
                : "bot-avatar.ts",
              [
                "BOT_COLOR_LIST",
                "BOT_COLORS",
                "BOT_AVATAR_SHAPE_COUNT",
                "HEX_COLOR",
                "parseBotAvatarValue",
              ],
            ),
            await declarations(
              existsSync(join(contracts, "threads/events.ts")) ? "threads/events.ts" : "events.ts",
              ["hasThinkingActivityMarker"],
            ),
          ].join("\n"),
        }));
        builder.onResolve({ filter: /^(@rakazo\/core|avatar-core)$/ }, () => ({
          path: "core",
          namespace: "original-exports",
        }));
        builder.onLoad({ filter: /.*/, namespace: "original-exports" }, () => ({
          resolveDir: avatars,
          contents: modules.map((name) => `export * from './${name}.ts';`).join("\n"),
        }));
        builder.onResolve(
          {
            filter:
              /^(react|react-native|react-native-svg|react-native-reanimated|.*\/avatar-life|.*\/logo-avatar-clock|.*\/native)$/,
          },
          (args) =>
            args.importer === logo
              ? {
                  path: join(here, "host.js"),
                  suffix: args.path === "react-native-svg" ? "?svg" : "",
                }
              : undefined,
        );
        builder.onLoad({ filter: /\/host\.js$/ }, async (args) => ({
          contents:
            (await readFile(args.path, "utf8")) +
            `\nexport default ${args.suffix === "?svg" ? "'svg'" : "{createAnimatedComponent: value => value}"};`,
          resolveDir: here,
        }));
      },
    },
  ],
});
await writeFile(
  join(here, "../../App/Assets.xcassets/AvatarEngine.dataset/engine.js"),
  result.outputFiles[0].contents,
);
