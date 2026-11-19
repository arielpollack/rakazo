import { LogoAvatar } from "original-logo";
import { mobileBotAvatarPresentation } from "original-identity";
import { lightTokens, darkTokens } from "avatar-tokens";
import { setPose } from "./pose.js";
import {
  usesLogoAvatar,
  avatarIdentitySeed,
  organicAvatarPath,
  organicAvatarEyeTilt,
  AVATAR_TYPING_DOTS,
  AVATAR_MOTION_UNITS,
  ORGANIC_AVATAR_EYES,
  SHIPPED_BOT_AVATAR_EYES,
  ORGANIC_AVATAR_VIEWBOX,
  SHIPPED_BOT_AVATAR_VIEWBOX,
  resolvePersonaColorDef,
  botEyeInk,
  AVATAR_REST_POSE,
  avatarClipPool,
  avatarSchedule,
  avatarSchedulePose,
  avatarFrame,
  shippedHash,
  shippedRandom,
  avatarThinkingDot,
  avatarPhotoDot,
  avatarPokeFrame,
  AVATAR_POKES,
  AVATAR_POKE_SECONDS,
} from "avatar-core";
import { initialLogoAvatarSignals, reduceLogoAvatarSignals, logoAvatarActivity } from "avatar-core";
import { reduceLiveMessageBlocks, liveMessageComposing, liveActivityLine } from "original-messages";

export function liveTurn(botId, runId, status, background, blocks, cursor) {
  let signals = { ...initialLogoAvatarSignals(botId), runId, status, background, cursor };
  const working = () =>
    ["running", "leased", "queued"].includes(signals.status) && !signals.background;
  return {
    read() {
      const active = working();
      const composing = active && liveMessageComposing(blocks);
      const pose = logoAvatarActivity(signals);
      return {
        status: signals.status,
        pose: composing && pose === "working" ? "writing" : pose,
        working: active,
        composing,
        text: active
          ? blocks
              .filter((b) => b.kind === "text" || (b.kind === "progress" && !b.activity))
              .map((b) => b.text)
              .join("")
          : "",
        label: active ? liveActivityLine([{ id: `progress:${runId}`, blocks }]) || "" : "",
      };
    },
    receive(event) {
      if (event.seq <= signals.cursor || event.botId !== botId || event.runId !== runId) return;
      signals = reduceLogoAvatarSignals(signals, event);
      if (
        !working() ||
        event.type === "run.started" ||
        (event.type === "thread.message.created" && event.payload.role === "bot")
      )
        blocks = [];
      else if (event.type === "thread.progress")
        blocks = reduceLiveMessageBlocks(blocks, { type: "progress", payload: event.payload });
      else if (event.type === "agent.tool.called")
        blocks = reduceLiveMessageBlocks(blocks, { type: "tool", name: event.payload.name ?? "" });
    },
  };
}

const aliases = {
  clipPath: "clip-path",
  strokeWidth: "stroke-width",
  strokeLinecap: "stroke-linecap",
  strokeLinejoin: "stroke-linejoin",
  stopColor: "stop-color",
  stopOpacity: "stop-opacity",
  maskType: "mask-type",
};
const skip = new Set(["key", "animatedProps", "accessible"]);
const escape = (value) =>
  String(value).replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
const attrs = (props) =>
  Object.entries(props)
    .filter(([name]) => !skip.has(name))
    .map(([name, value]) => ` ${aliases[name] ?? name}="${escape(value)}"`)
    .join("");
const xml = (node) =>
  `<${node.tag}${attrs(node.props)}>${node.children.map(xml).join("")}</${node.tag}>`;
const svg = (body, box = "0 0 100 100") =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="${box}">${body}</svg>`;
const dynamic = (node) => !!node.props.animatedProps || node.children.some(dynamic);
const matrix = (x, y, angle, sx, sy) => {
  const radians = (angle * Math.PI) / 180,
    cos = Math.cos(radians),
    sin = Math.sin(radians);
  return [
    cos * sx,
    sin * sx,
    -sin * sy,
    cos * sy,
    50 + x - 50 * (cos * sx - sin * sy),
    50 + y - 50 * (sin * sx + cos * sy),
  ];
};

function logo(props, tokens, clock, still, samplers) {
  setPose({ tokens, clock, still });
  const artwork = LogoAvatar({ ...props, motion: still ? "static" : "running" });
  const definitions = artwork.children.find((node) => node.tag === "defs");
  const defs = xml(definitions);
  function layer(node, inherited = {}) {
    const { animatedProps, transform, clipPath, ...style } = node.props;
    const item = {};
    if (animatedProps) {
      item.sample = samplers.length;
      samplers.push(animatedProps);
    }
    if (node.tag === "ellipse" && animatedProps) return { ...item, eye: style.rx, ink: style.fill };
    if (node.tag !== "g" || !dynamic(node)) {
      const body = `<g${attrs(inherited)}>${xml(node)}</g>`;
      item.image = svg((body.includes("url(#") ? defs : "") + body);
      return item;
    }
    if (clipPath) {
      const clip = definitions.children.find((child) => `url(#${child.props.id})` === clipPath)
        .children[0];
      if (clip.tag === "rect") {
        const { x = 0, y = 0, width, height, rx = 0 } = clip.props;
        item.clip = [x, y, width, height, rx];
      } else item.mask = svg(xml(clip));
    }
    if (transform) {
      const match = /^translate\(([-.\d]+)[ ,]+([-.\d]+)\)$/.exec(transform);
      if (!match) throw Error(`Unsupported dynamic group: ${transform}`);
      item.offset = [Number(match[1]), Number(match[2])];
    }
    item.children = node.children.map((child) => layer(child, { ...inherited, ...style }));
    return item;
  }
  return artwork.children.filter((node) => node !== definitions).map((node) => layer(node));
}

