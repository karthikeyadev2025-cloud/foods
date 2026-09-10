import React from 'react';
import ReactDOM from 'react-dom/client';
import { App } from '@/app/App';
import { isDesktop } from '@/lib/desktop';
import './index.css';

const root = document.getElementById('root');
if (!root) throw new Error('#root not found');

// The phone installs the web build as an app; the shell is cached so it opens offline.
if (import.meta.env.PROD && !isDesktop() && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    void navigator.serviceWorker.register('/sw.js').catch(() => undefined);
  });

  /**
   * Reload once when a newly deployed worker takes over.
   *
   * Without this, an installed app window can sit open for days serving the
   * build it started with — the deploy lands, the person reopens the app, and
   * the change is simply not there. The worker calls skipWaiting() and
   * clients.claim(), so controllerchange is the moment the new code is ready;
   * the flag stops the reload from firing a second time.
   */
  let reloading = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (reloading) return;
    reloading = true;
    window.location.reload();
  });
}

ReactDOM.createRoot(root).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
