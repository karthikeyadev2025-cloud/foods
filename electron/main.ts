// Electron main process — the desktop shell (T11.1).
//
// The renderer is the same Vite build as the web app, loaded from dist/ with a hash
// router. Nothing here talks to Supabase: the app does, over HTTPS, exactly as in the
// browser. The shell adds a stable device id (for licensing), external-link handling,
// a single-instance lock and the window state.
//
//   npm run desktop:dev    dev server + electron
//   npm run desktop:dist   signed Windows installer under release/ (see docs/DESKTOP.md)
import { app, BrowserWindow, ipcMain, shell } from 'electron';
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { hostname } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const devServerUrl = process.env.VITE_DEV_SERVER_URL;

interface DeviceFile {
  deviceId: string;
}

/** A uuid written once to userData/device.json; survives updates, not a reinstall of Windows. */
function deviceId(): string {
  const file = path.join(app.getPath('userData'), 'device.json');
  try {
    if (existsSync(file)) {
      const parsed = JSON.parse(readFileSync(file, 'utf8')) as Partial<DeviceFile>;
      if (parsed.deviceId) return parsed.deviceId;
    }
  } catch {
    // unreadable: make a new one
  }
  const id = randomUUID();
  writeFileSync(file, JSON.stringify({ deviceId: id } satisfies DeviceFile), 'utf8');
  return id;
}

function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 1366,
    height: 768,
    minWidth: 1024,
    minHeight: 640,
    title: 'Jyothi Foods ERP',
    backgroundColor: '#f8fafc',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(here, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
    },
  });

  // Links to other sites open in the system browser, never inside the app.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) void shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (event, url) => {
    const allowed = devServerUrl ? url.startsWith(devServerUrl) : url.startsWith('file:');
    if (!allowed) {
      event.preventDefault();
      void shell.openExternal(url);
    }
  });

  if (devServerUrl) {
    void win.loadURL(devServerUrl);
    win.webContents.openDevTools({ mode: 'detach' });
  } else {
    void win.loadFile(path.join(here, '..', 'dist', 'index.html'));
  }
  return win;
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    const [win] = BrowserWindow.getAllWindows();
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
  });

  ipcMain.handle('desktop:info', () => ({
    deviceId: deviceId(),
    deviceName: hostname(),
    platform: process.platform,
    version: app.getVersion(),
  }));
  ipcMain.handle('desktop:open', (_event, url: unknown) => {
    if (typeof url === 'string' && /^https?:/.test(url)) return shell.openExternal(url);
    return Promise.resolve();
  });

  void app.whenReady().then(() => {
    createWindow();
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
  });

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
  });
}
