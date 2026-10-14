// Shared client for the signed remote compat profile (dreamskin-compat-profile/1).
//
// tools/sync-runtime-assets.mjs stages this file verbatim into both platform
// asset trees (macos/assets, windows/assets) and both platform injectors import
// it from there, so the fetch/verify/merge logic exists exactly once. Keep this
// module pure and stdlib-only: it runs on the ChatGPT-bundled Node runtime,
// whose version we do not control, so no fetch()/AbortController and no APIs
// newer than what the injectors already require.
//
// Contract: docs/compat-profile-design.md. Everything here is fail-closed —
// any rejection drops the WHOLE profile; nothing is partially applied and the
// caller keeps the built-in selector contract from assets/selectors.json.

import { createPublicKey, sign as cryptoSign, verify as cryptoVerify } from "node:crypto";
import fs from "node:fs/promises";
import http from "node:http";
import https from "node:https";
import os from "node:os";
import path from "node:path";

export const COMPAT_PROFILE_SCHEMA = "dreamskin-compat-profile/1";
// Fixed distribution endpoint; step 1 of the chain pins the request to exactly
// this origin (https + no cross-origin redirects).
export const COMPAT_PROFILE_URL =
  "https://raw.githubusercontent.com/CCDawn/Codex-Dynamic-Skin/main/compat/profile.json";
export const COMPAT_PROFILE_ORIGIN = "https://raw.githubusercontent.com";
export const COMPAT_PROFILE_MAX_BYTES = 64 * 1024;
export const COMPAT_PROFILE_TIMEOUT_MS = 5000;
export const COMPAT_PROFILE_USER_AGENT = "CodexDreamSkin-CompatProfile/1";

// Trusted ed25519 public keys (base64 DER SPKI). A profile is accepted when ANY
// listed key verifies it, so key rotation ships a client with both old and new
// keys while previously signed profiles stay valid. Rotation runbook:
// docs/compat-profile-runbook.md (append the new key, ship, retire the old one
// in a later release).
export const COMPAT_PROFILE_PUBLIC_KEYS = [
  "MCowBQYDK2VwAyEAGMTdXzS1zKlphJw+v5aNUBRR05lw40LdTkwIwacrcRg=",
];

const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

// Deterministic signing envelope: every top-level field except `signature`,
// serialized with recursively dictionary-ordered keys and no insignificant
// whitespace. The signing tool (tools/build-compat-profile*) must produce the
// exact same bytes; the test suite pins this shape.
export function canonicalCompatProfileJson(profile) {
  const serialize = (value) => {
    if (value === null || typeof value !== "object") return JSON.stringify(value);
    if (Array.isArray(value)) return `[${value.map(serialize).join(",")}]`;
    const entries = Object.keys(value).sort()
      .map((key) => `${JSON.stringify(key)}:${serialize(value[key])}`);
    return `{${entries.join(",")}}`;
  };
  const unsigned = { ...profile };
  delete unsigned.signature;
  return serialize(unsigned);
}

function signatureBytes(profile) {
  if (typeof profile.signature !== "string" || !profile.signature.startsWith("ed25519:")) {
    return null;
  }
  const bytes = Buffer.from(profile.signature.slice("ed25519:".length), "base64");
  return bytes.length === 64 ? bytes : null;
}

// Step 5 in isolation: ed25519 verification against the trusted key set.
export function verifyCompatProfile(profile, publicKeys = COMPAT_PROFILE_PUBLIC_KEYS) {
  if (!profile || typeof profile !== "object" || Array.isArray(profile)) return false;
  const signature = signatureBytes(profile);
  if (!signature) return false;
  const message = Buffer.from(canonicalCompatProfileJson(profile), "utf8");
  for (const encodedKey of Array.isArray(publicKeys) ? publicKeys : []) {
    if (typeof encodedKey !== "string" || !encodedKey) continue;
    try {
      const publicKey = createPublicKey({
        key: Buffer.from(encodedKey, "base64"),
        format: "der",
        type: "spki",
      });
      if (cryptoVerify(null, message, publicKey, signature)) return true;
    } catch {
      // An unusable entry (rotation typo, truncated base64) must not abort the
      // remaining trusted keys.
    }
  }
  return false;
}

