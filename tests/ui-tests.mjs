import { resolve } from "node:path";

// CI sets LOGOS_QT_MCP automatically; for interactive use:
//   nix build .#test-framework -o result-mcp
const root = process.env.LOGOS_QT_MCP || new URL("../result-mcp", import.meta.url).pathname;
const { test, run } = await import(resolve(root, "test-framework/framework.mjs"));

const COMPOSER_PLACEHOLDER = "Write a post (plain text)";
const POST_TEXT = "TECHNICAL TEST DATA: hermetic UI round trip";

async function setProp(app, placeholder, value) {
  const found = await app.inspector.send("findByProperty", {
    property: "placeholderText",
    value: placeholder,
  });
  if (found.error || !found.matches || found.matches.length === 0) {
    throw new Error(`field not found: ${placeholder}`);
  }
  const set = await app.inspector.send("setProperty", {
    objectId: found.matches[0].id,
    property: "text",
    value,
  });
  if (set.error) throw new Error("setProperty failed: " + set.error);
}

async function evaluateText(app, expr) {
  const res = await app.inspector.send("evaluate", { expression: expr });
  return JSON.stringify(res);
}

// Positive control: the module loads and connects.
test("forum_module: UI loads", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Logos Forum"]); },
    { timeout: 20000, interval: 500, description: "UI to load" }
  );
});

test("forum_module: backend connects", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend to connect" }
  );
});

// Store-backed flows run in CI: flake.nix points FORUM_DB_PATH at a writable
// sandbox path. (The earlier "store open kills the ui-host" symptom was the
// plugin missing libsodium — fixed by LINK_LIBRARIES in CMakeLists.txt.)

async function waitOutcome(app, pred, description) {
  let last = "";
  await app.waitFor(async () => {
    const r = await app.inspector.send("evaluate", { expression: "outcome.text" });
    last = typeof r.result === "string" ? r.result : JSON.stringify(r.result ?? r);
    if (!pred(last)) throw new Error("outcome: " + last.slice(0, 200));
  }, { timeout: 15000, interval: 300, description });
  return last;
}

async function evalValue(app, expr) {
  const r = await app.inspector.send("evaluate", { expression: expr });
  return r.result;
}

test("forum_module: alias account is created, selected and listed", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; aliasInput.text = 'ci-alice'" });
  await app.inspector.send("evaluate", { expression: "addAliasButton.clicked()" });
  await waitOutcome(app, (v) => v === "Alias created", "alias created");
  await app.waitFor(async () => {
    const sel = await evalValue(app, "root.selectedAlias + '|' + identityBox.displayText + '|' + JSON.stringify(root.accounts)");
    if (sel !== 'ci-alice|ci-alice|["ci-alice"]') throw new Error("identity state: " + sel);
  }, { timeout: 10000, interval: 300, description: "alias selected + listed" });
});

test("forum_module: topic is created and listed", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; topicInput.text = 'CI Topic'" });
  await app.inspector.send("evaluate", { expression: "createTopicButton.clicked()" });
  await waitOutcome(app, (v) => v === "Topic created", "topic created");
  await app.waitFor(async () => {
    const topics = JSON.stringify(await evalValue(app, "root.topics"));
    if (!topics.includes("CI Topic (0)")) throw new Error("topics: " + topics.slice(0, 200));
  }, { timeout: 10000, interval: 300, description: "topic listed" });
});

// Post path with honest refusal: no transport in CI → visible refusal and the
// composer text is kept (contract §0.2), never a silent success.
test("forum_module: post path refuses honestly without transport", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  await setProp(app, COMPOSER_PLACEHOLDER, POST_TEXT);
  await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
  await app.waitFor(async () => {
    const s = await evaluateText(app, "outcome.text");
    if (!s.includes("Not sent (unavailable)")) throw new Error("outcome: " + s.slice(0, 200));
  }, { timeout: 15000, interval: 500, description: "honest refusal" });
  const found = await app.inspector.send("findByProperty", {
    property: "placeholderText",
    value: COMPOSER_PLACEHOLDER,
  });
  const props = await app.inspector.send("getProperties", { objectId: found.matches[0].id });
  const textProp = props.properties.find((p) => p.name === "text");
  if (!textProp || textProp.value !== POST_TEXT) {
    throw new Error("composer text was discarded on refusal — contract violation");
  }
});

