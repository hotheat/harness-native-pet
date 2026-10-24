import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { connect } from 'node:net';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
const root = fileURLToPath(new URL('../', import.meta.url));
const runtime = mkdtempSync('/tmp/dnp-ipc-');
const executable = process.env.DSH_NATIVE_PET_SMOKE_BINARY ?? join(root, 'native/.build/debug/PetIPCSmoke');
const env = {...process.env, DSH_NATIVE_PET_RUNTIME_DIR: runtime};
const child = spawn(executable, [], {env, stdio:['ignore','pipe','pipe']});
const records = [], sockets = [];
let stderr = '', buffer = '';
child.stderr.on('data', chunk => { stderr += chunk; });
child.stdout.on('data', chunk => {
  buffer += chunk;
  while (buffer.includes('\n')) {
    const end = buffer.indexOf('\n'), line = buffer.slice(0,end); buffer = buffer.slice(end+1);
    if (line.trim()) { try { records.push(JSON.parse(line)); } catch { records.push({type:'log',line}); } }
  }
});
const sleep = ms => new Promise(resolve => setTimeout(resolve,ms));
async function waitFor(predicate, timeout=6000) {
  const end=Date.now()+timeout;
  while (Date.now()<end) {
    const value=records.find(predicate); if (value) return value;
    if (child.exitCode !== null) throw new Error(`IPC server exited ${child.exitCode}: ${stderr}`);
    await sleep(15);
  }
  throw new Error(`IPC timeout: ${JSON.stringify(records)} ${stderr}`);
}
const message = record => record.type==='message' ? record.message : record;
function snapshot(sourceId,seq,phase='thinking') {
  return {type:'snapshot',sourceId,sourceLabel:'IPC smoke',seq,sessions:[{sessionId:'session',turn:1,phase,activeTools:phase==='working'?1:0,pendingApprovals:0,result:null}]};
}
async function client() {
  const socket=connect(join(runtime,'pet.sock')); sockets.push(socket);
  socket.on('error',()=>{}); await once(socket,'connect'); return socket;
}
try {
  await waitFor(r=>r.type==='ready');
  const a=await client();
  const line=JSON.stringify(snapshot('source-a',1))+'\n';
  a.write(line.slice(0,17)); await sleep(30); a.write(line.slice(17));
  await waitFor(r=>message(r).type==='snapshot' && message(r).seq===1);
  a.write(JSON.stringify({type:'heartbeat',sourceId:'source-a',seq:2})+'\n'+JSON.stringify(snapshot('source-a',3,'working'))+'\n');
  await waitFor(r=>message(r).type==='snapshot' && message(r).seq===3);
  const b=await client(); b.write(JSON.stringify(snapshot('source-b',1))+'\n');
  await waitFor(r=>message(r).sourceId==='source-b');
  a.destroy(); await waitFor(r=>r.type==='disconnect' && r.sourceId==='source-a');
  b.write(JSON.stringify(snapshot('source-b',2,'working'))+'\n');
  await waitFor(r=>message(r).type==='snapshot' && message(r).sourceId==='source-b' && message(r).seq===2);
  const second=spawn(executable,[],{env,stdio:['ignore','pipe','pipe']});
  let secondError=''; second.stderr.on('data',x=>{secondError+=x;}); second.stdout.resume();
  const secondExit=await Promise.race([once(second,'exit'),sleep(5000).then(()=>{second.kill('SIGKILL');throw new Error('Second instance did not fail promptly');})]);
  assert.notEqual(secondExit[0],0,'Second instance must reject held lock');
  assert(existsSync(join(runtime,'pet.sock')),'Second instance removed active socket');
  const exited=once(child,'exit'); child.kill('SIGTERM');
  const [code]=await exited; assert.equal(code,0,stderr);
  assert(!existsSync(join(runtime,'pet.sock')),'Socket survives normal shutdown');
  console.log('Real Swift/Node IPC: split frames, coalesced frames, two sources, disconnect isolation, instance lock and shutdown passed');
} finally {
  for (const socket of sockets) socket.destroy();
  if (child.exitCode===null) {const exit=once(child,'exit');child.kill('SIGTERM');await Promise.race([exit,sleep(2000)]);if(child.exitCode===null)child.kill('SIGKILL');}
  rmSync(runtime,{recursive:true,force:true});
}
