/**
 * The bridge the Electron preload exposes as window.desktop (electron/preload.cts).
 * Absent in the browser; every caller must cope with that.
 */
export interface DesktopBridge {
  platform: string;
  version: string;
  info(): Promise<{ deviceId: string; deviceName: string; platform: string; version: string }>;
  openExternal(url: string): Promise<void>;
}

declare global {
  interface Window {
    desktop?: DesktopBridge;
  }
}

export function isDesktop(): boolean {
  return typeof window !== 'undefined' && Boolean(window.desktop);
}

export const APP_VERSION: string = typeof __APP_VERSION__ === 'string' ? __APP_VERSION__ : '0.0.0';

/** The commit this bundle was built from, and when — see vite.config.ts. */
export const BUILD_SHA: string = typeof __BUILD_SHA__ === 'string' ? __BUILD_SHA__ : 'dev';
export const BUILT_AT: string = typeof __BUILT_AT__ === 'string' ? __BUILT_AT__ : '';

export interface DeviceInfo {
  deviceId: string;
  deviceName: string;
  platform: string;
  version: string;
}

/** A stable id for this installation: the desktop's device.json, or a browser-local uuid. */
export async function deviceInfo(): Promise<DeviceInfo> {
  if (window.desktop) return window.desktop.info();
  let id: string | null = null;
  try {
    id = localStorage.getItem('erp.device_id');
    if (!id) {
      id = crypto.randomUUID();
      localStorage.setItem('erp.device_id', id);
    }
  } catch {
    id = 'browser';
  }
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? 'Edge' : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
  const os = /Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : /Mac/.test(ua) ? 'Mac' : /Linux/.test(ua) ? 'Linux' : '';
  return { deviceId: id, deviceName: `${browser}${os ? ` on ${os}` : ''}`, platform: 'web', version: APP_VERSION };
}

/** Open a link outside the app (system browser on desktop, new tab on the web). */
export function openExternal(url: string): void {
  if (window.desktop) void window.desktop.openExternal(url);
  else window.open(url, '_blank', 'noopener');
}
