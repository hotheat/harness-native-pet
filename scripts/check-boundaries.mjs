import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
async function files(path) {
 const entries = await readdir(path, {withFileTypes:true}).catch(error => { if (error.code === 'ENOENT') return []; throw error; });
 const lists=await Promise.all(entries.map(e => e.isDirectory()?files(join(path,e.name)):[join(path,e.name)]));
 return lists.flat();
}
const checks = [
 ['native/Sources/PetCore', /import\s+(AppKit|SwiftUI|Network)\b/, 'Core cannot import UI or transport'],
 ['native/Sources/PetIPC', /import\s+DSHNativePet\b/, 'Transport cannot import application'],
 ['bridge/lib', /(?:from\s+['"][^'"]*dsh[^'"]*\/src\/|\.(?:snapshotEvents|eventAt|ownEvents)\s*\()/, 'Bridge must use public live APIs'],
];
const violations=[];
for (const [dir,pattern,reason] of checks) for (const path of await files(join(root,dir))) if (/\.(swift|js|mjs)$/.test(path) && pattern.test(await readFile(path,'utf8'))) violations.push(`${path}: ${reason}`);
if (violations.length) throw new Error(violations.join('\n'));
console.log('Module dependency boundaries passed');
