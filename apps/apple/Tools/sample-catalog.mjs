import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../../../packages/adapters/src/providers/integration/composio/composio-fake.ts', import.meta.url), 'utf8');
const directory = source.match(/const DEFAULT_DIRECTORY:[^=]*= \[([\s\S]+?)\n\];/)[1];
const apps = [...directory.matchAll(/slug: "(\w+)", name: "([^"]+)", logo: null, noAuth: (true|false)/g)].map(([, slug, name, noAuth]) => {
  const block = source.match(new RegExp(`const ${slug}_TOOLS: SessionTools = \\[([\\s\\S]+?)\\n\\];`));
  const tools = block ? [...block[1].matchAll(/functionTool\(\s*"([A-Z_]+)",\s*"([^"]+)"/g)].map(([, name, description]) => ({ name, description })) : [{ name: `${slug}_EMULATED_ACTION`, description: `Run a deterministic ${slug} action` }];
  if (!tools.length) throw new Error(`No tools for ${slug}`);
  return { slug: slug.toLowerCase(), name, noAuth: noAuth === 'true', tools };
});
if (!apps.length) throw new Error('Empty upstream directory');
const sources = await Promise.all(['asana.com', 'figma.com', 'github.com', 'linear.app', 'slack.com'].map(async domain => {
  const response = await fetch(`https://integrations.sh/api/search?q=${domain}&limit=4`, { redirect: 'error', signal: AbortSignal.timeout(10000) });
  if (!response.ok) throw new Error(`Directory unavailable: ${response.status}`);
  const result = (await response.json()).results.find(item => item.domain === domain);
  const surfaces = [...new Set(result.surfaces.map(item => item.kind).filter(kind => ['mcp', 'openapi', 'graphql', 'cli'].includes(kind)))].sort();
  if (!surfaces.length) throw new Error(`No interfaces for ${domain}`);
  return { domain, surfaces };
}));
console.log(JSON.stringify({ apps, sources }, null, 2));
