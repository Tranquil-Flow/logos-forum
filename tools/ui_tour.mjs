#!/usr/bin/env node
// LP-0026 Forum — UI tour: drives one running instance through the main
// screens and saves a PNG per step (for review, README and the demo).
//   node tools/ui_tour.mjs --port 3768 --out <dir> [--live] [--features]
// --live also joins logos.dev and loads history (public network).
// --features (offline, local store only): alias with key rotation, topics
// with unread counts, search, and the narrow-window layout.
import net from "node:net";
import fs from "node:fs";
const args = process.argv.slice(2);
function arg(name, dflt) { const i = args.indexOf("--" + name); return i >= 0 ? args[i + 1] : dflt; }
const port = parseInt(arg("port", "3768"), 10);
const out = arg("out", ".");
const live = args.includes("--live");
const features = args.includes("--features");

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
      }, 60000);
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

const c = new Client(port);
const ev = async (e) => String((await c.send("evaluate", { expression: e })).result ?? "");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function shot(name) {
  const r = await c.send("screenshot", {});
  const img = r.image || (r.result && r.result.image);
  if (!img) throw new Error("screenshot failed: " + JSON.stringify(r).slice(0, 200));
  fs.writeFileSync(`${out}/${name}.png`, Buffer.from(img, "base64"));
  console.log("saved", name);
}
async function setText(placeholder, text) {
  const f = await c.send("findByProperty", { property: "placeholderText", value: placeholder });
  if (!f.matches || !f.matches.length) throw new Error("no field: " + placeholder);
  await c.send("setProperty", { objectId: f.matches[0].id, property: "text", value: text });
}
try {
  await c.connect();
  await waitFor(async () => c.expectTexts(["Module ready"]), 30000, "backend");
  await sleep(1500);
  await shot("01-first-start");
  const placeholders = JSON.parse(await ev("JSON.stringify(['x'])"));
  void placeholders;
  if (live) {
    await c.send("evaluate", { expression: "connectButton.clicked()" });
    await sleep(800);
    await shot("02-connecting");
    await waitFor(async () => { if ((await ev("root.connection")) !== "connected") throw new Error("not yet"); }, 180000, "connected");
    await sleep(3000);
    await shot("03-connected");
    await c.send("evaluate", { expression: "historyButton.clicked()" });
    await waitFor(async () => { const h = await ev("root.historyState"); if (!/^loaded |could not reach/.test(h)) throw new Error(h); }, 120000, "history");
    await sleep(1000);
    await shot("04-history-loaded");
  }
  if (features) {
    const call = async (expr) => {
      await c.send("evaluate", { expression: "outcome.text = ''; logos.watch(" + expr + ", function (v) { outcome.text = String(v) }, function (e) { outcome.text = 'Error: ' + e })" });
      let v = "";
      await waitFor(async () => { v = await ev("outcome.text"); if (!v) throw new Error("no reply: " + expr); }, 15000, expr);
      return v;
    };
    await call("root.backend.createAccount('tour-alias')");
    await call("root.backend.selectIdentity('tour-alias')");
    await call("root.backend.setAutoRotate(10)");
    await call("root.backend.setAutoRotateDays(7)");
    await call("root.backend.rotateKey()");
    const tid = await call("root.backend.createTopic('Tour: storage snapshots')");
    await call("root.backend.createTopic('Tour: key rotation')");
    await call("root.backend.openTopic('" + tid + "')");
    await c.send("evaluate", { expression: "composer.text = 'TECHNICAL TEST DATA: written offline, kept for sending'; sendButton.clicked()" });
    await sleep(1500);
    await shot("05-identity-rotation");
    await c.send("evaluate", { expression: "searchInput.text = 'rotation'" });
    await sleep(1200);
    await shot("06-search");
    await c.send("evaluate", { expression: "searchInput.text = ''" });
    await sleep(800);
    // Narrow layout: the forum view at 700 px (the host window keeps its
    // size; the view's own width drives the layout).
    await c.send("evaluate", { expression: "root.width = 700" });
    await sleep(1200);
    console.log("compact at 700px:", await ev("root.compact"));
    await shot("07-narrow");
  }
  console.log(JSON.stringify({ state: await ev("root.transportState"), history: await ev("root.historyState"), posts: await ev("JSON.stringify(threadPosts)") }).slice(0, 1500));
} catch (e) {
  console.error("tour error:", e.message || e);
  try { await shot("99-error"); } catch {}
  process.exitCode = 1;
} finally { c.disconnect(); }
