#!/usr/bin/env node
// LP-0026 Forum — in-app Logos Storage snapshot driver.
//   --phase save     (author) connect to logos.dev, post two --text posts through
//                    Mix, press "Save snapshot", wait until the snapshot is saved
//                    and its announcement is sent; prints the announcement.
//   --phase restore  (fresh reader, never joins Delivery) restore from the
//                    --announcement text; every post must verify and render.
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
      if (/^FATAL /.test(String(e && e.message))) throw e;  // a final failure state
      lastErr = e;
      await new Promise((r) => setTimeout(r, 500));
    }
  }
  throw new Error(`timeout waiting for ${description}: ${lastErr && lastErr.message}`);
}

const announcement = arg("announcement", "");
const result = { status: "FAIL", phase, text, timeline: [] };
const mark = (what, extra = {}) => result.timeline.push({ t_s: elapsed(), what, ...extra });
const c = new Client(port);
const evalStr = async (e) => String((await c.send("evaluate", { expression: e })).result ?? "");
const rows = async () => JSON.parse((await evalStr("JSON.stringify(root.threadPosts)")) || "[]");
const texts = [text + " (1/2)", text + " (2/2)"];
try {
  await c.connect();
  await waitFor(async () => c.expectTexts(["Module ready"]), 30000, "backend");
  // Test posts go to the shared Sandbox topic, never General.
  await c.send("evaluate", { expression: SANDBOX });
  await waitFor(async () => {
    const r = await c.send("evaluate", { expression: "root.currentTopicTitle" });
    if (r.result !== "Sandbox") throw new Error("not in Sandbox: " + JSON.stringify(r));
  }, 10000, "Sandbox open");
  if (phase === "save") {
    await c.send("evaluate", { expression: "connectButton.clicked()" });
    mark("connect clicked");
    await waitFor(async () => {
      const s = await evalStr("transportState");
      if (!/^transport ready/.test(s)) throw new Error(s.slice(0, 200));
    }, 180000, "transport ready");
    mark("transport ready");
    await new Promise((r) => setTimeout(r, 20000));  // let the Mix pool settle
    for (const t of texts) {
      await c.send("evaluate", { expression: "composer.text = " + JSON.stringify(t) + "; sendButton.clicked()" });
      mark("posted", { text: t });
      await new Promise((r) => setTimeout(r, 3000));
    }
    await waitFor(async () => {
      const r = await rows();
      for (const t of texts) if (!r.some((x) => x.endsWith("[sent]: " + t))) throw new Error("not sent yet: " + t);
    }, 300000, "both posts sent through Mix");
    mark("posts sent");
    await waitFor(async () => {
      if (await evalStr("archiveButton.visible") !== "true") throw new Error("archive button hidden");
    }, 10000, "archive button");
    await c.send("evaluate", { expression: "archiveButton.clicked()" });
    mark("save snapshot clicked");
    await waitFor(async () => {
      const s = await evalStr("root.archiveState");
      if (/did not start|refused|did not finish/.test(s)) throw new Error("FATAL " + s);
      if (!/^saved /.test(s)) throw new Error(s.slice(0, 200));
    }, 120000, "snapshot saved");
    result.archive_state = await evalStr("root.archiveState");
    mark("snapshot saved", { state: result.archive_state });
    // The announcement of THIS snapshot (a fresh profile may also have
    // received earlier runs' announcements from the network's store).
    const cidPrefix = (/\(([A-Za-z0-9]+)…\)/.exec(result.archive_state) || [])[1] || "";
    if (!cidPrefix) throw new Error("no CID in archive state: " + result.archive_state);
    let row = "";
    await waitFor(async () => {
      row = (await rows()).find((x) => x.includes("]: Snapshot of this topic on Logos Storage") &&
                                      x.includes("\ncid: " + cidPrefix)) || "";
      if (!/ \[sent\]: /.test(row)) throw new Error("announcement: " + row.slice(0, 120));
    }, 300000, "announcement sent through Mix");
    result.announcement = row.slice(row.indexOf("]: ") + 3);
    result.announcement_author = row.slice(0, row.indexOf(" ["));
    mark("announcement sent");
  } else {
    result.connection = await evalStr("root.connection");  // must stay offline
    result.initial_thread = await rows();
    await c.send("evaluate", { expression: "logos.watch(root.backend.restoreSnapshot(" + JSON.stringify(announcement) + "), function (v) { outcome.text = v }, function (e) { outcome.text = 'Error: ' + e })" });
    mark("restore requested");
    await waitFor(async () => {
      const s = await evalStr("root.archiveState");
      if (/could not fetch|could not reach|refused|did not start|not a forum snapshot/.test(s)) throw new Error("FATAL " + s);
      if (!/^restored /.test(s)) throw new Error(s.slice(0, 200));
    }, 360000, "restore finished");
    result.archive_state = await evalStr("root.archiveState");
    mark("restored", { state: result.archive_state });
    const m = /: (\d+) new posts?, (\d+) already here, (\d+) rejected/.exec(result.archive_state);
    if (!m || Number(m[1]) < 2 || Number(m[3]) !== 0) throw new Error("unexpected restore counts: " + result.archive_state);
    await waitFor(async () => {
      const r = await rows();
      for (const t of texts) if (!r.some((x) => x.endsWith("[received]: " + t))) throw new Error("missing " + t);
    }, 10000, "restored posts rendered");
    result.connection_after = await evalStr("root.connection");
    if (result.connection_after !== "offline") throw new Error("reader joined Delivery: " + result.connection_after);
  }
  result.thread = await rows();
  result.status = "PASS";
} catch (e) {
  result.error = String((e && e.message) || e);
  try { result.last_archive_state = await evalStr("root.archiveState"); result.last_state = await evalStr("transportState"); result.thread = await rows(); } catch {}
} finally {
  c.disconnect();
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.status === "PASS" ? 0 : 1);
}
