/**
 * The subscription quota's storage: its schema, and the SQL that reads and writes it.
 *
 * Separate from `database.ts` for one reason: the schema has to be runnable against a real
 * SQLite database in a test. `database.ts` opens Electron's userData directory, so anything
 * it owns can only be exercised by launching the app - and the failure this schema has to
 * survive is precisely the one that only happens on an EXISTING database, which a fresh
 * launch never produces. The SQL lives here so `subscriptionStorage.test.ts` can run the real
 * statements against a synthetic pre-upgrade `settings.db`.
 *
 * There is no Electron, no filesystem and no connection handling here: a caller supplies an
 * open `DatabaseSync`.
 */

import type { DatabaseSync } from "node:sqlite";

import type { SubscriptionQuota, SubscriptionQuotaUpdate } from "../shared/subscription";

export type { SubscriptionQuota, SubscriptionQuotaUpdate };

/**
 * The quota table, as one idempotent statement.
 *
 * `CREATE TABLE IF NOT EXISTS` is what makes an existing `settings.db` safe: the database
 * simply gains the table. This is the ONLY migration mechanism this schema has, and it is
 * the reason the quota is a table rather than columns on `profiles` - adding columns there
 * would work on a fresh install, work in CI, and fail on every real upgrade with
 * `no such column`, at the moment something first wrote a quota.
 *
 * A separate table also says the right thing about the data: optional metadata about a
 * REMOTE subscription, not a property of a profile. A local profile has no row, and neither
 * does a remote profile whose provider never sent the header.
 *
 * There is deliberately no foreign key. `PRAGMA foreign_keys` is off by default and nothing
 * here turns it on, so declaring one would produce a constraint that is documented but not
 * enforced; `deleteSubscriptionQuota` removes the row in the same transaction as the profile.
 */
export const subscriptionQuotaSchema = `
    CREATE TABLE IF NOT EXISTS profile_subscription_quota (
      profile_id TEXT PRIMARY KEY,
      upload INTEGER,
      download INTEGER,
      total INTEGER,
      expire INTEGER,
      updated_at INTEGER NOT NULL
    );`;

interface SubscriptionQuotaRow {
  profile_id: string;
  upload: number | null;
  download: number | null;
  total: number | null;
  expire: number | null;
  updated_at: number;
}

function subscriptionQuotaFromRow(row: SubscriptionQuotaRow): SubscriptionQuota {
  const quota: SubscriptionQuota = { updatedAt: row.updated_at };
  // null is "this snapshot does not carry that field", which is not the same as 0 - a
  // provider that sent no expire has no expiry, while `expire=0` is one most panels mean as
  // "no expiry set" (and is certainly not 1970-01-01).
  if (row.upload !== null) {
    quota.upload = row.upload;
  }
  if (row.download !== null) {
    quota.download = row.download;
  }
  if (row.total !== null) {
    quota.total = row.total;
  }
  if (row.expire !== null) {
    quota.expire = row.expire;
  }
  return quota;
}

export function readSubscriptionQuota(
  store: DatabaseSync,
  profileId: string,
): SubscriptionQuota | undefined {
  const row = store
    .prepare("SELECT * FROM profile_subscription_quota WHERE profile_id = ?")
    .get(profileId) as SubscriptionQuotaRow | undefined;
  return row === undefined ? undefined : subscriptionQuotaFromRow(row);
}

export function writeSubscriptionQuota(
  store: DatabaseSync,
  profileId: string,
  quota: SubscriptionQuota,
): void {
  store
    .prepare(
      `INSERT INTO profile_subscription_quota
         (profile_id, upload, download, total, expire, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(profile_id) DO UPDATE SET
         upload = excluded.upload,
         download = excluded.download,
         total = excluded.total,
         expire = excluded.expire,
         updated_at = excluded.updated_at`,
    )
    .run(
      profileId,
      quota.upload ?? null,
      quota.download ?? null,
      quota.total ?? null,
      quota.expire ?? null,
      quota.updatedAt,
    );
}

export function deleteSubscriptionQuota(store: DatabaseSync, profileId: string): void {
  store
    .prepare("DELETE FROM profile_subscription_quota WHERE profile_id = ?")
    .run(profileId);
}

/**
 * Applies one of the three outcomes.
 *
 * It lives here rather than in profiles.ts so the three cases can be exercised against a real
 * database - `applySubscriptionQuota: the three outcomes of a fetch` in
 * subscriptionStorage.test.ts. See `SubscriptionQuotaUpdate` for what each one means and why
 * getting them the wrong way round is the failure that is hardest to notice.
 */
export function applySubscriptionQuota(
  store: DatabaseSync,
  profileId: string,
  update: SubscriptionQuotaUpdate,
): void {
  if (update === undefined) {
    return;
  }
  if (update.quota === null) {
    deleteSubscriptionQuota(store, profileId);
    return;
  }
  writeSubscriptionQuota(store, profileId, update.quota);
}