test("forum_module: browsing topics switches the thread", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  // Fresh topic becomes current; a post lands in it.
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; topicInput.text = 'Browse Topic'" });
  await app.inspector.send("evaluate", { expression: "createTopicButton.clicked()" });
  await waitOutcome(app, (v) => v === "Topic created", "topic created");
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; composer.text = 'TECHNICAL TEST DATA: in browse topic'" });
  await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
  await waitOutcome(app, (v) => v.includes("Not sent (unavailable)"), "post stored");
  const browseId = await evalValue(app, "root.currentTopicId");
  // Topics are ordered by recent activity, so the new topic is listed first.
  const first = await evalValue(app, "root.topics[0].split('|')[0]");
  if (first !== browseId) throw new Error("most recent topic not first: " + first);
  // Click the shared "General" topic in the list.
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; topicsList.itemAtIndex(root.topics.findIndex(function (t) { return t.indexOf('|General (') > 0 })).clicked()" });
  await waitOutcome(app, (v) => v === "Opened topic", "topic opened");
  await app.waitFor(async () => {
    const cur = await evalValue(app, "root.currentTopicId");
    const posts = JSON.stringify(await evalValue(app, "root.threadPosts"));
    if (cur === browseId) throw new Error("thread did not switch");
    if (posts.includes("in browse topic")) throw new Error("other topic's post leaked: " + posts.slice(0, 200));
  }, { timeout: 10000, interval: 300, description: "thread switched" });
  // And back: the post is still in its own topic.
  await app.inspector.send("evaluate", {
    expression: "outcome.text = ''; root.backend.openTopic('" + browseId + "')" });
  await app.waitFor(async () => {
    const posts = JSON.stringify(await evalValue(app, "root.threadPosts"));
    if (!posts.includes("in browse topic")) throw new Error("threadPosts: " + posts.slice(0, 200));
  }, { timeout: 10000, interval: 300, description: "thread switched back" });
});

// Per-post state is visible in the thread: the refused post is stored and
// shown as [failed] (retryable), never silently dropped.
test("forum_module: refused post is stored and shown as failed in the thread", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; composer.text = 'TECHNICAL TEST DATA: thread state'" });
  await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
  await waitOutcome(app, (v) => v.includes("Not sent (unavailable)"), "honest refusal");
  await app.waitFor(async () => {
    const posts = JSON.stringify(await evalValue(app, "root.threadPosts"));
    if (!posts.includes("[failed]: TECHNICAL TEST DATA: thread state")) {
      throw new Error("threadPosts: " + posts.slice(0, 300));
    }
  }, { timeout: 10000, interval: 300, description: "failed post in thread" });
});

// The three identity options are distinct in the thread: alias + key id,
// key id only (alias hidden, same key), anonymous (one-time key).
test("forum_module: identity modes — alias + id, id only, anonymous", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  const post = async (text) => {
    await app.inspector.send("evaluate", { expression: "outcome.text = ''; composer.text = '" + text + "'" });
    await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
    await waitOutcome(app, (v) => v.includes("Not sent (unavailable)"), "refusal for " + text);
  };
  const rowFor = async (text) => {
    let row = "";
    await app.waitFor(async () => {
      const rows = await evalValue(app, "JSON.stringify(root.threadPosts)");
      row = (JSON.parse(rows) || []).find((r) => r.endsWith("]: " + text)) || "";
      if (!row) throw new Error("no row for " + text + " in " + String(rows).slice(0, 300));
    }, { timeout: 10000, interval: 300, description: "row for " + text });
    return row;
  };
  await app.inspector.send("evaluate", { expression: "aliasInput.text = 'ci-modes'; addAliasButton.clicked()" });
  let uid = "";
  await app.waitFor(async () => {
    uid = await evalValue(app, "root.selectedAlias === 'ci-modes' ? root.selectedUid : ''");
    if (!/^[0-9a-f]{16}$/.test(uid)) throw new Error("selectedUid: " + uid);
  }, { timeout: 10000, interval: 300, description: "account selected with key id" });

  await post("TECHNICAL TEST DATA: alias mode");
  const aliasRow = await rowFor("TECHNICAL TEST DATA: alias mode");
  if (!aliasRow.startsWith("ci-modes · id " + uid + " [failed]")) throw new Error("alias row: " + aliasRow);

  await app.inspector.send("evaluate", { expression: "hideAliasBox.toggle(); hideAliasBox.toggled()" });
  await app.waitFor(async () => {
    const h = await evalValue(app, "root.aliasHidden + '|' + identityHint.text");
    if (!h.startsWith("true|Identity: id " + uid + " (alias hidden)")) throw new Error("hint: " + h);
  }, { timeout: 10000, interval: 300, description: "alias hidden" });
  await post("TECHNICAL TEST DATA: id-only mode");
  const idRow = await rowFor("TECHNICAL TEST DATA: id-only mode");
  if (!idRow.startsWith("id " + uid + " [failed]") || idRow.includes("ci-modes")) throw new Error("id-only row: " + idRow);

  await app.inspector.send("evaluate", { expression: "hideAliasBox.toggle(); hideAliasBox.toggled(); root.backend.selectIdentity('')" });
  await app.waitFor(async () => {
    const h = await evalValue(app, "root.selectedAlias + '|' + root.aliasHidden + '|' + hideAliasBox.enabled");
    if (h !== "|false|false") throw new Error("anonymous state: " + h);
  }, { timeout: 10000, interval: 300, description: "anonymous selected" });
  await post("TECHNICAL TEST DATA: anonymous mode");
  const anonRow = await rowFor("TECHNICAL TEST DATA: anonymous mode");
  if (!/^id [0-9a-f]{16} \[failed\]/.test(anonRow) || anonRow.includes(uid)) throw new Error("anonymous row: " + anonRow);
});

