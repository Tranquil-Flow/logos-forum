import { Inspector, App } from "<repo>/result-mcp/test-framework/framework.mjs";
const ins = new Inspector(); ins.requestId = 5000;
const app = new App(ins);
await ins.connect();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const ev = async e => { const r = await ins.send("evaluate", { expression: e }); return r.result ?? r; };
const log = (k, v) => console.log(JSON.stringify({ t: new Date().toISOString().slice(11,23), k, v }));
for (let i = 0; i < 60; i++) { const c = await app.findByProperty("text", "Connected"); if (c.matches?.length) break; await sleep(500); }
log("connected", await ev("root.ready"));
const step = process.argv[2] || "all";
// Phase A: idle liveness — do the QML Timer echo pings round-trip?
for (let i = 0; i < 4; i++) { await sleep(3000); log("idle-liveness-age-ms", await ev("Date.now()-root.lastBackendOk")); }
// Phase B: echo via watch, result into outcome.text
await ev("outcome.text=''; logos.watch(root.backend.echo('h1-echo'), function(v){outcome.text='ECHO:'+v}, function(e){outcome.text='ECHOERR:'+e})");
for (let i = 0; i < 10; i++) { await sleep(500); const o = await ev("outcome.text"); if (o) { log("echo-outcome", o); break; } if (i==9) log("echo-outcome", "(none after 5s)"); }
// Phase C: createAccount (store-only slot, no cross-module calls)
await ev("outcome.text=''; logos.watch(root.backend.createAccount('h1demo'), function(v){outcome.text='CA:'+v}, function(e){outcome.text='CAERR:'+e})");
for (let i = 0; i < 16; i++) { await sleep(500); const o = await ev("outcome.text"); if (o) { log("createAccount-outcome", o); break; } if (i==15) log("createAccount-outcome", "(none after 8s)"); }
await sleep(1000); log("accounts-prop", await ev("JSON.stringify(root.accounts)")); log("topics-prop", await ev("JSON.stringify(root.topics)"));
if (step === "noxmod") { await sleep(25000); process.exit(0); }
// Phase D: transportStatus (cross-module sync calls: delivery + storage)
await ev("outcome.text=''; logos.watch(root.backend.transportStatus(), function(v){outcome.text='TS:'+v}, function(e){outcome.text='TSERR:'+e})");
for (let i = 0; i < 30; i++) { await sleep(1000); const o = await ev("outcome.text"); if (o) { log("transportStatus-outcome", o); break; } if (i==29) log("transportStatus-outcome", "(none after 30s)"); }
// Phase E: after cross-module call, does a store-only slot still work?
await ev("outcome.text=''; logos.watch(root.backend.createAccount('h1after'), function(v){outcome.text='CA2:'+v}, function(e){outcome.text='CA2ERR:'+e})");
for (let i = 0; i < 16; i++) { await sleep(500); const o = await ev("outcome.text"); if (o) { log("createAccount2-outcome", o); break; } if (i==15) log("createAccount2-outcome", "(none after 8s)"); }
await sleep(1000); log("accounts-prop-2", await ev("JSON.stringify(root.accounts)"));
log("liveness-age-end", await ev("Date.now()-root.lastBackendOk"));
process.exit(0);
