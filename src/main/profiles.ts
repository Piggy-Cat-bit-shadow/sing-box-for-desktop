import { ConnectError } from "@connectrpc/connect";
import { BrowserWindow, app, dialog, ipcMain } from "electron";
import { copyFile, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";

import { ServiceStatus_Type } from "../shared/gen/daemon/started_service_pb";
import { ProfileContent_Type } from "../shared/gen/experimental/boxdd/desktop_service_pb";
import { PROFILES_CALL, PROFILES_CHANGED } from "../shared/ipc";
import type {
  ProfileCreate,
  ProfileMetadata,
  ProfileMetadataPatch,
  ProfileType,
  ProfilesResult,
  ProfilesState,
} from "../shared/ipc";
import { fetchRemoteProfile } from "../shared/subscriptionFetch";
import { SUBSCRIPTION_USER_AGENT, type SubscriptionQuotaUpdate } from "../shared/subscription";
import { writeApplicationCacheFile } from "./appCache";
import { desktopService } from "./daemon";
import { Preference, settingsDatabase } from "./database";
import { serviceStartOptions } from "./settings";
import {
  applySubscriptionQuota as applySubscriptionQuotaUpdate,
  deleteSubscriptionQuota,
  readSubscriptionQuota,
} from "./subscriptionStorage";
import { applicationService } from "./worker";
import { daemonState } from "./state";

const MINIMUM_UPDATE_INTERVAL_MINUTES = 15;
const DEFAULT_UPDATE_INTERVAL_MINUTES = 60;
// Upstream, "Fix remote profile auto update scheduling": setTimeout silently clamps anything above
// 2^31-1 milliseconds to 1 ms, so an interval that large has to be capped deliberately instead.
const MAXIMUM_TIMER_DELAY_MILLISECONDS = 2 ** 31 - 1;

interface ProfileRow {
  id: string;
  name: string;
  type: string;
  remote_url: string | null;
  auto_update: number;
  auto_update_interval_minutes: number;
  last_updated: number | null;
  item_order: number;
}

function profilesDirectory(): string {
  return join(app.getPath("userData"), "profiles");
}

function contentPath(id: string): string {
  return join(profilesDirectory(), `${id}.json`);
}

async function atomicWriteFile(path: string, content: string): Promise<void> {
  await mkdir(profilesDirectory(), { recursive: true });
  const temporaryPath = `${path}.${crypto.randomUUID()}.tmp`;
  try {
    await writeFile(temporaryPath, content);
    await rename(temporaryPath, path);
  } finally {
    await unlink(temporaryPath).catch(() => {});
  }
}

const profileOperations = new Map<string, Promise<void>>();

function runProfileOperation<Result>(
  id: string,
  operation: () => Promise<Result>,
): Promise<Result> {
  const previous = profileOperations.get(id) ?? Promise.resolve();
  const result = previous.catch(() => {}).then(operation);
  const settled = result.then(
    () => {},
    () => {},
  );
  profileOperations.set(id, settled);
  return result.finally(() => {
    if (profileOperations.get(id) === settled) {
      profileOperations.delete(id);
    }
  });
}

const selectedProfilePreference = new Preference<string | null>(
  "selected_profile_id",
  null,
  (value) => {
    if (typeof value !== "string" || value === "") {
      throw new Error("invalid selected profile preference");
    }
    return value;
  },
);

function profileFromRow(row: ProfileRow): ProfileMetadata {
  const profile: ProfileMetadata = {
    id: row.id,
    name: row.name,
    type: row.type as ProfileType,
    autoUpdate: row.auto_update !== 0,
    autoUpdateIntervalMinutes: row.auto_update_interval_minutes,
  };
  if (row.remote_url !== null) {
    profile.remoteUrl = row.remote_url;
  }
  if (row.last_updated !== null) {
    profile.lastUpdated = row.last_updated;
  }
  return profile;
}

// ---------------------------------------------------------------------------
// Subscription quota
//
// The quota lives in its own table (see subscriptionStorage.ts, which owns the SQL, the
// three-outcome state machine and the tests), and it travels to the renderer on the profile
// it belongs to. It is NOT a field of the profile row, and it is NOT derived from
// `lastUpdated`: a profile update that succeeds while the provider omits the header leaves
// the content fresh and the quota stale, and the two timestamps have to be able to say so.
// ---------------------------------------------------------------------------

function applySubscriptionQuota(id: string, update: SubscriptionQuotaUpdate): void {
  applySubscriptionQuotaUpdate(settingsDatabase(), id, update);
}

function attachSubscriptionQuota(profile: ProfileMetadata): ProfileMetadata {
  const quota = readSubscriptionQuota(settingsDatabase(), profile.id);
  if (quota === undefined) {
    return profile;
  }
  return { ...profile, subscription: quota };
}

function listProfiles(): ProfileMetadata[] {
  const rows = settingsDatabase()
    .prepare("SELECT * FROM profiles ORDER BY item_order ASC")
    .all() as unknown as ProfileRow[];
  return rows.map((row) => attachSubscriptionQuota(profileFromRow(row)));
}

function selectedProfileId(): string | null {
  return selectedProfilePreference.get();
}

function writeSelectedProfileId(id: string | null): void {
  selectedProfilePreference.set(id);
}

function findProfile(id: string): ProfileMetadata {
  const row = settingsDatabase()
    .prepare("SELECT * FROM profiles WHERE id = ?")
    .get(id) as ProfileRow | undefined;
  if (row === undefined) {
    throw new Error(`profile not found: ${id}`);
  }
  return attachSubscriptionQuota(profileFromRow(row));
}

// Mirrors the Apple client's ProfileManager.uniqueName: appends " (n)" until
// the name is free, so imported or created profiles never collide.
function uniqueName(baseName: string): string {
  const existing = new Set(listProfiles().map((profile) => profile.name));
  if (!existing.has(baseName)) {
    return baseName;
  }
  let counter = 1;
  while (existing.has(`${baseName} (${counter})`)) {
    counter += 1;
  }
  return `${baseName} (${counter})`;
}

const changeListeners: (() => void)[] = [];

export function onProfilesChanged(listener: () => void) {
  changeListeners.push(listener);
}

export function profilesState(): ProfilesState {
  return { selectedId: selectedProfileId(), profiles: listProfiles() };
}

function notifyChanged() {
  for (const window of BrowserWindow.getAllWindows()) {
    if (!window.webContents.isDestroyed()) {
      window.webContents.send(PROFILES_CHANGED);
    }
  }
  for (const listener of changeListeners) {
    listener();
  }
}

async function checkConfig(content: string): Promise<void> {
  await applicationService.checkConfig({ content });
}

// The request itself - the body, the quota header, and the bounded compatibility retry that
// recovers a header a provider gates behind a recognised client - lives in
// ../shared/subscriptionFetch, where it can be tested against a stubbed fetch. What stays
// here is the part that needs the settings database, the daemon and this app's policy.
function remoteProfileRequest(remoteUrl: string) {
  return fetchRemoteProfile(remoteUrl, { userAgent: SUBSCRIPTION_USER_AGENT });
}

async function insertProfile(
  profile: ProfileMetadata,
  content: string,
  quota: SubscriptionQuotaUpdate,
): Promise<ProfileMetadata> {
  await atomicWriteFile(contentPath(profile.id), content);
  const store = settingsDatabase();
  store.transaction(() => {
    const nextOrder = (
      store
        .prepare(
          "SELECT COALESCE(MAX(item_order) + 1, 0) AS next_order FROM profiles",
        )
        .get() as {
        next_order: number;
      }
    ).next_order;
    store
      .prepare(
        `INSERT INTO profiles (id, name, type, remote_url, auto_update,
          auto_update_interval_minutes, last_updated, item_order)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        profile.id,
        profile.name,
        profile.type,
        profile.remoteUrl ?? null,
        profile.autoUpdate ? 1 : 0,
        profile.autoUpdateIntervalMinutes,
        profile.lastUpdated ?? null,
        nextOrder,
      );
    writeSelectedProfileId(profile.id);
  })();
  // Outside the profile transaction on purpose: `applySubscriptionQuota` owns its own
  // statement, and nesting it would make the quota's write depend on the profile's rollback
  // path for no benefit - a missing quota row is a valid state, an orphan is not, and this
  // runs after the row it references exists.
  applySubscriptionQuota(profile.id, quota);
  notifyChanged();
  reconfigureAutoUpdate();
  return profile;
}

async function importProfileData(
  fileName: string,
  data: Uint8Array,
): Promise<void> {
  if (fileName.toLowerCase().endsWith(".bpf")) {
    const content = await applicationService.decodeProfile({ data });
    await checkConfig(content.config);
    const remote = content.type === ProfileContent_Type.REMOTE;
    // Shared profile files carry LastUpdated in either seconds or milliseconds.
    let lastUpdated: number | undefined;
    if (remote && content.lastUpdated > 0n) {
      lastUpdated =
        content.lastUpdated > 100_000_000_000n
          ? Number(content.lastUpdated)
          : Number(content.lastUpdated) * 1000;
    }
    await insertProfile(
      {
        id: crypto.randomUUID(),
        name: uniqueName(content.name || basename(fileName, ".bpf")),
        type: remote ? "remote" : "local",
        remoteUrl: remote ? content.remotePath : undefined,
        autoUpdate: remote ? content.autoUpdate : false,
        autoUpdateIntervalMinutes:
          remote && content.autoUpdateInterval > 0
            ? content.autoUpdateInterval
            : DEFAULT_UPDATE_INTERVAL_MINUTES,
        lastUpdated,
      },
      content.config,
      // A shared profile file carries the subscription CONTENT and its own lastUpdated, but
      // no quota fields - the format has no place to put them. So an imported remote profile
      // starts with no quota and picks one up on its next update.
      undefined,
    );
    return;
  }
  throw new Error(`unsupported profile file: ${fileName}`);
}

async function encodeProfileData(id: string): Promise<Uint8Array> {
  const profile = findProfile(id);
  const remote = profile.type === "remote";
  const encoded = await applicationService.encodeProfile({
    type: remote ? ProfileContent_Type.REMOTE : ProfileContent_Type.LOCAL,
    name: profile.name,
    config: await readFile(contentPath(id), "utf-8"),
    remotePath: remote ? profile.remoteUrl : undefined,
    autoUpdate: remote ? profile.autoUpdate : false,
    autoUpdateInterval: remote ? profile.autoUpdateIntervalMinutes : 0,
    lastUpdated:
      remote && profile.lastUpdated !== undefined
        ? BigInt(profile.lastUpdated)
        : 0n,
  });
  return encoded.data;
}

async function startServiceWithContent(content: string): Promise<void> {
  if (desktopService === null) {
    throw new Error("daemon is not available");
  }
  await desktopService.startService({
    configContent: content,
    options: await serviceStartOptions(),
  });
}

async function reloadIfSelectedAndRunning(id: string): Promise<void> {
  if (selectedProfileId() !== id) {
    return;
  }
  if (daemonState.status !== ServiceStatus_Type.STARTED) {
    return;
  }
  await startServiceWithContent(await readFile(contentPath(id), "utf-8"));
}

function intervalOrDefault(profile: ProfileMetadata): number {
  if (profile.autoUpdateIntervalMinutes > 0) {
    return Math.max(
      profile.autoUpdateIntervalMinutes,
      MINIMUM_UPDATE_INTERVAL_MINUTES,
    );
  }
  return DEFAULT_UPDATE_INTERVAL_MINUTES;
}

function updateRemoteProfile(id: string): Promise<void> {
  return runProfileOperation(id, async () => {
    const profile = findProfile(id);
    if (profile.type !== "remote" || !profile.remoteUrl) {
      throw new Error("not a remote profile");
    }
    const remote = await remoteProfileRequest(profile.remoteUrl);
    // Validation runs BEFORE anything is committed, and it is the only gate. A provider that
    // answers HTTP 200 with a valid-looking quota header and an error page for a body must
    // leave the profile exactly as it was: a quota snapshot persisted first would be a
    // freshness claim about an update that then failed.
    await checkConfig(remote.content);
    const store = settingsDatabase();
    try {
      const oldContent = await readFile(contentPath(profile.id), "utf-8");
      if (oldContent !== remote.content) {
        await atomicWriteFile(contentPath(profile.id), remote.content);
        await reloadIfSelectedAndRunning(profile.id);
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        throw error;
      }
      await atomicWriteFile(contentPath(profile.id), remote.content);
      await reloadIfSelectedAndRunning(profile.id);
    }
    store
      .prepare("UPDATE profiles SET last_updated = ? WHERE id = ?")
      .run(Date.now(), profile.id);
    // Deliberately OUTSIDE the `oldContent !== remote.content` branch above, and after the
    // content write rather than before it.
    //
    // Outside it, because the two move independently in practice: a subscription whose node
    // list has not changed still consumes traffic, so `body unchanged` is the NORMAL case for
    // a quota that did change. Gating this on the body would freeze the quota for every
    // stable subscription.
    //
    // After it, because the commit order is the one the user can be wrong about. If the body
    // write throws, no quota timestamp is advanced and the card keeps saying when the last
    // SUCCESSFUL update happened.
    applySubscriptionQuota(profile.id, remote.quota);
    notifyChanged();
  });
}

export async function selectProfile(id: string): Promise<void> {
  findProfile(id);
  if (selectedProfileId() === id) {
    return;
  }
  writeSelectedProfileId(id);
  notifyChanged();
  await reloadIfSelectedAndRunning(id);
}

export async function startSelectedProfile(): Promise<void> {
  const selectedId = selectedProfileId();
  if (selectedId === null) {
    throw new Error("no profile selected");
  }
  const content = await readFile(contentPath(selectedId), "utf-8");
  await startServiceWithContent(content);
}

let updateTimer: NodeJS.Timeout | null = null;
// Upstream's scheduling fix, merged: a profile update that FAILS must not be retried in a tight
// loop, so the attempt is remembered separately from `lastUpdated` (which only moves on success),
// and the timer is computed from whichever is later.
const lastUpdateAttempts = new Map<string, number>();

function nextUpdateTime(profile: ProfileMetadata): number {
  return (
    Math.max(profile.lastUpdated ?? 0, lastUpdateAttempts.get(profile.id) ?? 0) +
    intervalOrDefault(profile) * 60 * 1000
  );
}

async function runDueProfileUpdates(): Promise<void> {
  const now = Date.now();
  const dueProfiles = listProfiles().filter((profile) => {
    if (profile.type !== "remote" || !profile.autoUpdate) {
      return false;
    }
    return nextUpdateTime(profile) <= now;
  });
  await Promise.all(
    dueProfiles.map(async (profile) => {
      lastUpdateAttempts.set(profile.id, now);
      try {
        await updateRemoteProfile(profile.id);
      } catch (error) {
        console.error(`update profile ${profile.name}:`, error);
      }
    }),
  );
}

function reconfigureAutoUpdate(): void {
  if (updateTimer !== null) {
    clearTimeout(updateTimer);
    updateTimer = null;
  }
  const enabled = listProfiles().filter(
    (profile) => profile.type === "remote" && profile.autoUpdate,
  );
  if (enabled.length === 0) {
    return;
  }
  const delay = Math.min(...enabled.map(nextUpdateTime)) - Date.now();
  updateTimer = setTimeout(() => {
    void runDueProfileUpdates().finally(() => {
      reconfigureAutoUpdate();
    });
  }, Math.min(Math.max(delay, 0), MAXIMUM_TIMER_DELAY_MILLISECONDS));
}

const handlers: Record<
  string,
  (...callArguments: never[]) => Promise<unknown>
> = {
  async list(): Promise<ProfilesState> {
    return profilesState();
  },

  async create(init: ProfileCreate): Promise<ProfileMetadata> {
    const profile: ProfileMetadata = {
      id: crypto.randomUUID(),
      name: uniqueName(init.name),
      type: init.type,
      autoUpdate: init.autoUpdate ?? init.type === "remote",
      autoUpdateIntervalMinutes:
        init.autoUpdateIntervalMinutes ?? DEFAULT_UPDATE_INTERVAL_MINUTES,
    };
    let content: string;
    let quota: SubscriptionQuotaUpdate;
    if (init.type === "remote") {
      if (!init.remoteUrl) {
        throw new Error("missing remote URL");
      }
      profile.remoteUrl = init.remoteUrl;
      const remote = await remoteProfileRequest(init.remoteUrl);
      content = remote.content;
      quota = remote.quota;
      await checkConfig(content);
      profile.lastUpdated = Date.now();
    } else {
      content = init.content ?? "{}";
      // A local profile has no remote account, so it never has a quota. `null` rather than
      // `undefined` would delete a row this profile cannot have; `undefined` is "no change",
      // which for a brand new profile is the same thing and says less about intent, so the
      // empty case is left to fall out of the table having no row.
      quota = undefined;
      if (init.content !== undefined) {
        await checkConfig(content);
      }
    }
    return await insertProfile(profile, content, quota);
  },

  async updateMetadata(id: string, patch: ProfileMetadataPatch): Promise<void> {
    await runProfileOperation(id, async () => {
      const profile = findProfile(id);
      let remoteContent: string | null = null;
      let quota: SubscriptionQuotaUpdate;
      // `remoteUrl` pointing somewhere else means a different subscription account, so the
      // snapshot on file is about an account this profile no longer follows. Clearing it is
      // the whole of the URL-change rule: the card goes quiet until the new URL reports its
      // own numbers, rather than presenting the old provider's remaining traffic as this
      // one's.
      const remoteUrlChanged =
        patch.remoteUrl !== undefined &&
        profile.type === "remote" &&
        patch.remoteUrl !== profile.remoteUrl;
      if (remoteUrlChanged) {
        const remote = await remoteProfileRequest(patch.remoteUrl as string);
        remoteContent = remote.content;
        quota = remote.quota ?? { quota: null };
        await checkConfig(remoteContent);
        await atomicWriteFile(contentPath(id), remoteContent);
      }
      const store = settingsDatabase();
      store.transaction(() => {
        if (patch.name !== undefined) {
          store
            .prepare("UPDATE profiles SET name = ? WHERE id = ?")
            .run(patch.name, id);
        }
        if (patch.remoteUrl !== undefined && profile.type === "remote") {
          store
            .prepare(
              "UPDATE profiles SET remote_url = ?, last_updated = ? WHERE id = ?",
            )
            .run(
              patch.remoteUrl,
              remoteContent === null
                ? (profile.lastUpdated ?? null)
                : Date.now(),
              id,
            );
        }
        if (patch.autoUpdate !== undefined) {
          store
            .prepare("UPDATE profiles SET auto_update = ? WHERE id = ?")
            .run(patch.autoUpdate ? 1 : 0, id);
        }
        if (patch.autoUpdateIntervalMinutes !== undefined) {
          store
            .prepare(
              "UPDATE profiles SET auto_update_interval_minutes = ? WHERE id = ?",
            )
            .run(
              Math.max(
                patch.autoUpdateIntervalMinutes,
                MINIMUM_UPDATE_INTERVAL_MINUTES,
              ),
              id,
            );
        }
      })();
      if (remoteUrlChanged) {
        // The new URL reported a header: its snapshot is now authoritative. It reported
        // none: the previous account's snapshot is removed and nothing replaces it, so the
        // UI shows no quota at all rather than another subscription's.
        applySubscriptionQuota(id, quota);
      }
      notifyChanged();
      reconfigureAutoUpdate();
      if (remoteContent !== null) {
        await reloadIfSelectedAndRunning(id);
      }
    });
  },

  async remove(id: string): Promise<void> {
    await runProfileOperation(id, async () => {
      findProfile(id);
      const store = settingsDatabase();
      store.transaction(() => {
        store.prepare("DELETE FROM profiles WHERE id = ?").run(id);
        // In the same transaction as the profile row, so a quota snapshot cannot outlive
        // its profile. Without this the table accumulates rows nothing will ever read,
        // update or delete - and a future profile that happened to reuse the id (it cannot
        // today, ids are UUIDs) would silently inherit a stranger's traffic figures.
        //
        // The schema declares no foreign key and nothing turns `PRAGMA foreign_keys` on, so
        // this is the only thing enforcing that - which is why it is here rather than
        // expected from the table definition.
        deleteSubscriptionQuota(store, id);
        if (selectedProfileId() === id) {
          const firstRow = store
            .prepare("SELECT id FROM profiles ORDER BY item_order ASC LIMIT 1")
            .get() as { id: string } | undefined;
          writeSelectedProfileId(firstRow === undefined ? null : firstRow.id);
        }
      })();
      try {
        await unlink(contentPath(id));
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
          throw error;
        }
      }
      notifyChanged();
      reconfigureAutoUpdate();
    });
  },

  async reorder(ids: string[]): Promise<void> {
    const store = settingsDatabase();
    store.transaction(() => {
      const currentIds = (
        store
          .prepare("SELECT id FROM profiles ORDER BY item_order ASC")
          .all() as { id: string }[]
      ).map((row) => row.id);
      const known = new Set(currentIds);
      const ordered = ids.filter((id) => known.has(id));
      const orderedSet = new Set(ordered);
      ordered.push(...currentIds.filter((id) => !orderedSet.has(id)));
      const updateOrderStatement = store.prepare(
        "UPDATE profiles SET item_order = ? WHERE id = ?",
      );
      for (const [index, id] of ordered.entries()) {
        updateOrderStatement.run(index, id);
      }
    })();
    notifyChanged();
  },

  async select(id: string): Promise<void> {
    await selectProfile(id);
  },

  async readContent(id: string): Promise<string> {
    findProfile(id);
    return await readFile(contentPath(id), "utf-8");
  },

  async writeContent(id: string, content: string): Promise<void> {
    await runProfileOperation(id, async () => {
      findProfile(id);
      await atomicWriteFile(contentPath(id), content);
      notifyChanged();
    });
  },

  async updateRemote(id: string): Promise<void> {
    await updateRemoteProfile(id);
  },

  async startService(): Promise<void> {
    await startSelectedProfile();
  },

  async takeOverService(): Promise<void> {
    if (desktopService === null) {
      throw new Error("daemon is not available");
    }
    await desktopService.takeOverService({});
    daemonState.retryConnection();
  },

  async pickImportFile(): Promise<{
    fileName: string;
    data: Uint8Array;
  } | null> {
    const result = await dialog.showOpenDialog({
      filters: [{ name: "sing-box profile", extensions: ["json", "bpf"] }],
      properties: ["openFile"],
    });
    if (result.canceled || result.filePaths.length === 0) {
      return null;
    }
    const filePath = result.filePaths[0];
    return { fileName: basename(filePath), data: await readFile(filePath) };
  },

  async importData(fileName: string, data: Uint8Array): Promise<void> {
    await importProfileData(fileName, data);
  },

  async decodeData(data: Uint8Array): Promise<{ name: string }> {
    const content = await applicationService.decodeProfile({ data });
    return { name: content.name };
  },

  async exportFile(id: string): Promise<boolean> {
    const profile = findProfile(id);
    const result = await dialog.showSaveDialog({
      defaultPath: `${profile.name}.json`,
      filters: [{ name: "sing-box configuration", extensions: ["json"] }],
    });
    if (result.canceled || !result.filePath) {
      return false;
    }
    await copyFile(contentPath(id), result.filePath);
    return true;
  },

  async exportData(id: string): Promise<boolean> {
    const profile = findProfile(id);
    const result = await dialog.showSaveDialog({
      defaultPath: `${profile.name}.bpf`,
      filters: [{ name: "sing-box profile", extensions: ["bpf"] }],
    });
    if (result.canceled || !result.filePath) {
      return false;
    }
    const data = await encodeProfileData(id);
    const cachePath = await writeApplicationCacheFile("share", ".bpf", data);
    await copyFile(cachePath, result.filePath);
    return true;
  },

  async encodeData(id: string): Promise<Uint8Array> {
    return await encodeProfileData(id);
  },
};

export function registerProfiles() {
  ipcMain.handle(
    PROFILES_CALL,
    async (
      _event,
      method: string,
      ...callArguments: unknown[]
    ): Promise<ProfilesResult> => {
      const handler = handlers[method];
      if (!handler) {
        return { ok: false, error: `unknown profiles method: ${method}` };
      }
      try {
        const value = await handler(...(callArguments as never[]));
        return { ok: true, value };
      } catch (error) {
        if (error instanceof ConnectError) {
          return { ok: false, error: error.rawMessage };
        }
        return {
          ok: false,
          error: error instanceof Error ? error.message : String(error),
        };
      }
    },
  );
  reconfigureAutoUpdate();
}
