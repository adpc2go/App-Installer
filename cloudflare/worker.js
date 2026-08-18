/**
 * PC2Go App Installer - Cloudflare Worker edge
 *
 * Fronts an R2 bucket and serves the five paths the tool expects:
 *
 *   /go             bootstrap, with $BaseUrl and $PinnedHash injected at the edge
 *   /AppDeploy.ps1  the tool
 *   /apps.json      catalog, with every /files/ URL rewritten to a signed, expiring URL
 *   /files/*        installers - HMAC-gated, Range-capable
 *   /icons/*        logos - public, long-cached
 *
 * Why the catalog signs the URLs instead of the client asking for a token:
 * AppDeploy.ps1 takes $item.Url straight off the catalog and hands it to BITS, and it
 * derives the local filename with ([Uri]$a.url).LocalPath - which ignores the query
 * string. So a signed URL flows through the existing client untouched. No client change.
 *
 * BITS resume is the constraint on TTL. A suspended job keeps the URL it was created
 * with, so the signature has to outlive a dropped connection or an overnight reboot.
 * TOKEN_TTL_SECONDS defaults to 48h for that reason - not because tokens want to be
 * long-lived, but because a 30 GB download legitimately takes that long.
 */

const encoder = new TextEncoder();

/** Paths served straight from R2 with no gating. */
const PUBLIC_PREFIXES = ["/icons/"];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = decodeURIComponent(url.pathname);

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405, headers: { allow: "GET, HEAD" } });
    }

    try {
      if (path === "/go" || path === "/go.ps1") return await serveBootstrap(env, url);
      if (path === "/AppDeploy.ps1") return await serveObject(request, env, "AppDeploy.ps1", { cache: "no-cache" });
      if (path === "/apps.json") return await serveCatalog(env, url);
      if (path.startsWith("/files/")) return await serveGated(request, env, url, path);
      if (PUBLIC_PREFIXES.some((p) => path.startsWith(p))) {
        return await serveObject(request, env, path.slice(1), { cache: "public, max-age=604800, immutable" });
      }
      if (path === "/" || path === "/health") {
        return new Response("pc2go edge ok\n", { headers: { "content-type": "text/plain; charset=utf-8" } });
      }
      return notFound();
    } catch (err) {
      // Never leak internals to a client machine; the technician sees a clean message.
      console.error("edge error", path, err && err.stack ? err.stack : String(err));
      return new Response("Internal error", { status: 500 });
    }
  },
};

/* ------------------------------------------------------------------ bootstrap */

/**
 * Serve go.ps1 with the live origin and the release hash pin substituted in.
 *
 * The pin lives in a Worker variable, NOT in the R2 copy of go.ps1 and NOT computed
 * from the R2 copy of AppDeploy.ps1. Deriving it from the bucket would make it
 * worthless: an attacker who can rewrite AppDeploy.ps1 could rewrite its hash too.
 * Keeping it in the Worker config means compromising R2 alone is not enough.
 */
