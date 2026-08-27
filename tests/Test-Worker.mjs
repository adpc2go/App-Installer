/**
 * The Cloudflare Worker's catalog filtering, tested against the real worker.js.
 *
 * Until now worker.js had no tests at all - the HMAC signing, the Range handling and the
 * catalog rewrite were covered only by a manual checklist in cloudflare/README.md. That was
 * survivable while the Worker only passed bytes through. It stopped being survivable when it
 * started DECIDING WHICH APPLICATIONS A CLIENT CAN SEE: a filter that is too aggressive hides
 * an app a technician needs, and one that is too lax puts a row in front of them that downloads
 * 15 GB and then refuses itself on a hash mismatch.
 *
 * The real source is imported, not copied. worker.js is an ES module and this repository has no
 * package.json, so Node would otherwise treat a .js file as CommonJS and the import would fail.
 * Loading it through a data: URL sidesteps that without adding a package.json the deploy does
 * not need - and it still tests the file that ships, byte for byte.
 *
 * Run:  node tests\Test-Worker.mjs
 */

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const workerPath = join(here, '..', 'cloudflare', 'worker.js');

let pass = 0, fail = 0;
const eq = (what, expected, actual) => {
  if (String(expected) === String(actual)) { pass++; console.log(`  PASS  ${what}`); }
  else { fail++; console.log(`  FAIL  ${what}\n          expected [${expected}]\n          actual   [${actual}]`); }
};
const ok = (what, cond) => eq(what, true, Boolean(cond));
const section = (t) => console.log(`\n${t}\n${'-'.repeat(t.length)}`);

const src = await readFile(workerPath, 'utf8');
const worker = (await import('data:text/javascript;base64,' + Buffer.from(src).toString('base64'))).default;

const REAL = 'a'.repeat(64);
const REAL2 = 'b'.repeat(64);

/** A stand-in for the R2 binding: just enough of it to serve one object. */
const makeEnv = (catalog, extra = {}) => ({
  BUCKET: {
    get: async (key) => (key === 'apps.json' ? { text: async () => JSON.stringify(catalog) } : null),
  },
  SIGNING_KEY: 'test-signing-key',
  GATE_FILES: 'true',
  TOKEN_TTL_SECONDS: '172800',
  PUBLIC_BASE_URL: '',
  ...extra,
});

const getCatalog = async (catalog, extra) => {
  const res = await worker.fetch(new Request('https://apps.pc2go.ca/apps.json'), makeEnv(catalog, extra));
  return { res, body: res.status === 200 ? await res.json() : null };
};

// ---------------------------------------------------------------- 1. the filter
section('1. Only installable applications are served');

const mixed = {
  manifestVersion: 1,
  updated: '2026-08-19',
  apps: [
    { id: 'ready', name: 'Ready App', sha256: REAL, url: 'https://apps.pc2go.ca/files/ready/s.exe',
      sizeBytes: 10, uninstall: { command: 'x', args: 'y', detect: 'z' },
      cleanup: { tokens: ['Ready'], paths: [], registry: [], hosts: [] },
      iconUrl: 'https://apps.example.com/icons/ready.png' },
    { id: 'placeholder', name: 'Not Uploaded', sha256: 'REPLACE_WITH_REAL_SHA256',
      url: 'https://apps.pc2go.ca/files/placeholder/s.exe', sizeBytes: 20 },
    { id: 'nourl', name: 'No URL', sha256: REAL2, url: '', sizeBytes: 30 },
    { id: 'shorthash', name: 'Truncated Hash', sha256: 'a'.repeat(63),
      url: 'https://apps.pc2go.ca/files/shorthash/s.exe', sizeBytes: 40 },
    { id: 'nohash', name: 'Empty Hash', sha256: '',
      url: 'https://apps.pc2go.ca/files/nohash/s.exe', sizeBytes: 50 },
  ],
};

