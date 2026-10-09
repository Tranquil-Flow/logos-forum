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

// Offline, a post is stored and waits for the user to connect; it is sent
// through Mix only (Required, no fallback). The UI says so plainly, and the
// composer is cleared because the text now lives in the store (keeping it in
// both places would invite a duplicate) — never a silent success or loss.
test("forum_module: offline post is saved and waits for the connection", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  await setProp(app, COMPOSER_PLACEHOLDER, POST_TEXT);
  await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
  await app.waitFor(async () => {
    const s = await evaluateText(app, "outcome.text");
    if (!s.includes("Saved — it will be sent through Mix")) throw new Error("outcome: " + s.slice(0, 200));
  }, { timeout: 15000, interval: 500, description: "saved, waiting" });
  await app.waitFor(async () => {
    const posts = JSON.stringify(await evalValue(app, "root.threadPosts"));
    if (!posts.includes("[pending]: " + POST_TEXT)) throw new Error("threadPosts: " + posts.slice(0, 300));
  }, { timeout: 10000, interval: 300, description: "post stored, waiting" });
  const found = await app.inspector.send("findByProperty", {
    property: "placeholderText",
    value: COMPOSER_PLACEHOLDER,
  });
  const props = await app.inspector.send("getProperties", { objectId: found.matches[0].id });
  const textProp = props.properties.find((p) => p.name === "text");
  if (!textProp || textProp.value !== "") {
    throw new Error("composer still holds the stored post's text: " + JSON.stringify(textProp && textProp.value));
  }
});

