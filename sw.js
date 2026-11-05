/* House to Home: deixa o app abrir sem internet. Nunca guarda respostas do Supabase (dados e login). */
const VER = 'hth-v1';
const SHELL = ['./', 'index.html', 'config.js', 'manifest.webmanifest', 'icons/icon-192.png', 'icons/icon-512.png', 'icons/apple-touch-icon.png'];
const CDN = ['https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js'];
self.addEventListener('install', e => {
  e.waitUntil((async () => {
    const c = await caches.open(VER);
    await Promise.allSettled([...SHELL.map(u => c.add(u)), ...CDN.map(u => c.add(new Request(u, { mode: 'no-cors' })))]);
    self.skipWaiting();
  })());
});
self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== VER) await caches.delete(k);
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET') return;
  const mine = u.origin === location.origin, cdn = CDN.includes(r.url);
  if (!mine && !cdn) return; // Supabase, Google, fontes: direto na rede
  if (mine && u.search) return; // verificação de versão: sempre direto na rede
  if (r.mode === 'navigate') {
    e.respondWith((async () => {
      try { const n = await fetch(r); const c = await caches.open(VER); c.put('index.html', n.clone()); return n }
      catch (x) { return (await caches.match('index.html')) || (await caches.match('./')) || Response.error() }
    })());
    return;
  }
  e.respondWith((async () => {
    const c = await caches.open(VER), hit = await c.match(r);
    const net = fetch(r).then(n => { if (n && (n.ok || n.type === 'opaque')) c.put(r, n.clone()); return n }).catch(() => null);
    return hit || (await net) || Response.error();
  })());
});