// Key rotation: manual ("New key now") and automatic (every N posts). Earlier
// posts keep their key id; later posts carry the new one.
test("forum_module: alias key rotation — manual, by posts and by age", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; aliasInput.text = 'ci-rotate'; addAliasButton.clicked()" });
  let uid1 = "";
  await app.waitFor(async () => {
    uid1 = await evalValue(app, "root.selectedAlias === 'ci-rotate' && rotateButton.visible ? root.selectedUid : ''");
    if (!/^[0-9a-f]{16}$/.test(uid1)) throw new Error("selectedUid: " + uid1);
  }, { timeout: 10000, interval: 300, description: "alias selected, rotation offered" });
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; rotateButton.clicked()" });
  let uid2 = "";
  await app.waitFor(async () => {
    uid2 = await evalValue(app, "root.selectedUid");
    if (!/^[0-9a-f]{16}$/.test(uid2) || uid2 === uid1) throw new Error("uid after rotation: " + uid2);
    const info = await evalValue(app, "root.rotationInfo");
    if (!info.includes("rotated 1 time")) throw new Error("rotationInfo: " + info);
  }, { timeout: 10000, interval: 300, description: "manual rotation" });
  // Automatic: a new key every 5 posts (stored posts count; they are sent
  // later with the same signature).
  await app.inspector.send("evaluate", { expression: "autoRotateBox.currentIndex = 1; autoRotateBox.activated(1)" });
  await app.waitFor(async () => {
    const v = await evalValue(app, "root.rotateEvery + '|' + root.rotationInfo");
    if (!v.startsWith("5|") || !v.includes("new key every 5 posts")) throw new Error("auto: " + v);
  }, { timeout: 10000, interval: 300, description: "automatic rotation set" });
  for (let i = 1; i <= 5; i++) {
    await app.inspector.send("evaluate", { expression: "outcome.text = ''; composer.text = 'TECHNICAL TEST DATA: rotation " + i + "'" });
    await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
    await waitOutcome(app, (v) => v.includes("Not sent (unavailable)"), "stored post " + i);
  }
  await app.waitFor(async () => {
    const v = await evalValue(app, "root.selectedUid + '|' + root.rotationInfo");
    if (v.startsWith(uid2) || !v.includes("rotated 2 times") || !v.includes("0 posts on this key")) {
      throw new Error("after 5 posts: " + v);
    }
  }, { timeout: 10000, interval: 300, description: "automatic rotation after 5 posts" });
  const rows = JSON.parse(await evalValue(app, "JSON.stringify(root.threadPosts)"));
  const r5 = rows.find((r) => r.endsWith("]: TECHNICAL TEST DATA: rotation 5")) || "";
  if (!r5.startsWith("ci-rotate · id " + uid2)) throw new Error("5th post not on the previous key: " + r5);
  // By age as well: both policies are shown; either one rotates.
  await app.inspector.send("evaluate", { expression: "autoRotateDaysBox.currentIndex = 2; autoRotateDaysBox.activated(2)" });
  await app.waitFor(async () => {
    const v = await evalValue(app, "root.rotateDays + '|' + root.rotationInfo");
    if (!v.startsWith("7|") || !v.includes("new key every 5 posts or 7 days")) throw new Error("age: " + v);
  }, { timeout: 10000, interval: 300, description: "rotation by age set" });
  await app.inspector.send("evaluate", { expression: "autoRotateBox.currentIndex = 0; autoRotateBox.activated(0); autoRotateDaysBox.currentIndex = 0; autoRotateDaysBox.activated(0)" });
  await app.waitFor(async () => {
    const v = await evalValue(app, "root.rotateEvery + '|' + root.rotateDays + '|' + root.rotationInfo");
    if (!v.startsWith("0|0|") || !v.includes("rotation: manual")) throw new Error("off: " + v);
  }, { timeout: 10000, interval: 300, description: "rotation back to manual" });
  await app.inspector.send("evaluate", { expression: "root.backend.selectIdentity('')" });
});

