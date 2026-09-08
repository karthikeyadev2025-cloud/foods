// Writes the app marks — a flat brand-red tile with a cream inner square, no image
// library needed. Run once: node scripts/make-icons.mjs
//
//   public/icons/icon-192.png, icon-512.png   the phone's home-screen icon (PWA)
//   build/icon.ico                            the Windows exe and installer icon
import { deflateSync } from 'node:zlib';
import { mkdirSync, writeFileSync } from 'node:fs';

const crcTable = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type, data) => {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
};

function png(size) {
  const outer = [0x7c, 0x2d, 0x12]; // brand red
  const inner = [0xfb, 0xf8, 0xf4]; // cream
  const pad = Math.round(size * 0.22);
  const raw = Buffer.alloc((size * 3 + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (size * 3 + 1)] = 0; // filter: none
    for (let x = 0; x < size; x++) {
      const insideSquare = x >= pad && x < size - pad && y >= pad && y < size - pad;
      // a small "J" notch: cut the top-left corner of the inner square
      const notch = insideSquare && x < pad + (size - 2 * pad) * 0.3 && y < pad + (size - 2 * pad) * 0.3;
      const [r, g, b] = insideSquare && !notch ? inner : outer;
      const i = y * (size * 3 + 1) + 1 + x * 3;
      raw[i] = r;
      raw[i + 1] = g;
      raw[i + 2] = b;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type RGB
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

/**
 * A .ico is a small directory followed by the images. Windows Vista and later read
 * PNG-compressed entries, so each size is the same PNG the web build uses.
 */
function ico(sizes) {
  const images = sizes.map(png);
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0); // reserved
  header.writeUInt16LE(1, 2); // 1 = icon
  header.writeUInt16LE(sizes.length, 4);
  let offset = 6 + sizes.length * 16;
  const entries = sizes.map((size, i) => {
    const e = Buffer.alloc(16);
    e.writeUInt8(size >= 256 ? 0 : size, 0); // 0 means 256
    e.writeUInt8(size >= 256 ? 0 : size, 1);
    e.writeUInt8(0, 2); // colours in palette
    e.writeUInt8(0, 3); // reserved
    e.writeUInt16LE(1, 4); // colour planes
    e.writeUInt16LE(32, 6); // bits per pixel
    e.writeUInt32LE(images[i].length, 8);
    e.writeUInt32LE(offset, 12);
    offset += images[i].length;
    return e;
  });
  return Buffer.concat([header, ...entries, ...images]);
}

mkdirSync('public/icons', { recursive: true });
for (const size of [192, 512]) writeFileSync(`public/icons/icon-${size}.png`, png(size));
mkdirSync('build', { recursive: true });
writeFileSync('build/icon.ico', ico([16, 32, 48, 64, 128, 256]));
console.log('wrote public/icons/icon-192.png, icon-512.png and build/icon.ico');
