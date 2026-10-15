import { app } from "electron";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

import {
  applicationDataDirectoryName,
  daemonDataDirectoryName,
} from "./identity";
import { readWindowsInstallationLayout } from "./installationLayout";
import { secureApplicationUserData } from "./userDataSecurity";

export interface ApplicationPaths {
  userData: string;
  daemonData: string;
}

let configuredPaths: ApplicationPaths | null = null;

export function configureApplicationPaths(developmentUserDataPath: string): ApplicationPaths {
  if (configuredPaths !== null) {
    return configuredPaths;
  }
  // The per-user fallback, used outside a Windows installation and by the development
  // server. It has to be this fork's own directory: the upstream client keeps its
  // settings, profiles and session in %APPDATA%\sing-box, and sharing that tree means
  // each client reads the other's selected profile, preferences and window state.
  const defaultUserDataPath = join(app.getPath("appData"), applicationDataDirectoryName);
  let paths: ApplicationPaths;
  if (developmentUserDataPath !== "") {
    paths = {
      userData: developmentUserDataPath,
      daemonData:
        process.platform === "win32"
          ? `C:\\ProgramData\\${daemonDataDirectoryName}`
          : "/var/lib/sing-box-daemon",
    };
  } else if (process.platform === "win32" && app.isPackaged) {
    const layout = readWindowsInstallationLayout(defaultUserDataPath);
    paths = {
      userData: layout.applicationDataDirectory,
      daemonData: layout.daemonDataDirectory,
    };
  } else {
    paths = {
      userData: defaultUserDataPath,
      daemonData:
        process.platform === "win32"
          ? `C:\\ProgramData\\${daemonDataDirectoryName}`
          : "/var/lib/sing-box-daemon",
    };
  }

  const sessionDataPath = join(paths.userData, "session");
  const crashDumpsPath = join(paths.userData, "crash_dumps");
  secureApplicationUserData(paths.userData);
  mkdirSync(sessionDataPath, { recursive: true, mode: 0o700 });
  mkdirSync(crashDumpsPath, { recursive: true, mode: 0o700 });
  app.setPath("userData", paths.userData);
  app.setPath("sessionData", sessionDataPath);
  app.setPath("crashDumps", crashDumpsPath);
  configuredPaths = paths;
  return paths;
}

export function applicationPaths(): ApplicationPaths {
  if (configuredPaths === null) {
    throw new Error("application paths are not configured");
  }
  return configuredPaths;
}
