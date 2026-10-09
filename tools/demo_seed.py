#!/usr/bin/env python3
"""Labelled demo posts, dated over the last two days, in ONE local profile.

For recording the demo video: a topic "DEMO: sample posts" whose posts sit
under the "Yesterday" and earlier day separators. Everything here is local:
the rows are written straight into the profile's store as received posts, so
nothing is sent to the network. Every post says it is a demo post, and the
authors are labelled demo aliases with fixed demo keys.

Do not press Save snapshot in the DEMO topic: a snapshot publishes the
topic's posts on Logos Storage.

Usage (the profile's Basecamp must be stopped; a profile whose Forum was
never opened gets the store created with the app's own posts table, and the
app adds the rest when it opens):
  python3 tools/demo_seed.py ~/lp0026-demo/play          # add (idempotent)
  python3 tools/demo_seed.py ~/lp0026-demo/play --remove # take them out again

The events are signed and encoded exactly as src/core/forum_core.cpp does
(the same rules as tools/m2b_cli.py), so they verify like any other post.
"""
import datetime
import hashlib
import sqlite3
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

FORUM = "general"
TOPIC_TITLE = "DEMO: sample posts"


def escape_field(s: str) -> str:
    return (s.replace("\\", "\\\\").replace("|", "\\p")
             .replace("\n", "\\n").replace("\r", "\\r"))


def demo_key(name: str) -> Ed25519PrivateKey:
    seed = hashlib.sha256(f"lp0026-forum/demo-seed/v1|{name}".encode()).digest()
    return Ed25519PrivateKey.from_private_bytes(seed)


def pub_hex(key: Ed25519PrivateKey) -> str:
    return key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()


def event(key, typ, topic, alias, ts_ms, body):
    canon = ("forum-v1|"
             f"forum={escape_field(FORUM)}|type={escape_field(typ)}|"
             f"topic={escape_field(topic)}|parent={escape_field(topic)}|"
             f"author={pub_hex(key)}|alias={escape_field(alias)}|"
             f"ts={ts_ms}|body={escape_field(body)}")
    if typ == "topic":  # a topic event references nothing
        canon = canon.replace(f"topic={escape_field(topic)}|parent={escape_field(topic)}|",
                              "topic=|parent=|")
    sig = key.sign(canon.encode()).hex()
    return {"id": hashlib.sha256(canon.encode()).hexdigest(), "canonical": canon,
            "signature": sig, "type": typ, "topic": "" if typ == "topic" else topic,
            "author": pub_hex(key), "alias": alias, "ts": ts_ms, "body": body}


def at(days_ago: int, hh: int, mm: int) -> int:
    d = datetime.date.today() - datetime.timedelta(days=days_ago)
    return int(datetime.datetime(d.year, d.month, d.day, hh, mm).timestamp() * 1000)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    db = Path(sys.argv[1]).expanduser() / "module_data/forum_module/forum.db"
    if not Path(sys.argv[1]).expanduser().is_dir():
        print(f"no profile at {sys.argv[1]}")
        return 1
    db.parent.mkdir(parents=True, exist_ok=True)
    ana, ben, anon = demo_key("demo-ana"), demo_key("demo-ben"), demo_key("demo-anon")
    authors = [pub_hex(k) for k in (ana, ben, anon)]
    c = sqlite3.connect(db)
    # The same table as src/core/forum_core.cpp (CREATE TABLE IF NOT EXISTS there too).
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("CREATE TABLE IF NOT EXISTS posts( event_id TEXT PRIMARY KEY, forum_id TEXT NOT NULL,"
              " type TEXT NOT NULL, topic_id TEXT NOT NULL, parent_id TEXT NOT NULL,"
              " author_pub_hex TEXT NOT NULL, alias TEXT NOT NULL, ts_ms INTEGER NOT NULL,"
              " body TEXT NOT NULL, signature TEXT NOT NULL, state TEXT NOT NULL,"
              " privacy TEXT NOT NULL, last_error TEXT NOT NULL, canonical TEXT NOT NULL,"
              " created_ms INTEGER NOT NULL)")
    if "--remove" in sys.argv[2:]:
        n = c.execute(f"DELETE FROM posts WHERE author_pub_hex IN ({','.join('?' * 3)})",
                      authors).rowcount
        c.commit()
        print(f"removed {n} demo rows")
        return 0
    topic = event(ana, "topic", "", "demo-ana", at(2, 17, 0), TOPIC_TITLE)
    tid = topic["id"]
    posts = [
        event(ana, "post", tid, "demo-ana", at(2, 17, 4),
              "DEMO POST: sample posts for the demo video, dated over the last two days "
              "so the day separators show."),
        event(ben, "post", tid, "demo-ben", at(1, 10, 12),
              "DEMO POST: every author's key id is shown next to the alias, so two people "
              "called the same thing can't pass as each other."),
        event(ana, "post", tid, "demo-ana", at(1, 18, 40),
              "DEMO POST: and the square beside each post is drawn from the key, so the same "
              "author looks the same everywhere."),
        event(anon, "post", tid, "", at(1, 21, 3),
              "DEMO POST: this one is anonymous: no alias, just a key id."),
    ]
    added = 0
    for e in [topic] + posts:
        cur = c.execute(
            "INSERT OR IGNORE INTO posts(event_id,forum_id,type,topic_id,parent_id,"
            "author_pub_hex,alias,ts_ms,body,signature,state,privacy,last_error,canonical,"
            "created_ms) VALUES(?,?,?,?,?,?,?,?,?,?,'received','required','',?,0)",
            (e["id"], FORUM, e["type"], e["topic"], e["topic"], e["author"], e["alias"],
             e["ts"], e["body"], e["signature"], e["canonical"]))
        added += cur.rowcount
    c.commit()
    print(f"added {added} demo rows (topic '{TOPIC_TITLE}', {len(posts)} posts); "
          "they stay on this device")
    return 0


if __name__ == "__main__":
    sys.exit(main())