function localContractKeys(localContract) {
  if (localContract instanceof Set) return localContract;
  if (localContract instanceof Map) return new Set(localContract.keys());
  if (Array.isArray(localContract)) return new Set(localContract);
  if (localContract && Array.isArray(localContract.selectors)) {
    const keys = new Set();
    for (const entry of localContract.selectors) {
      if (entry && typeof entry.key === "string" && entry.key) keys.add(entry.key);
    }
    return keys;
  }
  return null;
}

// Pure merge step: only selector strings of keys that already exist in the
// built-in contract may be overridden. Any unknown/invalid entry rejects the
// whole mapping (null) — the caller then keeps the built-in contract entirely.
// `localContract` accepts the injector's SELECTOR_MAP, a Set/Array of keys, or
// the raw selectors contract object.
export function buildOverrides(profile, localContract) {
  if (!profile || typeof profile !== "object" || !Array.isArray(profile.selectors)) return null;
  const keys = localContractKeys(localContract);
  if (!keys || keys.size === 0) return null;
  const overrides = {};
  for (const entry of profile.selectors) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null;
    if (typeof entry.key !== "string" || !entry.key || !keys.has(entry.key)) return null;
    if (typeof entry.selector !== "string" || !entry.selector) return null;
    overrides[entry.key] = entry.selector;
  }
  return overrides;
}

function semverParts(value) {
  if (typeof value !== "string") return null;
  const match = /^(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?$/.exec(value.trim());
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null;
}

function semverAtMost(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] < right[index];
  }
  return true;
}

function isoTimestamp(value) {
  if (typeof value !== "string" || !ISO_DATE.test(value)) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

// Step 3: structural schema validation. `css` (top level or per entry) is not
// supported this iteration and rejects the whole profile.
function profileShapeReason(profile) {
  if (!profile || typeof profile !== "object" || Array.isArray(profile)) return "shape";
  if (profile.schema !== COMPAT_PROFILE_SCHEMA) return "schema";
  if (hasOwn(profile, "css")) return "css-unsupported";
  if (!Number.isSafeInteger(profile.revision) || profile.revision < 1) return "revision-shape";
  if (isoTimestamp(profile.issuedAt) === null) return "issuedAt-shape";
  if (isoTimestamp(profile.expiresAt) === null) return "expiresAt-shape";
  if (semverParts(profile.minClient) === null) return "minClient-shape";
  if (typeof profile.signature !== "string") return "signature-shape";
  if (!Array.isArray(profile.selectors) || profile.selectors.length === 0) return "selectors-shape";
  const seen = new Set();
  for (const entry of profile.selectors) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return "selector-shape";
    if (hasOwn(entry, "css")) return "css-unsupported";
    if (typeof entry.key !== "string" || !entry.key || seen.has(entry.key)) return "selector-key";
    if (typeof entry.selector !== "string" || !entry.selector) return "selector-value";
    seen.add(entry.key);
  }
  return null;
}

// The fail-closed validation chain, in order:
//   (3) schema/shape  (4) revision monotonicity against the cached baseline
//   (5) ed25519 signature  (6) expiresAt fresh + minClient <= client version
//   (7) every selector key exists in the built-in contract
// Steps 1 (https + exact fixed origin) and 2 (bounded body + lenient
// Content-Type) run in httpsGetProfile below. Any failure returns a reason
// code; the caller drops the whole profile.
export function validateCompatProfile(profile, {
  publicKeys = COMPAT_PROFILE_PUBLIC_KEYS,
  clientVersion,
  cachedRevision = null,
  nowMs = Date.now(),
  localContract,
} = {}) {
  const shapeReason = profileShapeReason(profile);
  if (shapeReason) return { ok: false, reason: shapeReason };
  const cached = Number.isSafeInteger(cachedRevision) && cachedRevision >= 1 ? cachedRevision : null;
  if (cached !== null && profile.revision <= cached) {
    return { ok: false, reason: "revision-not-newer" };
  }
  if (!verifyCompatProfile(profile, publicKeys)) return { ok: false, reason: "signature" };
  if (isoTimestamp(profile.expiresAt) <= nowMs) return { ok: false, reason: "expired" };
  const client = semverParts(clientVersion);
  if (!client) return { ok: false, reason: "client-version" };
  if (!semverAtMost(semverParts(profile.minClient), client)) {
    return { ok: false, reason: "client-too-old" };
  }
  const keys = localContractKeys(localContract);
  if (!keys || keys.size === 0) return { ok: false, reason: "local-contract" };
  for (const entry of profile.selectors) {
    if (!keys.has(entry.key)) return { ok: false, reason: "unknown-key" };
  }
  return { ok: true };
}