{
  const { res, body } = await getCatalog(mixed);
  eq('the catalog is served', 200, res.status);
  eq('only the installable app is served', 1, body.apps.length);
  eq('and it is the right one', 'ready', body.apps[0].id);

  const ids = body.apps.map((a) => a.id);
  ok('a placeholder hash is dropped', !ids.includes('placeholder'));
  ok('a real hash with no url is dropped', !ids.includes('nourl'));
  // 63 hex characters is not a hash, and a prefix match would have let it through - exactly the
  // near-miss that reaches a client and only fails after the whole download.
  ok('a 63-character hash is dropped', !ids.includes('shorthash'));
  ok('an empty hash is dropped', !ids.includes('nohash'));

  // Dropping rows must not quietly damage the rows that survive.
  eq('the surviving app keeps its uninstall command', 'x', body.apps[0].uninstall.command);
  eq('and its cleanup tokens', 'Ready', body.apps[0].cleanup.tokens[0]);
  ok('its url is signed for the client', /[?&]sig=/.test(body.apps[0].url) && /[?&]exp=/.test(body.apps[0].url));
  ok('and its icon is rehosted onto the live origin', body.apps[0].iconUrl.startsWith('https://apps.pc2go.ca/icons/'));
  eq('manifestVersion survives', 1, body.manifestVersion);
}

{
  // An uninstall-only entry carries removal knowledge for a product we never install - no url,
  // no install hash, and the filter must NOT drop it. Its removal detail has to arrive intact,
  // and an installable placeholder must not sneak through by wearing the flag with a url.
  const unOnly = { manifestVersion: 1, apps: [
    { id: 'ready', sha256: REAL, url: 'https://apps.pc2go.ca/files/ready/s.exe' },
    { id: 'avast-like', name: 'Avast Free Antivirus', uninstallOnly: true,
      uninstall: { command: 'Instup.exe', args: '/instop:uninstall /silent', detect: 'AvastUI.exe' },
      cleanup: { tokens: ['Avast'],
                 removers: [{ name: 'avastclear', url: 'https://apps.pc2go.ca/files/removers/avastclear.exe',
                              sha256: 'REPLACE_WITH_REAL_SHA256', args: '/silent' }] } },
    { id: 'flagged-placeholder', uninstallOnly: false, sha256: 'REPLACE_WITH_REAL_SHA256',
      url: 'https://apps.pc2go.ca/files/x/s.exe' },
  ] };
  const { body } = await getCatalog(unOnly);
  eq('an uninstall-only entry survives the filter', 2, body.apps.length);
  const av = body.apps.find((a) => a.id === 'avast-like');
  ok('and it is the uninstall-only one', Boolean(av));
  eq('its vendor uninstall command arrives intact', 'Instup.exe', av.uninstall.command);
  eq('and its remover rides along', 'avastclear', av.cleanup.removers[0].name);
  ok('with its /files/ url SIGNED - it downloads at wipe time, and unsigned would 403',
     /[?&]sig=/.test(av.cleanup.removers[0].url) && /[?&]exp=/.test(av.cleanup.removers[0].url));
  ok('while a placeholder with the flag set false is still dropped',
     !body.apps.some((a) => a.id === 'flagged-placeholder'));
}

// ---------------------------------------------------------------- 1b. access gate
section('1b. The access code gate');

{
  const cat = { manifestVersion: 1, apps: [
    { id: 'a', sha256: REAL, url: 'https://apps.pc2go.ca/files/a/s.exe' } ] };
  const gated = { ACCESS_CODE: 'sesame' };
  // no code -> refused, with the marker header go.ps1 keys its prompt on
  let res = await worker.fetch(new Request('https://apps.pc2go.ca/apps.json'), makeEnv(cat, gated));
  eq('the catalog is refused without a code', 403, res.status);
  eq('and says so in the marker header', 'required', res.headers.get('x-pc2go-auth'));
  res = await worker.fetch(new Request('https://apps.pc2go.ca/apps.json',
        { headers: { 'x-pc2go-code': 'wrong' } }), makeEnv(cat, gated));
  eq('a wrong code is refused', 403, res.status);
  res = await worker.fetch(new Request('https://apps.pc2go.ca/apps.json',
        { headers: { 'x-pc2go-code': 'sesame' } }), makeEnv(cat, gated));
  eq('the right code is served', 200, res.status);
  ok('with real content', (await res.json()).apps.length === 1);
  res = await worker.fetch(new Request('https://apps.pc2go.ca/apps.json?code=sesame'), makeEnv(cat, gated));
  eq('?code= works for hand testing', 200, res.status);
  // the TOOL is gated too - the 403 must come before the object lookup (the stub env holds
  // no AppDeploy.ps1, so a 404 here would mean the gate ran; a 403 means it ran FIRST)
  res = await worker.fetch(new Request('https://apps.pc2go.ca/AppDeploy.ps1'), makeEnv(cat, gated));
  eq('the tool is refused without a code', 403, res.status);
  res = await worker.fetch(new Request('https://apps.pc2go.ca/AppDeploy.ps1',
        { headers: { 'x-pc2go-code': 'sesame' } }), makeEnv(cat, gated));
  eq('and looked up once the code is right (404: stub bucket holds no tool)', 404, res.status);
  // the bootstrap stays open - it is useless without what it fetches
  res = await worker.fetch(new Request('https://apps.pc2go.ca/go'), makeEnv(cat, gated));
  ok('/go stays open', res.status !== 403);
  // and with NO secret configured nothing is gated - the code ships dormant
  res = await worker.fetch(new Request('https://apps.pc2go.ca/apps.json'), makeEnv(cat));
  eq('no ACCESS_CODE secret = open, backwards compatible', 200, res.status);
}

