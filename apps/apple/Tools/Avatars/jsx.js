export const Fragment = null;
export function makeNode(tag, props, ...children) {
  const nodes = children.flat(Infinity).filter((child) => child && typeof child === "object");
  return tag ? { tag, props: props ?? {}, children: nodes } : nodes;
}
