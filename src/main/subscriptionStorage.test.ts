/**
 * The subscription quota table against a REAL database, including a pre-upgrade one.
 *
 * Run with `node --test src` (Node runs TypeScript directly). Node's own `node:sqlite` is
 * the same module the app uses, so these are the production statements against a real
 * SQLite file rather than a re-implementation of them.
 *
 * # Why the upgrade case is the point
 *
 * This schema has no version table and no ALTER-based migration: its entire upgrade
 * mechanism is `CREATE TABLE IF NOT EXISTS`. That is safe for a new table and is NOT safe
 * for new columns - `CREATE TABLE IF NOT EXISTS profiles (...)` is a no-op on a database
 * that already has `profiles`, so five quota columns there would pass on a fresh install,
 * pass in CI, and fail on every real upgrade with `no such column`. The only way to know
 * which one this is, is to run it against a database that already has the old shape.
 *
 * A fresh-database test cannot tell the two apart, which is why the first test below builds
 * the PRE-feature schema, runs the feature's schema against it, and then queries the new
 * table - reproducing exactly what happens the first time an upgraded user opens the app.
 */
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, describe, it } from "node:test";

import {
  applySubscriptionQuota,
  deleteSubscriptionQuota,
  readSubscriptionQuota,
  subscriptionQuotaSchema,
  writeSubscriptionQuota,
} from "./subscriptionStorage";

/** The schema exactly as it shipped before this feature: three tables, no quota. */
const PRE_FEATURE_SCHEMA = `
    CREATE TABLE IF NOT EXISTS profiles (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      remote_url TEXT,
      auto_update INTEGER NOT NULL,
      auto_update_interval_minutes INTEGER NOT NULL,
      last_updated INTEGER,
      item_order INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS preferences (
      name TEXT PRIMARY KEY,
      data BLOB NOT NULL
    );
    CREATE TABLE IF NOT EXISTS remote_servers (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      url TEXT NOT NULL,
      secret TEXT NOT NULL,
      item_order INTEGER NOT NULL
    );`;

const temporaryDirectories: string[] = [];

/** A database file on disk, closed by `after` so Windows can delete the directory. */
function openDatabase(prefix: string): { store: DatabaseSync; directory: string } {
  const directory = mkdtempSync(join(tmpdir(), prefix));
  temporaryDirectories.push(directory);
  return { store: new DatabaseSync(join(directory, "settings.db")), directory };
}

after(() => {
  for (const directory of temporaryDirectories) {
    rmSync(directory, { recursive: true, force: true });
  }
});

