import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const root = new URL('../', import.meta.url);
const require = createRequire(new URL('bridge/package.json', root));
const Ajv = require('ajv');
const json = path => JSON.parse(readFileSync(new URL(path, root), 'utf8'));
const validate = new Ajv({allErrors: true, strict: true}).compile(json('contracts/bridge.schema.json'));
for (const {name,message} of [...json('contracts/fixtures/snapshots.json'), ...json('contracts/fixtures/activity.json')]) assert(validate(message), `${name}: ${JSON.stringify(validate.errors)}`);
for (const {name,message} of json('contracts/fixtures/invalid-messages.json')) assert(!validate(message), `${name} was accepted`);
if (existsSync(new URL('bridge/fixtures/', root))) {
  for (const name of ['snapshots.json', 'activity.json', 'invalid-messages.json']) {
    const plugin = readFileSync(new URL(`bridge/fixtures/${name}`, root));
    const contract = readFileSync(new URL(`contracts/fixtures/${name}`, root));
    if (!plugin.equals(contract)) throw new Error(`${name}: bridge and contracts fixture copies must be identical`);
  }
}
console.log('Shared schema fixtures passed');
