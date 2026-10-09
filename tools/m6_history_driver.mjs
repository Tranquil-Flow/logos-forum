#!/usr/bin/env node
// LP-0026 Forum — live offline-reader driver (logos.dev). One instance at a time:
//   --phase post   connect, wait until connected, post --text, wait propagated
//   --phase fetch  (fresh store, started after the poster quit) connect and
//                  wait for --text to appear in the thread as [received]
import net from "node:net";
const SANDBOX = "root.backend.openTopic(root.topics.filter(function (t) { return t.indexOf('|Sandbox (') > 0 })[0].split('|')[0])";
const args = process.argv.slice(2);
function arg(name, dflt) { const i = args.indexOf("--" + name); return i >= 0 ? args[i + 1] : dflt; }
const port = parseInt(arg("port", "3768"), 10);
const phase = arg("phase", "post");
const text = arg("text", "");
const waitMs = parseInt(arg("wait", "300000"), 10);
const t0 = Date.now();
const elapsed = () => Math.round((Date.now() - t0) / 1000);

class Client {
  constructor(port) {
    this.port = port;
    this.id = 0;
    this.pending = new Map();
    this.buffer = "";
    this.socket = null;
  }
  connect() {
    return new Promise((resolve, reject) => {
      const sock = net.createConnection({ host: "localhost", port: this.port });
      sock.once("connect", () => { this.socket = sock; resolve(); });
      sock.once("error", (e) => reject(new Error(`inspector :${this.port}: ${e.message}`)));
      sock.on("data", (chunk) => {
        this.buffer += chunk.toString("utf-8");
        let idx;
        while ((idx = this.buffer.indexOf("\n")) >= 0) {
          const line = this.buffer.slice(0, idx).trim();
          this.buffer = this.buffer.slice(idx + 1);
          if (!line) continue;
          try {
            const msg = JSON.parse(line);
            const p = this.pending.get(String(msg.id));
            if (p) { this.pending.delete(String(msg.id)); p.resolve(msg); }
          } catch { /* skip malformed */ }
        }
      });
    });
  }
  send(command, params = {}) {
    const id = ++this.id;
    const payload = JSON.stringify({ id, command, params }) + "\n";
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`timeout: ${command} :${this.port}`));
      }, 20000);
      this.pending.set(String(id), { resolve, timer });
      this.socket.write(payload);
    });
  }
  async findByText(text) {
    const res = await this.send("findByProperty", { property: "text", value: text });
    return res;
  }
  async expectTexts(texts) {
    const missing = [];
    for (const t of texts) {
      const res = await this.findByText(t);
      if (res.error || !res.matches || res.matches.length === 0) missing.push(t);
    }
    if (missing.length) throw new Error(`texts not found: ${JSON.stringify(missing)}`);
  }
  async click(text) {
    const res = await this.send("findAndClick", { text });
    if (res.error) throw new Error(`click(${text}): ${res.error}`);
  }
  disconnect() { if (this.socket) this.socket.destroy(); }
}

async function waitFor(fn, timeoutMs, description) {
  const start = Date.now();
  let lastErr;
  while (Date.now() - start < timeoutMs) {
    try { await fn(); return; } catch (e) {
      lastErr = e;
      await new Promise((r) => setTimeout(r, 500));
    }
  }
  throw new Error(`timeout waiting for ${description}: ${lastErr && lastErr.message}`);
}

const result = { status: "FAIL", phase, text, timeline: [] };
const mark = (what, extra = {}) => result.timeline.push({ t_s: elapsed(), what, ...extra });
const c = new Client(port);
const evalStr = async (e) => String((await c.send("evaluate", { expression: e })).result ?? "");
try {
  await c.connect();
  await waitFor(async () => c.expectTexts(["Module ready"]), 30000, "backend");
  // Test posts go to the shared Sandbox topic, never General.
  await c.send("evaluate", { expression: SANDBOX });
  await waitFor(async () => {
    const r = await c.send("evaluate", { expression: "root.currentTopicTitle" });
    if (r.result !== "Sandbox") throw new Error("not in Sandbox: " + JSON.stringify(r));
  }, 10000, "Sandbox open");
  result.initial_thread = await evalStr("JSON.stringify(threadPosts)");
  await c.send("evaluate", { expression: "connectButton.clicked()" });
  mark("connect clicked");
  await waitFor(async () => {
    const s = await evalStr("transportState");
    if (!/^transport ready/.test(s)) throw new Error(s.slice(0, 200));
  }, 180000, "transport ready");
  mark("transport ready", { state: await evalStr("transportState") });
  if (phase === "post") {
    await new Promise((r) => setTimeout(r, 25000));  // let Mix pool + peers settle
    const f = await c.send("findByProperty", { property: "placeholderText", value: "Write a post (plain text)" });
    await c.send("setProperty", { objectId: f.matches[0].id, property: "text", value: text });
    await c.send("evaluate", { expression: "sendButton.clicked()" });
    mark("post clicked");
    let retries = 0;
    await waitFor(async () => {
      const s = await evalStr("transportState");
      if (/propagated|validated by network/i.test(s)) return;
      if (/FAILED/.test(s) && retries < 10) { retries++; await new Promise((r) => setTimeout(r, 10000)); await c.click("Retry stored").catch(() => {}); mark("retry", { n: retries, after: s.slice(0, 200) }); }
      throw new Error(s.slice(0, 200));
    }, waitMs, "propagated");
    mark("propagated");
    await new Promise((r) => setTimeout(r, 15000));  // let store nodes persist it
  } else {
    await waitFor(async () => {
      const rows = await evalStr("JSON.stringify(threadPosts)");
      if (!rows.includes("[received]: " + text)) throw new Error("thread: " + rows.slice(0, 300));
    }, waitMs, "history row");
    mark("history row rendered");
    result.history_state_after_catchup = await evalStr("root.historyState");
    // Explicit older-history request against a logos.dev store node.
    await c.send("evaluate", { expression: "historyButton.clicked()" });
    mark("load older posts clicked");
    try {
      await waitFor(async () => {
        const h = await evalStr("root.historyState");
        if (!/^loaded |could not reach/.test(h)) throw new Error(h.slice(0, 200));
      }, 120000, "older history result");
    } catch (e) { result.load_history_error = String(e.message || e); }
    result.history_state_after_load = await evalStr("root.historyState");
    mark("load older posts finished", { state: result.history_state_after_load });
  }
  result.thread = await evalStr("JSON.stringify(threadPosts)");
  result.status = "PASS";
} catch (e) {
  result.error = String((e && e.message) || e);
  try { result.last_state = await evalStr("transportState"); result.thread = await evalStr("JSON.stringify(threadPosts)"); } catch {}
} finally {
  c.disconnect();
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.status === "PASS" ? 0 : 1);
}