// Search filters topics and the open thread locally; clearing restores both.
test("forum_module: search filters topics and posts", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; topicInput.text = 'Zebra Search Topic'" });
  await app.inspector.send("evaluate", { expression: "createTopicButton.clicked()" });
  await waitOutcome(app, (v) => v === "Topic created", "topic created");
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; composer.text = 'TECHNICAL TEST DATA: needle-alpha'" });
  await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
  await waitOutcome(app, (v) => v.includes("Not sent (unavailable)"), "post stored");
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; composer.text = 'TECHNICAL TEST DATA: other words'" });
  await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
  await waitOutcome(app, (v) => v.includes("Not sent (unavailable)"), "post stored");
  await app.inspector.send("evaluate", { expression: "searchInput.text = 'needle-alpha'" });
  await app.waitFor(async () => {
    const t = JSON.parse(await evalValue(app, "JSON.stringify(root.topics)"));
    const p = JSON.parse(await evalValue(app, "JSON.stringify(root.threadPosts)"));
    if (t.length !== 1 || !t[0].includes("|Zebra Search Topic (")) throw new Error("topics: " + JSON.stringify(t));
    if (p.length !== 1 || !p[0].endsWith("needle-alpha")) throw new Error("posts: " + JSON.stringify(p));
  }, { timeout: 10000, interval: 300, description: "filtered" });
  await app.inspector.send("evaluate", { expression: "searchInput.text = 'no-such-words-xyz'" });
  await app.waitFor(async () => {
    const n = await evalValue(app, "root.topics.length + '|' + topicsList.count");
    if (n !== "0|0") throw new Error("empty filter: " + n);
  }, { timeout: 10000, interval: 300, description: "nothing matches" });
  await app.inspector.send("evaluate", { expression: "searchInput.text = ''" });
  await app.waitFor(async () => {
    const n = await evalValue(app, "root.topics.length + '|' + root.threadPosts.length");
    const [topics, posts] = n.split("|").map(Number);
    if (topics < 2 || posts < 2) throw new Error("cleared: " + n);
  }, { timeout: 10000, interval: 300, description: "filter cleared" });
});

// Logos Storage snapshots: saving needs a connection (not offered offline);
// a restore request without a CID is refused before anything is fetched.
test("forum_module: storage snapshot controls are honest offline", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  await app.waitFor(async () => {
    const v = await evalValue(app, "archiveButton.visible + '|' + root.archiveState");
    if (v !== "false|") throw new Error("archive offline: " + v);
  }, { timeout: 10000, interval: 300, description: "save not offered offline" });
  // Send once, then wait for the asynchronous reply (re-sending would clear
  // a reply that arrives between two polls).
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; logos.watch(root.backend.restoreSnapshot('not a snapshot'), function (v) { outcome.text = v }, function (e) { outcome.text = 'Error: ' + e }); 'sent'" });
  await app.waitFor(async () => {
    const r = await evalValue(app, "outcome.text");
    if (r !== "error: no snapshot CID found") throw new Error("restore: " + r);
  }, { timeout: 15000, interval: 300, description: "restore without CID refused" });
});

// Without a configured transport the user is OFFERED an explicit network
// join (never automatic). CI has no network, so the join itself is not clicked.
test("forum_module: network join is offered, not automatic", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  await app.waitFor(async () => {
    const v = await evalValue(app, "root.connection + '|' + connectButton.visible + '|' + connectButton.enabled + '|' + historyButton.visible");
    // Offered while no network was chosen (also after a refused post); the
    // history action needs a connection, so it is not offered yet.
    if (v !== "offline|true|true|false") throw new Error("connect offer: " + v);
  }, { timeout: 10000, interval: 300, description: "connect button offered" });
});

// Transport status reports presence honestly (no privacy claims).
test("forum_module: transport status honest", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  // The diagnostics sit behind "Network details" (clicked like a user). The
  // headless test window never renders a frame, so the layout does not
  // re-position buttons that become visible: both diagnostics buttons stay
  // stacked at one point and a synthesised mouse click lands on the wrong
  // one (evidence: integration-toggle-5-FAIL.log). Fire the button's own click signal.
  await app.click("Network details", { exact: true });
  await app.waitFor(async () => {
    if (await evalValue(app, "String(checkButton.visible)") !== "true") throw new Error("details folded");
  }, { timeout: 10000, interval: 300, description: "network details shown" });
  await evalValue(app, "checkButton.clicked(), 'ok'");
  await app.waitFor(async () => {
    const s = await evaluateText(app, "outcome.text");
    for (const needle of ["delivery:", "storage:", "privacy: unverified"]) {
      if (!s.includes(needle)) throw new Error(`missing ${needle} in: ` + s.slice(0, 200));
    }
  }, { timeout: 20000, interval: 500, description: "honest transport status" });
});

run();