// Per-platform cache locations. The cache stores only fully verified profiles
// and is used solely as the revision monotonicity baseline for the next start;
// a failed fetch never falls back to replaying it.
export function compatProfileCachePath(platform = process.platform, env = process.env) {
  // Joined with the target platform's separators so the result is correct even
  // when computed on the other OS (tests, doctor tooling).
  if (platform === "win32") {
    const localAppData = env && typeof env.LOCALAPPDATA === "string" && env.LOCALAPPDATA
      ? env.LOCALAPPDATA : null;
    return localAppData
      ? path.win32.join(localAppData, "CodexDreamSkin", "compat-profile.json") : null;
  }
  if (platform === "darwin") {
    const home = env && typeof env.HOME === "string" && env.HOME ? env.HOME : os.homedir();
    return path.posix.join(
      home, "Library", "Application Support", "CodexDreamSkin", "compat-profile.json",
    );
  }
  return null;
}

function httpsGetProfile(urlString, allowedOrigin, timeoutMs, maxBytes) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    let parsed;
    try {
      parsed = new URL(urlString);
    } catch {
      finish({ error: "bad-url" });
      return;
    }
    // Step 1: an origin that matches the fixed endpoint exactly. The default
    // allowedOrigin is the https GitHub RAW origin, so production traffic is
    // always TLS; the scheme is taken from the pinned origin (tests pin a
    // loopback http origin). `origin` comparison also rejects embedded
    // credentials and unexpected ports for the default constant.
    if ((parsed.protocol !== "https:" && parsed.protocol !== "http:") ||
        parsed.origin !== allowedOrigin) {
      finish({ error: "origin" });
      return;
    }
    let request;
    try {
      // The transport follows the pinned origin's scheme: https for the real
      // endpoint (node:https rejects http: URLs outright), http only for an
      // explicitly http pinned origin such as the test loopback server.
      const transport = parsed.protocol === "https:" ? https : http;
      request = transport.request(parsed, {
        method: "GET",
        timeout: timeoutMs,
        headers: {
          "Accept": "application/json",
          "User-Agent": COMPAT_PROFILE_USER_AGENT,
        },
      }, (response) => {
        // The fixed origin never legitimately redirects; refusing all of them
        // makes cross-origin redirects impossible by construction.
        if (response.statusCode === 301 || response.statusCode === 302 ||
            response.statusCode === 303 || response.statusCode === 307 ||
            response.statusCode === 308) {
          response.resume();
          finish({ error: "redirect" });
          return;
        }
        if (response.statusCode !== 200) {
          response.resume();
          finish({ error: `http-${response.statusCode}` });
          return;
        }
        const contentType = String(response.headers["content-type"] || "").toLowerCase();
        // Step 2 (content type): lenient on purpose. raw.githubusercontent.com
        // serves every blob — including JSON — as `text/plain; charset=utf-8`,
        // so requiring "json" would reject all real responses. The signature
        // check is the actual trust boundary; this only filters obviously
        // non-text payloads.
        if (!contentType.includes("json") && !contentType.startsWith("text/")) {
          response.resume();
          finish({ error: "content-type" });
          return;
        }
        const chunks = [];
        let total = 0;
        response.on("data", (chunk) => {
          total += chunk.length;
          if (total > maxBytes) {
            // Step 2 (bounded body): stop reading as soon as the cap is passed.
            finish({ error: "too-large" });
            response.destroy();
            return;
          }
          chunks.push(chunk);
        });
        response.on("end", () => finish({ bytes: Buffer.concat(chunks) }));
        response.on("error", () => finish({ error: "network" }));
      });
    } catch {
      finish({ error: "bad-url" });
      return;
    }
    request.on("timeout", () => {
      request.destroy(new Error("compat profile request timed out"));
    });
    request.on("error", (error) => {
      const code = error && error.code;
      if (code === "ECONNREFUSED") finish({ error: "connection-refused" });
      else if (code === "ETIMEDOUT" || code === "ECONNRESET" || /timed?\s?out/i.test(String(error?.message))) {
        finish({ error: "timeout" });
      } else if (code === "ENOTFOUND" || code === "EAI_AGAIN") finish({ error: "dns" });
      else finish({ error: typeof code === "string" && code ? code : "network" });
    });
    request.end();
  });
}