function legacy(identity, raw, size, activity, composing, still, tokens, clock, samplers) {
  const parsed = mobileBotAvatarPresentation(raw),
    shape = parsed.kind === "shape";
  const fill =
    shape || parsed.kind === "color" ? parsed.color : resolvePersonaColorDef(identity, raw).hex;
  const seed = avatarIdentitySeed(identity || fill);
  const eyes = shape ? SHIPPED_BOT_AVATAR_EYES : ORGANIC_AVATAR_EYES;
  const box = shape ? SHIPPED_BOT_AVATAR_VIEWBOX : ORGANIC_AVATAR_VIEWBOX;
  const [minX, minY, units] = box.split(" ").map(Number),
    unit = 100 / units;
  const body = shape ? parsed.shapePath : organicAvatarPath(seed);
  const ink = botEyeInk(fill, tokens),
    active = !still && activity !== "idle" && activity !== "waiting" && activity !== "error";
  const clips = active
    ? avatarSchedule(
        avatarClipPool(composing ? "thinking" : "working", size, "running"),
        0,
        AVATAR_REST_POSE,
        shippedRandom(shippedHash(identity)),
      )
    : [];
  const last = clips.at(-1),
    length = last ? last.start + last.duration : 1;
  let lastTime, frame;
  const pose = () => {
    if (clock.value !== lastTime) {
      lastTime = clock.value;
      frame = avatarFrame(
        active ? avatarSchedulePose(clips, (lastTime / 1000) % length) : AVATAR_REST_POSE,
        active ? 1 : 0,
      );
    }
    return frame;
  };
  const sample = (fn) => {
    samplers.push(fn);
    return samplers.length - 1;
  };
  const grow = () => clock.morph * clock.morph * (3 - 2 * clock.morph);
  const face = {
    sample: sample(() => {
      const p = pose();
      const factor = 1 - (1 - (2 * AVATAR_TYPING_DOTS.radius) / AVATAR_MOTION_UNITS) * grow();
      return {
        matrix: matrix(
          100 * p.translateX,
          100 * p.translateY,
          p.rotate,
          p.scaleX * factor,
          p.scaleY * factor,
        ),
        opacity: 1 - grow(),
      };
    }),
    children: [
      { image: svg(`<path d="${body}" fill="${fill}"/>`, box) },
      {
        tilt: shape ? 0 : organicAvatarEyeTilt(seed),
        children: [eyes.leftCx, eyes.rightCx].map((cx) => ({
          bar: eyes.width * unit,
          ink,
          sample: sample(() => ({
            cx: (cx - minX) * unit + pose().eyeX,
            cy: (eyes.cy - minY) * unit + pose().eyeY,
            ry: grow() >= 0.5 ? 0 : (eyes.height * unit * pose().lid) / 2,
          })),
        })),
      },
    ],
  };
  return [
    face,
    ...[0, 1, 2].map((slot) => ({
      dot: true,
      ink: fill,
      sample: sample(() => {
        const d = avatarThinkingDot(slot, clock.value / 1000, clock.morph);
        return { cx: 50 + d.x, cy: 50 + d.y, ry: d.radius, opacity: d.opacity };
      }),
    })),
  ];
}

export function create(identity, color, avatarSet, size, dark, activity, composing, still) {
  const tokens = dark ? darkTokens : lightTokens,
    clock = { value: 0, morph: 0 },
    samplers = [];
  const photo = color.startsWith("data:image/");
  const nodes = photo
    ? [0, 1, 2].map((slot) => {
        samplers.push(() => ({
          cx: ((3 + slot * 10) * 100) / size,
          cy: 50,
          ry: 300 / size,
          opacity: still ? 0.6 : avatarPhotoDot(slot, clock.value, composing),
        }));
        return { dot: true, ink: tokens.mutedForeground, sample: slot };
      })
    : usesLogoAvatar({ color, avatarSet })
      ? logo({ color, identity, size, activity }, tokens, clock, still, samplers)
      : legacy(identity, color, size, activity, composing, still, tokens, clock, samplers);
  return {
    nodes,
    sample: (milliseconds, morph) => {
      clock.value = milliseconds;
      clock.morph = morph;
      return samplers.map((sample) => sample());
    },
  };
}
export function poke(index, seconds) {
  const kind = AVATAR_POKES[index % AVATAR_POKES.length];
  if (seconds < 0 || seconds >= AVATAR_POKE_SECONDS[kind]) return [1, 0, 0, 1, 0, 0];
  const frame = avatarPokeFrame(kind, seconds / AVATAR_POKE_SECONDS[kind]);
  return matrix(0, 100 * frame.translateY, frame.rotate, 1, frame.scaleY);
}
