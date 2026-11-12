import { Menu, Tray, app, nativeImage, screen } from "electron";
import type { MenuItemConstructorOptions, NativeImage, Rectangle } from "electron";

import { ServiceStatus_Type } from "../shared/gen/daemon/started_service_pb";
import { SelectionLedger } from "../shared/selectionIdentity";
import { desktopLanguageFromLocale, translateDesktop } from "../shared/translations";
import type { DesktopMessageKey } from "../shared/translations";
import { managedService, startedService } from "./daemon";
import { preferredLocale } from "./locale";
import { onPreferenceChanged } from "./preferences";
import { onProfilesChanged, profilesState, selectProfile, startSelectedProfile } from "./profiles";
import { resourcePath } from "./resources";
import { daemonState } from "./state";
import { destroyTrayMenuWindow, hideTrayMenu, prepareTrayMenuWindow, showTrayMenu } from "./trayMenu";
import { X11Tray } from "./x11Tray";

const DOUBLE_ACTIVATE_INTERVAL_MILLISECONDS = 500;

// The tray's only persistent selection state. It outlives one menu rebuild on purpose: a rebuild
// between the click and the daemon's answer must not drop the attempt it is waiting for.
const selectionLedger = new SelectionLedger();

let tray: Tray | null = null;
let x11Tray: X11Tray | null = null;
let openWindow: () => void = () => {};
let serviceStarted = false;

function cursorAnchor(): Rectangle {
  const cursor = screen.getCursorScreenPoint();
  return { x: cursor.x, y: cursor.y, width: 0, height: 0 };
}

// Plasma's system tray sends the icon position, not the cursor position, in
// ContextMenu/Activate/SecondaryActivate, and it does so in Wayland sessions
// too — where the cursor position read through XWayland is stale. On X11 the
// coordinates are device pixels while Chromium's screen space is DIPs; in
// Wayland sessions plasmashell sends logical coordinates, which match
// Chromium's DIP space in both XWayland scaling modes. Other SNI hosts send
// (0, 0) or coordinates outside any display.
function clickAnchor(clickX: number, clickY: number): Rectangle {
  let x = clickX;
  let y = clickY;
  if (process.env.XDG_SESSION_TYPE?.toLowerCase() !== "wayland") {
    const scaleFactor = screen.getPrimaryDisplay().scaleFactor;
    x = Math.round(x / scaleFactor);
    y = Math.round(y / scaleFactor);
  }
  const insideDisplay = screen.getAllDisplays().some((display) => {
    const bounds = display.bounds;
    return (
      x >= bounds.x &&
      x < bounds.x + bounds.width &&
      y >= bounds.y &&
      y < bounds.y + bounds.height
    );
  });
  if ((clickX === 0 && clickY === 0) || !insideDisplay) {
    return cursorAnchor();
  }
  return { x, y, width: 0, height: 0 };
}

function translate(key: DesktopMessageKey): string {
  return translateDesktop(desktopLanguageFromLocale(preferredLocale()), key);
}

function ignoreErrors(promise: Promise<unknown> | undefined) {
  void promise?.catch((error) => {
    console.error("tray action:", error);
  });
}

// Sends one selection with its own request identity and settles it by that identity.
//
// The menu is rebuilt from the groups stream, so the radio follows the daemon anyway; what this
// adds is that an answer for a replaced attempt, or an answer from a daemon that cannot name the
// attempt, is never read as this click's confirmation.
function selectGroupItem(groupTag: string, outboundTag: string) {
  const snapshot = selectionLedger.begin(groupTag, outboundTag);
  const answer = startedService?.selectOutbound({
    groupTag,
    outboundTag,
    requestId: snapshot.requestId,
    expectedRevision: snapshot.expectedRevision,
  });
  if (answer === undefined) {
    selectionLedger.fail(snapshot, "the daemon is not connected");
    return;
  }
  void answer.then(
    (response) => {
      const settlement = selectionLedger.settle(snapshot, {
        requestId: response.requestId,
        appliedOutboundTag: response.appliedOutboundTag,
        appliedRevision: response.appliedRevision,
        stale: response.stale,
      });
      if (settlement.kind === "unconfirmed") {
        console.warn(`select outbound: ${settlement.reason}`);
      } else if (settlement.kind === "applied" && settlement.stale) {
        console.warn(`select outbound: request ${snapshot.requestId} was applied against a group state this client had not seen`);
      }
    },
    (error: unknown) => {
      selectionLedger.fail(snapshot, String(error));
      console.error("select outbound:", error);
    },
  );
}

function groupsSubmenu(): MenuItemConstructorOptions[] {
  const selectableGroups = daemonState.groups.filter((group) => group.selectable);
  const items: MenuItemConstructorOptions[] = [
    {
      label: translate("URLTest All"),
      click: () => {
        for (const group of selectableGroups) {
          ignoreErrors(startedService?.uRLTest({ outboundTag: group.tag }));
        }
      },
    },
    {
      label: translate("Close All Connections"),
      click: () => ignoreErrors(startedService?.closeAllConnections({})),
    },
    { type: "separator" },
  ];
  for (const group of selectableGroups) {
    items.push({
      label: group.tag,
      submenu: [
        {
          label: translate("URLTest"),
          click: () => ignoreErrors(startedService?.uRLTest({ outboundTag: group.tag })),
        },
        { type: "separator" },
        ...group.items.map((item) => ({
          label: item.urlTestDelay > 0 ? `${item.tag} (${item.urlTestDelay}ms)` : item.tag,
          type: "radio" as const,
          checked:
            selectionLedger.pendingSelection(group.tag) !== null
              ? selectionLedger.pendingSelection(group.tag)?.outboundTag === item.tag
              : item.tag === group.selected,
          click: () => selectGroupItem(group.tag, item.tag),
        })),
      ],
    });
  }
  return items;
}