// ---------------------------------------------------------------- 2. edges
section('2. Edges: everything ready, and nothing ready');

{
  const allGood = { manifestVersion: 1, apps: [
    { id: 'a', sha256: REAL, url: 'https://apps.pc2go.ca/files/a/s.exe' },
    { id: 'b', sha256: REAL2, url: 'https://apps.pc2go.ca/files/b/s.exe' },
  ] };
  const { body } = await getCatalog(allGood);
  eq('a fully finished catalog is served whole', 2, body.apps.length);
}

{
  // Every app filtered out leaves an empty array. AppDeploy's Load-Catalog treats that as a
  // failed load and shows a red badge - the correct, loud behaviour, but worth pinning here so
  // nobody "fixes" it into a green badge with no rows. Publish-Release refuses to publish such
  // a catalog in the first place.
  const noneReady = { manifestVersion: 1, apps: [
    { id: 'a', sha256: 'REPLACE_WITH_REAL_SHA256', url: 'https://apps.pc2go.ca/files/a/s.exe' },
  ] };
  const { res, body } = await getCatalog(noneReady);
  eq('a catalog with nothing ready still returns 200', 200, res.status);
  eq('with an empty apps array rather than a phantom row', 0, body.apps.length);
}

{
  const weird = { manifestVersion: 1, apps: [null, { id: 'a', sha256: REAL, url: 'https://apps.pc2go.ca/files/a/s.exe' }] };
  const { body } = await getCatalog(weird);
  eq('a null entry does not crash the Worker', 1, body.apps.length);
}

// ---------------------------------------------------------------- 3. regressions
section('3. The filter did not break what already worked');

{
  // postInstall urls are signed too, and the filter runs before signing - so a surviving app
  // must still get every one of its urls signed.
  const withPost = { manifestVersion: 1, apps: [
    { id: 'a', sha256: REAL, url: 'https://apps.pc2go.ca/files/a/s.exe',
      postInstall: [{ type: 'run', name: 'patch', url: 'https://apps.pc2go.ca/files/a/patch.exe', sha256: REAL2 }] },
  ] };
  const { body } = await getCatalog(withPost);
  ok('a postInstall url is still signed', /[?&]sig=/.test(body.apps[0].postInstall[0].url));

  const third = { manifestVersion: 1, apps: [
    { id: 'a', sha256: REAL, url: 'https://vendor.example.net/setup.exe' },
  ] };
  const { body: b2 } = await getCatalog(third);
  eq('a third-party vendor url is left alone', 'https://vendor.example.net/setup.exe', b2.apps[0].url);
}

{
  const env = makeEnv(mixed);
  const denied = await worker.fetch(new Request('https://apps.pc2go.ca/files/ready/s.exe'), env);
  eq('an unsigned /files/ request is still refused', 403, denied.status);

  const health = await worker.fetch(new Request('https://apps.pc2go.ca/health'), env);
  eq('/health still answers', 200, health.status);

  const nope = await worker.fetch(new Request('https://apps.pc2go.ca/nothing-here'), env);
  eq('an unknown path is still 404', 404, nope.status);

  const post = await worker.fetch(new Request('https://apps.pc2go.ca/apps.json', { method: 'POST' }), env);
  eq('a non-GET is still refused', 405, post.status);
}

{
  // GATE_FILES=false is the documented escape hatch. The filter must apply either way, or
  // turning gating off would start serving uninstallable rows again.
  const { body } = await getCatalog(mixed, { GATE_FILES: 'false' });
  eq('the filter still applies when gating is off', 1, body.apps.length);
  ok('and urls are then unsigned', !/[?&]sig=/.test(body.apps[0].url));
}

console.log('');
console.log(`PASS ${pass}   FAIL ${fail}`);
process.exit(fail ? 1 : 0);