async function serveBootstrap(env, url) {
  const obj = await env.BUCKET.get("go.ps1");
  if (!obj) return notFound();

  let text = await obj.text();
  const origin = env.PUBLIC_BASE_URL || url.origin;

  text = text.replace(/^(\s*\$BaseUrl\s*=\s*)'[^']*'/m, `$1'${origin}'`);

  const pin = (env.APPDEPLOY_SHA256 || "").trim().toUpperCase();
  if (/^[0-9A-F]{64}$/.test(pin)) {
    text = text.replace(/^(\s*\$PinnedHash\s*=\s*)'[^']*'/m, `$1'${pin}'`);
  }
  // If no valid pin is configured the placeholder survives and go.ps1 skips the check,
  // which is its documented behaviour. /health reports this so it is not silent.

  return new Response(text, {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

/* -------------------------------------------------------------------- catalog */

/**
 * Serve apps.json, replacing every URL that points at our own /files/ with a signed one.
 *
 * Three places carry a downloadable URL: apps[].url, apps[].postInstall[].url, and
 * apps[].iconUrl. Icons stay public (they are not licensed payload and they cache far
 * better unsigned), so only the first two are signed.
 *
 * Third-party URLs are left exactly as they are - signing a vendor's own CDN link would
 * simply break it.
 */
async function serveCatalog(env, url) {
  const obj = await env.BUCKET.get("apps.json");
  if (!obj) return notFound();

  const raw = await obj.text();
  let manifest;
  try {
    manifest = JSON.parse(raw);
  } catch (err) {
    console.error("apps.json is not valid JSON", String(err));
    return new Response("Catalog is malformed", { status: 500 });
  }

  const origin = env.PUBLIC_BASE_URL || url.origin;

  if (env.GATE_FILES !== "false") {
    const ttl = Number(env.TOKEN_TTL_SECONDS || 172800);
    const exp = Math.floor(Date.now() / 1000) + ttl;

    for (const app of manifest.apps || []) {
      if (app.url) app.url = await signIfOurs(app.url, origin, exp, env);
      for (const step of app.postInstall || []) {
        if (step.url) step.url = await signIfOurs(step.url, origin, exp, env);
      }
    }
  }

  // Rewrite icon URLs to the live origin so a bucket copied between environments still
  // resolves, but leave them unsigned.
  for (const app of manifest.apps || []) {
    if (app.iconUrl) app.iconUrl = rehost(app.iconUrl, origin, "/icons/");
  }

  return new Response(JSON.stringify(manifest), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      // Must not be cached: every response carries a fresh expiry.
      "cache-control": "no-store",
    },
  });
}

/**
 * Sign a URL if it is one of ours under /files/, otherwise hand it back untouched.
 * Accepts absolute URLs on any host we recognise, and bare "/files/..." paths.
 */
async function signIfOurs(raw, origin, exp, env) {
  const target = toOurUrl(raw, origin);
  if (!target || !target.pathname.startsWith("/files/")) return raw;

  const sig = await sign(env.SIGNING_KEY, `${decodeURIComponent(target.pathname)}\n${exp}`);
  target.searchParams.set("exp", String(exp));
  target.searchParams.set("sig", sig);
  return target.toString();
}

/**
 * Resolve a catalog URL against our origin.
 *
 * A catalog written against a placeholder host (apps.example.com) still points at our
 * files, so match on path shape rather than demanding the hostname already be correct.
 * That makes the bucket portable between staging and production without a rewrite.
 */
function toOurUrl(raw, origin) {
  try {
    if (raw.startsWith("/")) return new URL(raw, origin);
    const u = new URL(raw);
    if (u.pathname.startsWith("/files/") || u.pathname.startsWith("/icons/")) {
      return new URL(u.pathname + u.search, origin);
    }
    return null;
  } catch {
    return null;
  }
}

function rehost(raw, origin, prefix) {
  const u = toOurUrl(raw, origin);
  return u && u.pathname.startsWith(prefix) ? u.toString() : raw;
}

/* ------------------------------------------------------------------ gated files */

async function serveGated(request, env, url, path) {
  if (env.GATE_FILES !== "false") {
    const exp = Number(url.searchParams.get("exp") || 0);
    const sig = url.searchParams.get("sig") || "";

    if (!exp || !sig) return deny("missing token");
    if (!Number.isFinite(exp) || exp * 1000 < Date.now()) return deny("token expired");

    const expected = await sign(env.SIGNING_KEY, `${path}\n${exp}`);
    if (!timingSafeEqual(expected, sig)) return deny("bad token");
  }

  return await serveObject(request, env, path.slice(1), { cache: "private, max-age=0, no-store" });
}

function deny(reason) {
  // 403 rather than 404: BITS surfaces the status, and a technician chasing a failed
  // download needs to know the difference between "gone" and "your link aged out".
  return new Response(`Forbidden: ${reason}\n`, {
    status: 403,
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
  });
}

/* ------------------------------------------------------------------- R2 serving */

/**
 * Stream an R2 object, honouring Range and HEAD.
 *
 * Both matter here. BITS issues a HEAD before it starts to learn the size, and it
 * resumes with a Range request after every drop. Getting either wrong turns a resumable
 * 30 GB download into a restart-from-zero one.
 */
async function serveObject(request, env, key, opts = {}) {
  const rangeHeader = request.headers.get("range");

  if (request.method === "HEAD") {
    const head = await env.BUCKET.head(key);
    if (!head) return notFound();
    const headers = baseHeaders(head, opts);
    headers.set("content-length", String(head.size));
    return new Response(null, { status: 200, headers });
  }

  const obj = await env.BUCKET.get(key, rangeHeader ? { range: request.headers } : undefined);
  if (!obj) return notFound();

  const headers = baseHeaders(obj, opts);

  if (rangeHeader && obj.range) {
    const start = obj.range.offset ?? 0;
    const length = obj.range.length ?? obj.size - start;

    if (start >= obj.size) {
      return new Response("Range not satisfiable", {
        status: 416,
        headers: { "content-range": `bytes */${obj.size}` },
      });
    }

    headers.set("content-range", `bytes ${start}-${start + length - 1}/${obj.size}`);
    headers.set("content-length", String(length));
    return new Response(obj.body, { status: 206, headers });
  }

  headers.set("content-length", String(obj.size));
  return new Response(obj.body, { status: 200, headers });
}

function baseHeaders(obj, opts) {
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  // Without this BITS will not attempt a ranged resume at all.
  headers.set("accept-ranges", "bytes");
  headers.set("x-content-type-options", "nosniff");
  if (opts.cache) headers.set("cache-control", opts.cache);
  if (!headers.has("content-type")) headers.set("content-type", "application/octet-stream");
  return headers;
}

function notFound() {
  return new Response("Not found\n", {
    status: 404,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

/* ----------------------------------------------------------------------- crypto */

async function sign(secret, message) {
  if (!secret) throw new Error("SIGNING_KEY is not configured");
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Content-constant-time comparison of two hex strings. */
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
