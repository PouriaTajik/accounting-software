import { is } from "@electron-toolkit/utils";
import { app, BrowserWindow, shell } from "electron";
import { join } from "node:path";

/**
 * Spawning the FastAPI subprocess (and starting the embedded Postgres) is
 * not implemented yet -- see apps/desktop/README.md. For now this window
 * loads a renderer that polls GET /api/v1/health/ready itself and shows its
 * own "waiting for backend" state, so it behaves the same whether the API is
 * started by this process or, as in dev today, by `npm run api:dev`
 * pointed at Postgres from `npm run db:up`.
 */
function createWindow(): void {
  const window = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 960,
    minHeight: 600,
    show: false,
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(__dirname, "../preload/index.js"),
      sandbox: false,
    },
  });

  window.on("ready-to-show", () => window.show());

  // External links open in the OS browser, never inside the shell.
  window.webContents.setWindowOpenHandler((details) => {
    shell.openExternal(details.url);
    return { action: "deny" };
  });

  if (is.dev && process.env["ELECTRON_RENDERER_URL"]) {
    window.loadURL(process.env["ELECTRON_RENDERER_URL"]);
  } else {
    window.loadFile(join(__dirname, "../renderer/index.html"));
  }
}

app.whenReady().then(() => {
  createWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