// The signed body is limited in UTF-8 bytes, so the composer counts bytes:
// 2100 Cyrillic letters are 4200 bytes, over the limit even though they are
// fewer than 4096 characters. Send is disabled and nothing is stored.
test("forum_module: post limit is counted in bytes", async (app) => {
  await setProp(app, COMPOSER_PLACEHOLDER, "ж".repeat(2100));
  await app.waitFor(async () => {
    const v = await evalValue(app, "sendButton.enabled + '|' + root.utf8Bytes(composer.text)");
    if (v !== "false|4200") throw new Error("send/bytes: " + v);
  }, { timeout: 5000, interval: 200, description: "send disabled over the byte limit" });
  await app.expectTexts(["4200 / 4096 bytes"]);
  const r = await evalValue(app, "root.utf8Bytes('a\u00e9\u20ac\ud83d\ude00')");
  if (String(r) !== "10") throw new Error("utf8Bytes: " + r);
  await setProp(app, COMPOSER_PLACEHOLDER, "");
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
  await waitOutcome(app, (v) => v.startsWith("Saved — it will be sent through Mix"), "post stored");
  const browseId = await evalValue(app, "root.currentTopicId");
  // Topics are ordered by recent activity, so the new topic is listed first.
  const first = await evalValue(app, "root.topics[0].split('|')[0]");
  if (first !== browseId) throw new Error("most recent topic not first: " + first);
  // Both shared topics are always listed: General and Sandbox (trial posts).
  const listed = await evalValue(app, "JSON.stringify(root.topics)");
  if (!listed.includes("|General (") || !listed.includes("|Sandbox (")) throw new Error("shared topics: " + listed.slice(0, 300));
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

// Per-post state is visible in the thread: the offline post is stored and
// shown as [pending] (waiting to send), never silently dropped.
test("forum_module: offline post is stored and shown as waiting in the thread", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; composer.text = 'TECHNICAL TEST DATA: thread state'" });
  await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
  await waitOutcome(app, (v) => v.startsWith("Saved — it will be sent through Mix"), "saved, waiting");
  await app.waitFor(async () => {
    const posts = JSON.stringify(await evalValue(app, "root.threadPosts"));
    if (!posts.includes("[pending]: TECHNICAL TEST DATA: thread state")) {
      throw new Error("threadPosts: " + posts.slice(0, 300));
    }
  }, { timeout: 10000, interval: 300, description: "waiting post in thread" });
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
    await waitOutcome(app, (v) => v.startsWith("Saved — it will be sent through Mix"), "saved: " + text);
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
  if (!aliasRow.startsWith("ci-modes · id " + uid + " [pending]")) throw new Error("alias row: " + aliasRow);

  await app.inspector.send("evaluate", { expression: "hideAliasBox.toggle(); hideAliasBox.toggled()" });
  await app.waitFor(async () => {
    const h = await evalValue(app, "root.aliasHidden + '|' + identityHint.text");
    if (!h.startsWith("true|Identity: id " + uid + " (alias hidden)")) throw new Error("hint: " + h);
  }, { timeout: 10000, interval: 300, description: "alias hidden" });
  await post("TECHNICAL TEST DATA: id-only mode");
  const idRow = await rowFor("TECHNICAL TEST DATA: id-only mode");
  if (!idRow.startsWith("id " + uid + " [pending]") || idRow.includes("ci-modes")) throw new Error("id-only row: " + idRow);

  await app.inspector.send("evaluate", { expression: "hideAliasBox.toggle(); hideAliasBox.toggled(); root.backend.selectIdentity('')" });
  await app.waitFor(async () => {
    const h = await evalValue(app, "root.selectedAlias + '|' + root.aliasHidden + '|' + hideAliasBox.enabled");
    if (h !== "|false|false") throw new Error("anonymous state: " + h);
  }, { timeout: 10000, interval: 300, description: "anonymous selected" });
  await post("TECHNICAL TEST DATA: anonymous mode");
  const anonRow = await rowFor("TECHNICAL TEST DATA: anonymous mode");
  if (!/^id [0-9a-f]{16} \[pending\]/.test(anonRow) || anonRow.includes(uid)) throw new Error("anonymous row: " + anonRow);
});

// An alias may try to imitate a key id or a post state. Aliases are printable
// ASCII (no look-alike or invisible characters), their brackets are shown as
// parentheses, the real key id is drawn on its own (never elided), and
// nothing is read as rich text.
test("forum_module: an alias cannot fake a key id or a state", async (app) => {
  const fake = "eve - id 0123456789abcdef [sent]: <b>x</b>";
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; aliasInput.text = " + JSON.stringify(fake) });
  await app.inspector.send("evaluate", { expression: "addAliasButton.clicked()" });
  let uid = "";
  await app.waitFor(async () => {
    uid = await evalValue(app, "root.selectedAlias === " + JSON.stringify(fake) + " && !root.aliasHidden ? root.selectedUid : ''");
    if (!/^[0-9a-f]{16}$/.test(uid)) throw new Error("selectedUid: " + uid);
  }, { timeout: 10000, interval: 300, description: "spoofing alias selected" });
  const text = "TECHNICAL TEST DATA: alias spoof check";
  await app.inspector.send("evaluate", { expression: "composer.text = '" + text + "'; sendButton.clicked()" });
  let parts = null;
  await app.waitFor(async () => {
    const rows = JSON.parse(await evalValue(app, "JSON.stringify(root.threadPosts)")) || [];
    const row = rows.find((r) => r.endsWith("]: " + text));
    if (!row) throw new Error("no row yet");
    parts = JSON.parse(await evalValue(app, "JSON.stringify(root.rowParts(" + JSON.stringify(row) + "))"));
  }, { timeout: 10000, interval: 300, description: "spoof row" });
  if (parts.keyId !== "id " + uid) throw new Error("key id: " + JSON.stringify(parts));
  if (parts.state !== "pending") throw new Error("state: " + JSON.stringify(parts));
  if (parts.body !== text) throw new Error("body: " + JSON.stringify(parts));
  if (parts.alias !== "eve - id 0123456789abcdef (sent): <b>x</b>") throw new Error("alias: " + JSON.stringify(parts));

  // A line separator (would break the row parser), a right-to-left override
  // (would reorder what is shown) and a look-alike dot: refused.
  const sneaky = "mal\u2028lory\u202e \u22c5 id 0123456789abcdef";
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; aliasInput.text = " + JSON.stringify(sneaky) + "; addAliasButton.clicked()" });
  await waitOutcome(app, (v) => v.includes("printable ASCII"), "non-ASCII alias refused");
  const accounts = await evalValue(app, "JSON.stringify(root.accounts)");
  if (accounts.includes("lory")) throw new Error("accounts: " + accounts);
  await app.inspector.send("evaluate", { expression: "root.backend.selectIdentity('')" });
});

// Key rotation: manual ("New key now") and automatic (every N posts). Earlier
// posts keep their key id; later posts carry the new one.
test("forum_module: alias key rotation — manual, by posts and by age", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  // Rotation lives in the identity panel, opened from "Posting as".
  await app.inspector.send("evaluate", { expression: "if (!root.identityOpen) postingAs.clicked()" });
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
    await waitOutcome(app, (v) => v.startsWith("Saved — it will be sent through Mix"), "stored post " + i);
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
  await waitOutcome(app, (v) => v.startsWith("Saved — it will be sent through Mix"), "post stored");
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; composer.text = 'TECHNICAL TEST DATA: other words'" });
  await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
  await waitOutcome(app, (v) => v.startsWith("Saved — it will be sent through Mix"), "post stored");
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

// Reading comfort: relative times under day separators (the signed date
// under each time), click-to-copy key ids, Esc closing open panels, and a refresh that
// never yanks a reader who scrolled up — an own new post still brings the
// newest into view.
test("forum_module: thread polish — times, day separators, copy, scroll, Esc", async (app) => {
  await app.waitFor(
    async () => { await app.expectTexts(["Module ready"]); },
    { timeout: 20000, interval: 500, description: "backend ready" }
  );
  // Formatting against a fixed "now" (7 Oct 2026, 12:00 local).
  const now = "new Date(2026, 9, 7, 12, 0).getTime()";
  const checks = [
    ["root.relativeTime('7 Oct 2026, 11:59', " + now + ")", "just now"],
    ["root.relativeTime('7 Oct 2026, 11:53', " + now + ")", "7 min ago"],
    ["root.relativeTime('7 Oct 2026, 09:05', " + now + ")", "09:05"],
    ["root.relativeTime('not a time', " + now + ")", "not a time"],
    ["root.dayLabel('7 Oct 2026, 09:05', " + now + ")", "Today"],
    ["root.dayLabel('6 Oct 2026, 23:59', " + now + ")", "Yesterday"],
    ["root.dayLabel('1 Oct 2026, 08:00', " + now + ")", "Thursday 1 October"],
    ["root.dayLabel('31 Dec 2025, 08:00', " + now + ")", "Wednesday 31 December 2025"],
  ];

  for (const [expr, want] of checks) {
    const got = await evalValue(app, expr);
    if (got !== want) throw new Error(expr + " -> " + got + " (want " + want + ")");
  }

  // Enough posts that the thread scrolls.
  for (let i = 1; i <= 12; i++) {
    await app.inspector.send("evaluate", { expression: "outcome.text = ''; composer.text = 'TECHNICAL TEST DATA: scroll filler " + i + "'" });
    await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
    await waitOutcome(app, (v) => v.startsWith("Saved — it will be sent through Mix"), "filler " + i);
  }
  await app.waitFor(async () => {
    const v = await evalValue(app, "threadList.count + '|' + threadList.atEnd + '|' + (threadList.contentHeight > threadList.height)");
    const [n, atEnd, scrolls] = v.split("|");
    if (Number(n) < 12 || atEnd !== "true" || scrolls !== "true") throw new Error("thread: " + v);
  }, { timeout: 10000, interval: 300, description: "own posts followed to the newest" });
  // The newest row says "just now", with a "Today" separator in the thread.
  const latest = await evalValue(app, "root.relativeTime(threadModel.get(threadModel.count - 1).time, Date.now())");
  if (latest !== "just now") throw new Error("latest time: " + latest);
  const today = await evalValue(app, "root.dayLabel(threadModel.get(threadModel.count - 1).time, Date.now())");
  if (today !== "Today") throw new Error("day label: " + today);
  const dateLine = await evalValue(app, "threadModel.get(threadModel.count - 1).time.split(', ')[0]");
  if (!/^\d{1,2} [A-Z][a-z]{2} \d{4}$/.test(dateLine)) throw new Error("date line: " + dateLine);

  // Scrolled up, a refresh of the same rows keeps the position (after the
  // brief settle that follows a jump to the end).
  await new Promise((r) => setTimeout(r, 600));
  await app.inspector.send("evaluate", { expression: "threadList.positionViewAtBeginning(); root.followNext = false; 'ok'" });
  await new Promise((r) => setTimeout(r, 400));
  await app.inspector.send("evaluate", { expression: "root.syncThread(); 'ok'" });
  await new Promise((r) => setTimeout(r, 400));
  const kept = await evalValue(app, "threadList.atYBeginning + '|' + threadList.atEnd + '|' + newPostsPill.visible");
  if (kept !== "true|false|false") throw new Error("refresh moved the reader: " + kept);
  // An own new post brings the newest back into view.
  await app.inspector.send("evaluate", { expression: "outcome.text = ''; composer.text = 'TECHNICAL TEST DATA: own post follows'" });
  await app.inspector.send("evaluate", { expression: "sendButton.clicked()" });
  await waitOutcome(app, (v) => v.startsWith("Saved — it will be sent through Mix"), "own post");
  await app.waitFor(async () => {
    const v = await evalValue(app, "threadList.atEnd + '|' + newPostsPill.visible");
    if (v !== "true|false") throw new Error("after own post: " + v);
  }, { timeout: 10000, interval: 300, description: "own post in view" });

  // Click to copy: the key id goes to the clipboard, with a short note.
  const keyId = await evalValue(app, "root.rowParts(threadModel.get(threadModel.count - 1).line).keyId.replace(/^id /, '')");
  if (!/^[0-9a-f]{16}$/.test(keyId)) throw new Error("key id: " + keyId);
  await app.inspector.send("evaluate", { expression: "root.copyText('" + keyId + "', 'key id'); 'ok'" });
  const note = await evalValue(app, "toast.message + '|' + toast.shown");
  if (note !== "Copied key id|true") throw new Error("toast: " + note);
  const pasted = await evalValue(app, "clipHelper.text = ''; clipHelper.paste(); var v = clipHelper.text; clipHelper.text = ''; v");
  if (pasted !== keyId) throw new Error("clipboard: " + pasted);

  // Esc closes the topmost open panel, one at a time.
  await app.inspector.send("evaluate", { expression: "root.identityOpen = true; root.newTopicOpen = true; 'ok'" });
  await app.inspector.send("evaluate", { expression: "root.closeTopmost(); 'ok'" });
  let open = await evalValue(app, "root.identityOpen + '|' + root.newTopicOpen");
  if (open !== "false|true") throw new Error("first Esc: " + open);
  await app.inspector.send("evaluate", { expression: "root.closeTopmost(); 'ok'" });
  open = await evalValue(app, "root.identityOpen + '|' + root.newTopicOpen");
  if (open !== "false|false") throw new Error("second Esc: " + open);
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

// A restore outcome shows on the snapshot card it is about (not only in the
// status line): fetching, restored, or the saving device being unreachable.
test("forum_module: snapshot cards show their own restore outcome", async (app) => {
  const cid = "zDvZRwzm1234567890abcdefghijklmnop";
  const k = cid.slice(0, 16);
  const cases = [
    ["fetching snapshot " + k + "… from Logos Storage", "busy", "Fetching from the device"],
    ["restored from Logos Storage (" + k + "…): 3 new posts, 2 already here, 0 rejected by verification", "ok", "Restored: 3 new posts, 2 already here, 0 rejected"],
    ["could not fetch snapshot " + k + "… from Logos Storage after 3 attempt(s): x (the node that serves it may be offline)", "bad", "Not reachable right now"],
    ["could not reach the node serving snapshot " + k + "…: x (it may be offline)", "bad", "Not reachable right now"],
    ["saved 4 posts on Logos Storage (" + k + "…) and announced it", "", ""],
    ["could not fetch snapshot zzzzzzzzzzzzzzzz… from Logos Storage", "", ""],
  ];
  for (const [state, kind, text] of cases) {
    const v = await evalValue(app, "JSON.stringify(root.restoreNote(" + JSON.stringify(cid) + ", " + JSON.stringify(state) + "))");
    const n = JSON.parse(v);
    if (n.kind !== kind || !n.text.startsWith(text)) throw new Error(state.slice(0, 40) + " → " + v);
  }
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
