import { electronAPI } from "@electron-toolkit/preload";
import { contextBridge } from "electron";

/**
 * Nothing app-specific exposed yet -- the renderer talks to the FastAPI
 * backend over plain HTTP (see src/renderer/src/lib/apiClient.ts), which
 * needs no main-process bridge. `electronAPI` (ipcRenderer helpers, process
 * versions) is exposed because @electron-toolkit/utils expects it to be.
 */
if (process.contextIsolated) {
  contextBridge.exposeInMainWorld("electron", electronAPI);
} else {
  // @ts-expect-error -- define on window without contextIsolation, dev-only fallback
  window.electron = electronAPI;
}
