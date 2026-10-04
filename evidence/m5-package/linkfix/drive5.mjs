import { Inspector, App } from "<repo>/result-mcp/test-framework/framework.mjs";
const ins = new Inspector(); ins.requestId = 9000; const app = new App(ins); await ins.connect();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const ev = async e => { const r = await ins.send("evaluate", { expression: e }); return r.result ?? r; };
const log = (k, v) => console.log(JSON.stringify({ k, v }));
for (let i = 0; i < 60; i++) { const c = await app.findByProperty("text", "Connected"); if (c.matches?.length) break; await sleep(500); }
await ev("aliasInput.text='alice'"); await ev("addAliasButton.clicked()"); await sleep(1500);
log("after-add", await ev("outcome.text + ' | sel=' + root.selectedAlias + ' | box=' + identityBox.displayText"));
await ev("composer.text='hello from alice'"); await ev("outcome.text=''"); await ev("sendButton.clicked()"); await sleep(1500);
log("post1", await ev("outcome.text")); log("thread1", await ev("JSON.stringify(root.threadPosts)"));
await ev("identityBox.currentIndex=0; identityBox.activated(0)"); await sleep(1000);
log("after-anon", await ev("outcome.text + ' | sel=' + root.selectedAlias + ' | box=' + identityBox.displayText"));
await ev("composer.text='anon post'"); await ev("outcome.text=''"); await ev("sendButton.clicked()"); await sleep(1500);
log("thread2", await ev("JSON.stringify(root.threadPosts)"));
await ev("identityBox.currentIndex=1; identityBox.activated(1)"); await sleep(1000);
log("after-reselect", await ev("outcome.text + ' | sel=' + root.selectedAlias + ' | box=' + identityBox.displayText"));
process.exit(0);
