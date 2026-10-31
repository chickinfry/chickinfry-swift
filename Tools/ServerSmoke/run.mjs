import assert from "node:assert/strict";
import fs from "node:fs";
import { WASI } from "node:wasi";
import { createHash } from "node:crypto";

const artifact = fs.readFileSync(process.argv[2]);
const module = new WebAssembly.Module(artifact);
function artifactABI(bytes) {
  let position = 8;
  const byte = () => bytes[position++];
  const integer = () => {
    let result = 0, shift = 0, value;
    do { value = byte(); result += (value & 127) * 2 ** shift; shift += 7; } while (value & 128);
    return result;
  };
  const name = () => { const size = integer(); const value = bytes.subarray(position, position + size).toString("utf8"); position += size; return value; };
  const vector = (read) => Array.from({ length: integer() }, read);
  const scalar = () => ({ 127: "i32", 126: "i64", 125: "f32", 124: "f64", 123: "v128", 112: "funcref", 111: "externref" })[byte()];
  const types = [], functions = [], imports = [], exports = [];
  while (position < bytes.length) {
    const section = byte(), end = integer() + position;
    if (section === 1) types.push(...vector(() => {
      assert.equal(byte(), 96);
      return { parameters: vector(scalar), results: vector(scalar) };
    }));
    if (section === 2) imports.push(...vector(() => {
      const module = name(), field = name();
      assert.equal(byte(), 0, "probe imports must be functions");
      const type = integer(); functions.push(type);
      return { module, name: field, ...types[type] };
    }));
    if (section === 3) functions.push(...vector(integer));
    if (section === 7) exports.push(...vector(() => {
      const field = name(), kind = byte(), index = integer();
      return { name: field, kind, ...(kind === 0 ? types[functions[index]] : {}) };
    }));
    position = end;
  }
  return { sha256: createHash("sha256").update(bytes).digest("hex"), bytes: bytes.length, imports, exports };
}
const abi = artifactABI(artifact);
assert.equal(abi.imports.length, 35);
assert.equal(abi.exports.length, 10);
console.log("artifact ABI:", JSON.stringify(abi));
const wasi = new WASI({ version: "preview1", args: [], env: {}, preopens: {} });
let instance;
let nextCall = 1;
const pending = new Map();
const resources = new Map();
const finished = [];
let logs = 0, databaseCalls = 0;
const range = (pointer, size) => {
  const memory = instance.exports.memory.buffer, start = pointer >>> 0;
  assert.ok(size >= 0 && start <= memory.byteLength - size, "range must use current memory and remain in bounds");
  return new Uint8Array(memory, start, size);
};
const encoder = new TextEncoder();
function hostResult(id, value) {
  const bytes = encoder.encode(JSON.stringify(value));
  const pointer = instance.exports.chik_allocate(bytes.length);
  try {
    range(pointer, bytes.length).set(bytes);
    instance.exports.chik_host_result(id, 1, pointer, bytes.length);
  } finally { instance.exports.chik_deallocate(pointer); }
}
function hostCall(channel, id, pointer, size) {
  const copy = range(pointer, size).slice();
  instance.exports.memory.grow(1);
  const frame = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(copy));
  const state = resources.get(frame.rid);
  assert.ok(state, "host authority must belong to a live rid");
  if (channel === 3) {
    if (frame.cancel) state.stopping = true;
    Promise.all([...state.pending]).then(() => {
      assert.equal(state.ports, 0, "finish cannot acknowledge a live port");
      resources.delete(frame.rid);
      finished.push({ rid: frame.rid, cancelled: frame.cancel, calls: state.calls });
      hostResult(id, {});
    });
    return;
  }
  assert.equal(state.stopping, false, "new I/O after cancellation is forbidden");
  const operation = (async () => {
    if (channel === 1) { assert.equal(frame.name, "probe"); return { value: "environment" }; }
    if (channel === 2) { assert.equal(frame.message, "Probe log"); logs++; return {}; }
    assert.equal(channel, 0);
    databaseCalls++; state.calls++;
    if (frame.op === "query") {
      state.ports++;
      try {
        if (frame.sql !== "fast") await new Promise((resolve) => setTimeout(resolve, 40));
        return state.stopping ? { error: "database_failed" } : { rows: [{ value: `db:${frame.sql}` }] };
      } finally { state.ports--; }
    }
    if (frame.op === "begin") { state.lease = 2 ** 32 + id; return { lease: state.lease }; }
    assert.equal(frame.op, "commit"); assert.equal(frame.lease, state.lease);
    instance.exports.chik_commit_observed(id, 2, 1);
    return {};
  })();
  state.pending.add(operation);
  operation.then((value) => {
    hostResult(id, value);
    hostResult(id, { error: "database_failed" });
  }).finally(() => state.pending.delete(operation));
}
const imports = {
  "wasi_snapshot_preview1": wasi.wasiImport,
  "chik-swift:1": {
    host_call: hostCall,
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
async function call(mode, value, options = {}) {
  const id = nextCall++;
  const host = ["db", "env", "transaction", "cancel"].includes(mode);
  const rid = host ? 2 ** 32 + id : undefined;
  if (host) resources.set(rid, { pending: new Set(), ports: 0, stopping: false, calls: 0 });
  const metadata = encoder.encode(JSON.stringify({ operation: "probe.run", context: { method: "POST", uri: "http://127.0.0.1/probe.run", headers: {} }, rid, deadlineMilliseconds: options.deadlineMilliseconds }));
  const body = options.body instanceof Uint8Array ? options.body : encoder.encode(options.body ?? JSON.stringify({ mode, value }));
  const response = await wait(id, () => {
    const frame = instance.exports.chik_allocate(metadata.length);
    const input = instance.exports.chik_allocate(body.length);
    try {
      range(frame, metadata.length).set(metadata); range(input, body.length).set(body);
      instance.exports.probe_handle(id, frame, metadata.length, input, body.length);
      if (options.cancel) instance.exports.chik_cancel(id);
    } finally { instance.exports.chik_deallocate(frame); instance.exports.chik_deallocate(input); }
  });
  assert.equal(response.status, options.status ?? 200);
  if (response.status !== 200) {
    assert.deepEqual(JSON.parse(new TextDecoder().decode(response.body)), { error: options.error ?? "operation_failed" });
    return;
  }
  const output = JSON.parse(new TextDecoder().decode(response.body));
  assert.equal(output.value, mode === "db" ? `db:${value}` : mode === "env" ? "environment" : value);
  assert.equal(output.setupCount, 1);
}
await call("fast", "first");
console.log("fast: passed");
await call("fast", "keys", { body: '{"mode":"fast","value":"keys","keys":{"é":1,"e\\u0301":2,"cafe\\u0301":3}}' });
await call("fast", "escaped keys", { body: '{"mode":"fast","value":"escaped keys","keys":{"\\u00e9":1,"é":2,"café":3}}' });
await call("fast", "invalid keys", { body: '{"mode":"fast","value":"invalid keys","keys":{"é":1,"é":9,"café":3}}', status: 400, error: "invalid_input" });
await call("fast", "budget", { body: '{"mode":"fast","value":"budget","keys":{"budget":0}}', status: 413, error: "request_too_large" });
console.log("byte-exact keys, default literal SPI, Foundation numeric parity, 400 and 413: passed");
const beforeInvalidInput = databaseCalls;
for (const [name, body, error] of [
  ["depth 65", '{"mode":"db","value":"blocked","ignored":' + "[".repeat(64) + "null" + "]".repeat(64) + "}", "invalid_input"],
  ["invalid JSON", '{"mode":"db","value":"blocked",}', "invalid_json"],
  ["invalid UTF-8", new Uint8Array([123, 34, 255, 34, 58, 48, 125]), "invalid_json"],
  ["positive overflow", '{"mode":"db","value":"blocked","ignored":1e999}', "invalid_input"],
  ["negative overflow", '{"mode":"db","value":"blocked","ignored":-1e999}', "invalid_input"],
  ["duplicate key", '{"mode":"db","value":"blocked","ignored":0,"ignored":1}', "invalid_input"],
  ["nested duplicate key", '{"mode":"db","value":"blocked","ignored":{"x":0,"x":1}}', "invalid_input"],
  ["escaped duplicate key", '{"mode":"db","value":"blocked","ign\\u006fred":0,"ignored":1}', "invalid_input"],
  ["unpaired surrogate value", '{"mode":"db","value":"blocked","ignored":"\\uD800"}', "invalid_input"],
  ["unpaired surrogate key", '{"mode":"db","value":"blocked","ignored":{"\\uDC00":0}}', "invalid_input"],
  ["syntax after duplicate key", '{"mode":"db","value":"blocked","ignored":0,"ignored":1}!', "invalid_json"],
  ["syntax after surrogate", '{"mode":"db","value":"blocked","ignored":"\\uD800"}!', "invalid_json"],
  ["unclosed depth 65", "[".repeat(65), "invalid_json"],
  ["bad token after depth 65", "[".repeat(65) + "null" + "]".repeat(65) + "!", "invalid_json"],
  ["depth 20000", '{"mode":"db","value":"blocked","ignored":' + "[".repeat(20000) + "null" + "]".repeat(20000) + "}", "invalid_input"],
  ["bad token after depth 20000", "[".repeat(20000) + "!", "invalid_json"],
]) {
  await call("db", "blocked", { body, status: 400, error });
  assert.equal(databaseCalls, beforeInvalidInput, "invalid input must not reach the database handler");
  console.log(`request structure ${name}: passed`);
}
await call("fast", "finite", { body: '{"mode":"fast","value":"finite","ignored":1e308}' });
await call("fast", "depth64", { body: '{"mode":"fast","value":"depth64","ignored":' + "[".repeat(63) + "null" + "]".repeat(63) + "}" });
await call("fast", "brackets", { body: JSON.stringify({ mode: "fast", value: "brackets", ignored: "[{".repeat(65) }) });
await call("fast", "surrogates", { body: '{"mode":"fast","value":"surrogates","ignored":"\\uD834\\uDD1E"}' });
await call("fast", "shallow", { body: '{"mode":"fast","value":"shallow","ignored":[' + "null,".repeat(100000) + 'null]}' });
console.log("request structure finite number, depth 64, string brackets, surrogate pair and large shallow array: passed");
console.log("WASM linear memory after large shallow array:", instance.exports.memory.buffer.byteLength);
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
const order = [];
const delayedDB = call("db", "slow").then(() => order.push("slow"));
await call("db", "fast"); order.push("fast");
await delayedDB;
assert.deepEqual(order, ["fast", "slow"]);
await call("env", "unused"); assert.equal(logs, 1);
await call("transaction", "committed");
const beforeCancellation = databaseCalls;
await call("cancel", "never sent", { cancel: true, status: 500 });
assert.equal(databaseCalls, beforeCancellation, "cancellation before registration must prevent I/O");
const concurrentDB = call("db", "other request");
await call("db", "late result", { deadlineMilliseconds: 5, status: 500 });
await concurrentDB;
assert.equal(resources.size, 0);
assert.equal(finished.filter((entry) => entry.cancelled).length, 2);
console.log("host db/env/log, safe rid/lease, one-shot results, memory growth, deadline and shared-instance cancellation: passed");