describe("profile_subscription_quota on an existing pre-feature settings.db", () => {
  it("creates the table, keeps the old profiles, and reads as no quota", () => {
    const { store } = openDatabase("jiejiebox-old-db-");
    try {
      // The database an upgraded user already has.
      store.exec(PRE_FEATURE_SCHEMA);
      store
        .prepare(
          `INSERT INTO profiles (id, name, type, remote_url, auto_update,
             auto_update_interval_minutes, last_updated, item_order)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run("existing", "Existing", "remote", "https://example.test/sub", 1, 60, 1_700_000_000_000, 0);
      store
        .prepare("INSERT INTO preferences (name, data) VALUES (?, ?)")
        .run("selected_profile_id", Buffer.from(JSON.stringify("existing")));

      // What `settingsDatabase()` runs on every open. If this were `ALTER`-based, or if the
      // quota lived in columns on `profiles`, this is the statement that would not compile.
      store.exec(subscriptionQuotaSchema);

      // The old rows survive.
      const profiles = store
        .prepare("SELECT id, name FROM profiles ORDER BY item_order ASC")
        .all() as unknown as { id: string; name: string }[];
      // `node:sqlite` returns null-prototype rows, so they are spread into plain objects
      // before comparison rather than asserted against a literal prototype they do not have.
      assert.deepEqual(
        profiles.map((row) => ({ ...row })),
        [{ id: "existing", name: "Existing" }],
      );
      const preference = store
        .prepare("SELECT data FROM preferences WHERE name = ?")
        .get("selected_profile_id") as { data: Uint8Array };
      assert.equal(JSON.parse(Buffer.from(preference.data).toString("utf-8")), "existing");

      // And the new storage is usable and empty - `no such table` would throw here, which is
      // the shape of the failure on an upgraded machine.
      assert.equal(readSubscriptionQuota(store, "existing"), undefined);
    } finally {
      store.close();
    }
  });

  it("accepts the first quota write after the upgrade", () => {
    const { store } = openDatabase("jiejiebox-old-db-write-");
    try {
      store.exec(PRE_FEATURE_SCHEMA);
      store
        .prepare(
          `INSERT INTO profiles (id, name, type, remote_url, auto_update,
             auto_update_interval_minutes, last_updated, item_order)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run("existing", "Existing", "remote", "https://example.test/sub", 1, 60, null, 0);
      store.exec(subscriptionQuotaSchema);

      // The statement the whole table exists for, against the upgraded database.
      writeSubscriptionQuota(store, "existing", {
        upload: 1_000,
        download: 2_000,
        total: 100_000,
        expire: 2_000_000_000,
        updatedAt: 1_700_000_000_000,
      });

      assert.deepEqual(readSubscriptionQuota(store, "existing"), {
        upload: 1_000,
        download: 2_000,
        total: 100_000,
        expire: 2_000_000_000,
        updatedAt: 1_700_000_000_000,
      });
    } finally {
      store.close();
    }
  });

  it("is idempotent, so opening the app twice does not fail", () => {
    const { store, directory } = openDatabase("jiejiebox-old-db-twice-");
    store.exec(PRE_FEATURE_SCHEMA);
    store.exec(subscriptionQuotaSchema);
    writeSubscriptionQuota(store, "p", { total: 10, updatedAt: 1 });
    // The second launch runs the same schema statement again.
    store.exec(subscriptionQuotaSchema);
    assert.deepEqual(readSubscriptionQuota(store, "p"), { total: 10, updatedAt: 1 });
    store.close();

    // And a second connection to the same file sees the data, which is what a cold start
    // does - this is the "only fails after a restart" class of bug.
    const reopened = new DatabaseSync(join(directory, "settings.db"));
    try {
      reopened.exec(subscriptionQuotaSchema);
      assert.deepEqual(readSubscriptionQuota(reopened, "p"), { total: 10, updatedAt: 1 });
    } finally {
      reopened.close();
    }
  });
});

describe("profile_subscription_quota round trip", () => {
  it("replaces the whole snapshot rather than merging into it", () => {
    // The partial-header rule, at the storage layer: a header that omitted `upload` and
    // `expire` must not leave the previous snapshot's values attached to the new one.
    const { store } = openDatabase("jiejiebox-quota-replace-");
    try {
      store.exec(subscriptionQuotaSchema);
      writeSubscriptionQuota(store, "p", {
        upload: 1,
        download: 2,
        total: 100,
        expire: 2_000_000_000,
        updatedAt: 1,
      });
      writeSubscriptionQuota(store, "p", { download: 3, total: 100, updatedAt: 2 });
      assert.deepEqual(readSubscriptionQuota(store, "p"), {
        download: 3,
        total: 100,
        updatedAt: 2,
      });
    } finally {
      store.close();
    }
  });

  it("keeps zero distinct from absent", () => {
    const { store } = openDatabase("jiejiebox-quota-zero-");
    try {
      store.exec(subscriptionQuotaSchema);
      writeSubscriptionQuota(store, "p", { download: 0, total: 0, expire: 0, updatedAt: 1 });
      // Present-and-zero is data; absent is not. A `??` in the wrong place turns one into
      // the other, and `total=0` becoming "no quota" is a decision the UI makes, not storage.
      assert.deepEqual(readSubscriptionQuota(store, "p"), {
        download: 0,
        total: 0,
        expire: 0,
        updatedAt: 1,
      });
    } finally {
      store.close();
    }
  });

  it("stores values at the top of the accepted range without losing precision", () => {
    const { store } = openDatabase("jiejiebox-quota-range-");
    try {
      store.exec(subscriptionQuotaSchema);
      // The largest value the parser accepts (1 PiB). SQLite's INTEGER is 64-bit, so storage
      // is not the constraint; JavaScript's exactly-representable range is, which is why the
      // cap is below 2^53-1 rather than at it.
      const maximum = 1_125_899_906_842_624;
      writeSubscriptionQuota(store, "p", { total: maximum, updatedAt: 1 });
      assert.equal(readSubscriptionQuota(store, "p")?.total, maximum);
    } finally {
      store.close();
    }
  });

  it("deletes only the row it is asked for", () => {
    const { store } = openDatabase("jiejiebox-quota-delete-");
    try {
      store.exec(subscriptionQuotaSchema);
      writeSubscriptionQuota(store, "keep", { total: 1, updatedAt: 1 });
      writeSubscriptionQuota(store, "drop", { total: 2, updatedAt: 1 });
      deleteSubscriptionQuota(store, "drop");
      assert.equal(readSubscriptionQuota(store, "drop"), undefined);
      assert.deepEqual(readSubscriptionQuota(store, "keep"), { total: 1, updatedAt: 1 });
    } finally {
      store.close();
    }
  });

  it("writes a row for a profile that does not exist, and that is why the caller deletes", () => {
    // There is no foreign key, so the database will not stop an orphan - which is exactly
    // why `remove` deletes this row inside the same transaction as the profile row. This
    // test states the property rather than pretending the schema enforces it.
    const { store } = openDatabase("jiejiebox-quota-orphan-");
    try {
      store.exec(PRE_FEATURE_SCHEMA);
      store.exec(subscriptionQuotaSchema);
      writeSubscriptionQuota(store, "gone", { total: 1, updatedAt: 1 });
      assert.deepEqual(readSubscriptionQuota(store, "gone"), { total: 1, updatedAt: 1 });
      const counted = store
        .prepare("SELECT COUNT(*) AS count FROM profile_subscription_quota")
        .get() as { count: number };
      assert.equal(counted.count, 1);
    } finally {
      store.close();
    }
  });
});

describe("applySubscriptionQuota: the three outcomes of a fetch", () => {
  it("keeps the snapshot and its timestamp when the provider sends no header", () => {
    // Update 1 succeeds with a header; update 2 succeeds and the provider omits it. The
    // CONTENT is fresh after update 2 and the QUOTA is not, and the two timestamps have to be
    // able to say so - which is the whole reason `updatedAt` is not `lastUpdated`.
    const { store } = openDatabase("jiejiebox-quota-freshness-");
    try {
      store.exec(subscriptionQuotaSchema);
      const update1 = { quota: { download: 10, total: 100, updatedAt: 1_000 } };
      applySubscriptionQuota(store, "p", update1);
      assert.deepEqual(readSubscriptionQuota(store, "p"), {
        download: 10,
        total: 100,
        updatedAt: 1_000,
      });

      // Update 2: the provider sent nothing. `undefined` is "no change", so the snapshot and
      // its timestamp both survive untouched.
      applySubscriptionQuota(store, "p", undefined);
      assert.deepEqual(
        readSubscriptionQuota(store, "p"),
        { download: 10, total: 100, updatedAt: 1_000 },
        "a missing header must not advance or clear the quota",
      );
    } finally {
      store.close();
    }
  });

  it("replaces the snapshot and advances the timestamp when a header arrives", () => {
    const { store } = openDatabase("jiejiebox-quota-advance-");
    try {
      store.exec(subscriptionQuotaSchema);
      applySubscriptionQuota(store, "p", { quota: { download: 10, total: 100, updatedAt: 1_000 } });
      applySubscriptionQuota(store, "p", { quota: { download: 20, total: 100, updatedAt: 2_000 } });
      assert.deepEqual(readSubscriptionQuota(store, "p"), {
        download: 20,
        total: 100,
        updatedAt: 2_000,
      });
    } finally {
      store.close();
    }
  });

  it("clears the snapshot when the profile's URL changed", () => {
    // The old account's remaining traffic must not be presented as the new one's, and it must
    // not come back if the new URL never reports a header.
    const { store } = openDatabase("jiejiebox-quota-urlchange-");
    try {
      store.exec(subscriptionQuotaSchema);
      applySubscriptionQuota(store, "p", { quota: { total: 100, updatedAt: 1_000 } });
      applySubscriptionQuota(store, "p", { quota: null });
      assert.equal(readSubscriptionQuota(store, "p"), undefined);
      applySubscriptionQuota(store, "p", undefined);
      assert.equal(
        readSubscriptionQuota(store, "p"),
        undefined,
        "nothing may resurrect a cleared snapshot",
      );
    } finally {
      store.close();
    }
  });

  it("distinguishes an absent header from an unparseable one", () => {
    // `undefined` keeps the old snapshot; `{}` is a header that parsed to nothing, which is
    // authoritative and therefore clears it. Getting these two the wrong way round produces a
    // card that is either permanently stale or permanently empty.
    const { store } = openDatabase("jiejiebox-quota-authoritative-");
    try {
      store.exec(subscriptionQuotaSchema);
      applySubscriptionQuota(store, "p", {
        quota: { upload: 1, download: 2, total: 100, updatedAt: 1_000 },
      });
      applySubscriptionQuota(store, "p", { quota: { updatedAt: 2_000 } });
      assert.deepEqual(readSubscriptionQuota(store, "p"), { updatedAt: 2_000 });
      assert.equal(readSubscriptionQuota(store, "p")?.upload, undefined);
      assert.equal(readSubscriptionQuota(store, "p")?.expire, undefined);
    } finally {
      store.close();
    }
  });
});