async function readCachedRevision(cachePath) {
  if (!cachePath) return null;
  try {
    const cached = JSON.parse(await fs.readFile(cachePath, "utf8"));
    return cached && Number.isSafeInteger(cached.revision) && cached.revision >= 1
      ? cached.revision : null;
  } catch {
    return null;
  }
}

async function writeCachedProfile(cachePath, profile) {
  if (!cachePath) return;
  try {
    await fs.mkdir(path.dirname(cachePath), { recursive: true });
    await fs.writeFile(cachePath, `${JSON.stringify(profile, null, 2)}\n`, "utf8");
  } catch {
    // Best-effort: an unwritable cache location must never fail the fetch.
  }
}

// Orchestrates: read cached revision baseline -> bounded https fetch ->
// fail-closed validation chain -> best-effort cache write -> overrides build.
// Resolves null (never rejects) when the profile must not be applied; optional
// `onStatus(reason)` receives the machine-readable reason code for the single
// diagnostic log line.
export async function fetchCompatProfile(options = {}) {
  const {
    url = COMPAT_PROFILE_URL,
    publicKeys = COMPAT_PROFILE_PUBLIC_KEYS,
    allowedOrigin = COMPAT_PROFILE_ORIGIN,
    cachePath = null,
    clientVersion,
    localContract,
    timeoutMs = COMPAT_PROFILE_TIMEOUT_MS,
    maxBytes = COMPAT_PROFILE_MAX_BYTES,
    now = () => Date.now(),
    onStatus = null,
  } = options;
  const status = typeof onStatus === "function" ? onStatus : () => {};
  const cachedRevision = await readCachedRevision(cachePath);
  const response = await httpsGetProfile(url, allowedOrigin, timeoutMs, maxBytes);
  if (response.error) {
    status(response.error);
    return null;
  }
  let profile;
  try {
    profile = JSON.parse(response.bytes.toString("utf8"));
  } catch {
    status("json");
    return null;
  }
  const verdict = validateCompatProfile(profile, {
    publicKeys,
    clientVersion,
    cachedRevision,
    nowMs: now(),
    localContract,
  });
  if (!verdict.ok) {
    status(verdict.reason);
    return null;
  }
  const overrides = buildOverrides(profile, localContract);
  if (!overrides) {
    status("overrides");
    return null;
  }
  await writeCachedProfile(cachePath, profile);
  return { profile, overrides };
}

// The staged runtime template carries `const COMPAT_PROFILE_OVERRIDES = {};`
// (substituted by tools/sync-runtime-assets.mjs). Once a profile is verified,
// the injector swaps that literal for the overrides mapping; a function
// replacement keeps any `$` constructs inside selector strings literal.
export const COMPAT_TEMPLATE_MARKER = "const COMPAT_PROFILE_OVERRIDES = {};";
export function applyCompatOverridesToTemplate(template, overrides) {
  if (typeof template !== "string" || !overrides || typeof overrides !== "object") return template;
  if (Object.keys(overrides).length === 0) return template;
  if (!template.includes(COMPAT_TEMPLATE_MARKER)) return template;
  return template.replace(
    COMPAT_TEMPLATE_MARKER,
    () => `const COMPAT_PROFILE_OVERRIDES = ${JSON.stringify(overrides)};`,
  );
}

// Signing helper exported for the publishing tool and tests; the injector
// never links a private key.
export function signCompatProfile(profile, privateKey) {
  const message = Buffer.from(canonicalCompatProfileJson(profile), "utf8");
  return `ed25519:${cryptoSign(null, message, privateKey).toString("base64")}`;
}
