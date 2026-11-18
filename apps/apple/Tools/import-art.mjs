import { mkdir, copyFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = process.argv[2] ? resolve(process.argv[2]) : fileURLToPath(new URL('../../../', import.meta.url));
const assets = 'App/Assets.xcassets';
const core = join(root, 'packages/core/src');
const avatars = existsSync(join(core, 'avatars/avatar-shape.ts')) ? join(core, 'avatars') : core;
const organic = await import(pathToFileURL(join(avatars, 'avatar-shape.ts')));
const shipped = await import(pathToFileURL(join(avatars, 'bot-avatar-shapes.ts')));
const info = { author: 'xcode', version: 1 };
async function catalog(path, infoFile) {
  await mkdir(path, {recursive:true});
  await writeFile(join(path,'Contents.json'), JSON.stringify({info,...infoFile},null,2)+'\n');
}
await catalog(assets,{});
for (const [series,count] of [['Organic',10],['Classic',8]]) {
  for(let index=0;index<count;index++) {
    const dir=join(assets,`${series}${index}.imageset`);
    const body=series==='Organic'?organic.organicAvatarPath(index):shipped.shippedBotAvatarShapePath(index);
    const box=series==='Organic'?organic.ORGANIC_AVATAR_VIEWBOX:shipped.SHIPPED_BOT_AVATAR_VIEWBOX;
    await catalog(dir,{images:[{idiom:'universal',filename:'body.svg'}],properties:{'preserves-vector-representation':true,'template-rendering-intent':'template'}});
    await writeFile(join(dir,'body.svg'),`<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="${box}"><path d="${body}"/></svg>\n`);
  }
}
const icon=join(assets,'AppIcon.appiconset');
await catalog(icon,{images:[{filename:'icon.png',idiom:'universal',platform:'ios',size:'1024x1024'}]});
await copyFile(join(root,'apps/mobile/assets/icon.png'),join(icon,'icon.png'));
await mkdir('ThirdParty',{recursive:true});
for (const name of ['LICENSE','NOTICE']) await copyFile(join(root,name),join('ThirdParty',`Rakazo-${name}`));