function buildTrayTemplate(): MenuItemConstructorOptions[] {
  const started = daemonState.status === ServiceStatus_Type.STARTED;
  const { selectedId, profiles } = profilesState();
  const template: MenuItemConstructorOptions[] = [{ label: "sing-box", enabled: false }];
  if (started) {
    template.push({
      label: translate("Stop"),
      click: () => ignoreErrors(managedService?.stopService({})),
    });
  } else {
    template.push({
      label: translate("Start"),
      enabled: daemonState.connection.phase === "connected",
      click: () => ignoreErrors(startSelectedProfile()),
    });
  }
  template.push({ type: "separator" });
  if (started && daemonState.groups.some((group) => group.selectable)) {
    template.push({ label: translate("Group"), submenu: groupsSubmenu() });
  }
  template.push({
    label: translate("Profiles"),
    submenu:
      profiles.length === 0
        ? [{ label: translate("No profiles"), enabled: false }]
        : profiles.map((profile) => ({
            label: profile.name,
            type: "radio" as const,
            checked: profile.id === selectedId,
            click: () => ignoreErrors(selectProfile(profile.id)),
          })),
  });
  template.push({ type: "separator" });
  template.push({ label: translate("Open"), click: () => openWindow() });
  template.push({ label: translate("Quit"), click: () => app.quit() });
  return template;
}

export function rebuildTrayMenu() {
  // Electron's Windows context menu suppresses the tray click events used by
  // the custom menu window.
  if (tray === null || process.platform === "win32") {
    return;
  }
  tray.setContextMenu(Menu.buildFromTemplate(buildTrayTemplate()));
}

function trayIconPath(): string {
  if (process.platform === "darwin") {
    return resourcePath(serviceStarted ? "trayTemplate.png" : "trayStoppedTemplate.png");
  }
  if (process.platform === "win32") {
    return resourcePath(serviceStarted ? "tray.ico" : "trayStopped.ico");
  }
  return resourcePath(serviceStarted ? "tray.png" : "trayStopped.png");
}

function trayIcon(): NativeImage {
  const icon = nativeImage.createFromPath(trayIconPath());
  if (process.platform === "darwin") {
    icon.setTemplateImage(true);
  }
  return icon;
}

function updateTrayIcon() {
  const started = daemonState.status === ServiceStatus_Type.STARTED;
  if (started === serviceStarted) {
    return;
  }
  serviceStarted = started;
  tray?.setImage(trayIcon());
  x11Tray?.setIcon(trayIconPath());
}

export function initializeTray(open: () => void) {
  openWindow = open;
  daemonState.on("change", updateTrayIcon);
  if (process.platform !== "win32") {
    daemonState.on("change", rebuildTrayMenu);
    onProfilesChanged(rebuildTrayMenu);
    onPreferenceChanged((name) => {
      if (name === "language") {
        rebuildTrayMenu();
      }
    });
  }
  daemonState.start();
}

function createElectronTray() {
  tray = new Tray(trayIcon());
  tray.setToolTip("sing-box");
  if (process.platform === "win32") {
    prepareTrayMenuWindow(tray.getBounds());
    const popMenu = (bounds: Rectangle) => {
      void showTrayMenu(bounds);
    };
    tray.on("click", (_event, bounds) => popMenu(bounds));
    tray.on("right-click", (_event, bounds) => popMenu(bounds));
    tray.on("double-click", () => {
      hideTrayMenu();
      openWindow();
    });
    return;
  }
  rebuildTrayMenu();
}

export function updateTrayVisibility(enabled: boolean) {
  if (!enabled) {
    tray?.destroy();
    tray = null;
    x11Tray?.destroy();
    x11Tray = null;
    destroyTrayMenuWindow();
    return;
  }
  if (tray !== null || x11Tray !== null) {
    return;
  }
  // Electron resolves the ozone platform before the main script runs and
  // appends the result to its command line, so the switch value reports the
  // platform actually in use even when nothing was passed.
  if (process.platform !== "linux" || app.commandLine.getSwitchValue("ozone-platform") !== "x11") {
    createElectronTray();
    return;
  }
  prepareTrayMenuWindow(cursorAnchor());
  const popMenu = (x: number, y: number) => {
    void showTrayMenu(clickAnchor(x, y));
  };
  let lastActivateAt = 0;
  let currentTray: X11Tray;
  try {
    currentTray = new X11Tray(trayIconPath(), popMenu, (x, y) => {
      const now = Date.now();
      if (now - lastActivateAt < DOUBLE_ACTIVATE_INTERVAL_MILLISECONDS) {
        lastActivateAt = 0;
        hideTrayMenu();
        openWindow();
        return;
      }
      lastActivateAt = now;
      popMenu(x, y);
    });
  } catch (error: unknown) {
    console.error("failed to create X11 tray:", error);
    destroyTrayMenuWindow();
    createElectronTray();
    return;
  }
  x11Tray = currentTray;
  void currentTray.ready.catch((error: unknown) => {
    if (x11Tray !== currentTray) {
      return;
    }
    console.error("failed to initialize X11 tray:", error);
    currentTray.destroy();
    x11Tray = null;
    destroyTrayMenuWindow();
    createElectronTray();
  });
}
