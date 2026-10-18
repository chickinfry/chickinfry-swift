import assert from "node:assert/strict";
import fs from "node:fs";
import { WASI } from "node:wasi";

const module = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
const wasi = new WASI({ version: "preview1", args: [], env: {}, preopens: {} });
let instance;
let nextCall = 1;
const pending = new Map();
const range = (pointer, size) => new Uint8Array(instance.exports.memory.buffer, pointer >>> 0, size >>> 0);
const imports = {
  "wasi_snapshot_preview1": wasi.wasiImport,
  "chik-swift:1": {
    enqueue(job, delay) {
      const run = () => instance.exports.chik_run_job(job);
      if (delay === 0) queueMicrotask(run);
      else setTimeout(run, delay);
    },
    settle(id, status, pointer, size) {
      const resolve = pending.get(id);
      assert.ok(resolve, "completion must belong to a pending request");
      pending.delete(id);
      resolve({ status, body: range(pointer, size).slice() });
    },
  },
};
instance = new WebAssembly.Instance(module, imports);
wasi.initialize(instance);
function wait(id, start) {
  let timer;
  return new Promise((resolve, reject) => {
    timer = setTimeout(() => reject(new Error("Swift async completion watchdog expired")), 3000);
    pending.set(id, resolve);
    start();
  }).finally(() => clearTimeout(timer));
}
const boot = await wait(0, () => assert.doesNotThrow(() => instance.exports.probe_boot(), "WASM bootstrap must use the Swift calling convention"));
assert.equal(boot.status, 200);
console.log("bootstrap: passed");
const encoder = new TextEncoder();
async function call(mode, value) {
  const id = nextCall++;
  const metadata = encoder.encode(JSON.stringify({ operation: "probe.run", context: { method: "POST", uri: "http://127.0.0.1/probe.run", headers: {} } }));
  const body = encoder.encode(JSON.stringify({ mode, value }));
  const response = await wait(id, () => {
    const frame = instance.exports.chik_allocate(metadata.length);
    const input = instance.exports.chik_allocate(body.length);
    try {
      range(frame, metadata.length).set(metadata); range(input, body.length).set(body);
      instance.exports.probe_handle(id, frame, metadata.length, input, body.length);
    } finally { instance.exports.chik_deallocate(frame); instance.exports.chik_deallocate(input); }
  });
  assert.equal(response.status, 200);
  const output = JSON.parse(new TextDecoder().decode(response.body));
  assert.equal(output.value, value);
  assert.equal(output.setupCount, 1);
}
await call("fast", "first");
console.log("fast: passed");
for (const mode of ["legacy", "duration", "main"]) {
  const order = [];
  const delayed = call(mode, mode).then(() => order.push("delayed"));
  await call("fast", "concurrent");
  order.push("fast");
  await delayed;
  if (mode !== "main") assert.deepEqual(order, ["fast", "delayed"], "a suspended request must let another request finish");
  console.log(`${mode}: passed`);
}
const outputs = await Promise.all([call("duration", "slow"), call("fast", "fast"), call("legacy", "other")]);
assert.equal(outputs.length, 3);
console.log("request isolation and setup once: passed");
