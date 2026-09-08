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
    navigator.serviceWorker.register('/sw.js').catch(() => undefined);
  });
}

ReactDOM.createRoot(root).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
