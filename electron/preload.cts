// Preload: the only bridge between the page and the shell. Runs sandboxed, so it is
// CommonJS (.cts → .cjs). Exposes window.desktop, typed in src/lib/desktop.ts.
import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('desktop', {
  platform: process.platform,
  version: process.env.npm_package_version ?? '',
  info: () => ipcRenderer.invoke('desktop:info'),
  openExternal: (url: string) => ipcRenderer.invoke('desktop:open', url),
});
