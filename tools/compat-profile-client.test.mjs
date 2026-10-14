// Tests for the shared remote compat-profile client (dreamskin-compat-profile/1).
//
// Everything runs against a 127.0.0.1 node:http mock (the same technique as
// macos/tests/bounded-community-http.test.mjs); the fixed-origin rule is
// exercised through fetchCompatProfile's `allowedOrigin` override so no test
// ever leaves loopback. Key pairs are generated per run — the repository must
// never carry a real signing key.

import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  applyCompatOverridesToTemplate,
  buildOverrides,
  canonicalCompatProfileJson,
  COMPAT_PROFILE_ORIGIN,
  COMPAT_PROFILE_URL,
  compatProfileCachePath,
  fetchCompatProfile,
  signCompatProfile,
  verifyCompatProfile,
} from "./compat-profile-client.mjs";

const LOCAL_CONTRACT = new Set(["shell-main", "left-panel", "composer-chrome"]);

function makeKeyPair() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    base64: publicKey.export({ type: "spki", format: "der" }).toString("base64"),
    privateKey,
  };
}

const signingKey = makeKeyPair();
const rotatingKey = makeKeyPair();
const untrustedKey = makeKeyPair();

function makeProfile(overrides = {}) {
  return {
    schema: "dreamskin-compat-profile/1",
    revision: 3,
    issuedAt: "2026-10-01T00:00:00Z",
    expiresAt: "2099-01-01T00:00:00Z",
    minClient: "1.0.0",
    selectors: [
      {
        key: "shell-main",
        selector: 'main:is(.compat-main, [data-compat-surface])',
        tier: "L1",
        scope: "all",
        required: true,
        notes: "compat override",
      },
      {
        key: "composer-chrome",
        selector: ".compat-composer",
        tier: "L1",
        scope: "all",
        required: true,
        notes: "compat override",
      },
    ],
    ...overrides,
  };
}

function signed(profile, key = signingKey) {
  return { ...profile, signature: signCompatProfile(profile, key.privateKey) };
}

async function withServer(handler, run) {
  const server = http.createServer(handler);
  const sockets = new Set();
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    return await run(origin);
  } finally {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
  }
}

function jsonHandler(body, { contentType = "application/json", status = 200, headers = {} } = {}) {
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  return (request, response) => {
    response.writeHead(status, { "Content-Type": contentType, ...headers });
    response.end(payload);
  };
}

function fetchOptions(origin, extra = {}) {
  return {
    url: `${origin}/compat/profile.json`,
    allowedOrigin: origin,
    publicKeys: [signingKey.base64, rotatingKey.base64],
    clientVersion: "1.7.1",
    localContract: LOCAL_CONTRACT,
    timeoutMs: 2000,
    ...extra,
  };
}

async function temporaryCachePath() {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "dreamskin-compat-"));
  return path.join(directory, "compat-profile.json");
}

test("a valid profile passes the chain, yields overrides and writes the cache", async () => {
  const cachePath = await temporaryCachePath();
  const profile = signed(makeProfile(), rotatingKey);
  await withServer(jsonHandler(profile), async (origin) => {
    const result = await fetchCompatProfile(fetchOptions(origin, { cachePath }));
    assert.ok(result, "a correctly signed profile must be accepted");
    assert.equal(result.profile.revision, 3);
    assert.deepEqual(result.overrides, {
      "shell-main": 'main:is(.compat-main, [data-compat-surface])',
      "composer-chrome": ".compat-composer",
    });
    const cached = JSON.parse(await fs.readFile(cachePath, "utf8"));
    assert.equal(cached.revision, 3);
    assert.equal(cached.signature, profile.signature);
  });
});

test("a profile signed by an unlisted key is dropped", async () => {
  const profile = signed(makeProfile(), untrustedKey);
  await withServer(jsonHandler(profile), async (origin) => {
    const reasons = [];
    const result = await fetchCompatProfile(fetchOptions(origin, { onStatus: (r) => reasons.push(r) }));
    assert.equal(result, null);
    assert.deepEqual(reasons, ["signature"]);
  });
});

test("revision must strictly exceed the cached baseline", async () => {
  const cachePath = await temporaryCachePath();
  await withServer(null, async (origin) => {});
  const serve = async (revision) => {
    let outcome = null;
    await withServer(jsonHandler(signed(makeProfile({ revision }))), async (serverOrigin) => {
      outcome = await fetchCompatProfile(fetchOptions(serverOrigin, {
        cachePath,
        onStatus: () => {},
      }));
    });
    return outcome;
  };
  assert.ok(await serve(5), "first fetch (revision 5) has no baseline and must pass");
  assert.equal(await serve(5), null, "an equal revision must be dropped");
  assert.equal(await serve(4), null, "a lower revision must be dropped");
  const newer = await serve(6);
  assert.ok(newer, "a strictly greater revision must pass");
  assert.equal(newer.profile.revision, 6);
});

test("selectors referencing unknown keys drop the whole profile", async () => {
  const withNewKey = signed(makeProfile({
    selectors: [
      ...makeProfile().selectors,
      { key: "brand-new-key", selector: ".never-shipped", tier: "L2", scope: "all" },
    ],
  }));
  await withServer(jsonHandler(withNewKey), async (origin) => {
    const reasons = [];
    const result = await fetchCompatProfile(fetchOptions(origin, { onStatus: (r) => reasons.push(r) }));
    assert.equal(result, null);
    assert.deepEqual(reasons, ["unknown-key"]);
  });
});

test("a css field (top level or per entry) drops the whole profile", async () => {
  await withServer(jsonHandler(signed(makeProfile({ css: "a { color: red }" }))), async (origin) => {
    const reasons = [];
    const result = await fetchCompatProfile(fetchOptions(origin, { onStatus: (r) => reasons.push(r) }));
    assert.equal(result, null);
    assert.deepEqual(reasons, ["css-unsupported"]);
  });
  const entryCss = signed(makeProfile({
    selectors: [{ ...makeProfile().selectors[0], css: "a{color:red}" }],
  }));
  await withServer(jsonHandler(entryCss), async (origin) => {
    const result = await fetchCompatProfile(fetchOptions(origin));
    assert.equal(result, null);
  });
});

test("a response above 64 KiB is dropped while streaming", async () => {
  const oversized = signed(makeProfile({
    selectors: [{
      ...makeProfile().selectors[0],
      notes: "x".repeat(70 * 1024),
    }],
  }));
  const body = JSON.stringify(oversized);
  assert.ok(Buffer.byteLength(body) > 64 * 1024, "fixture must actually exceed the cap");
  await withServer(jsonHandler(body), async (origin) => {
    const reasons = [];
    const result = await fetchCompatProfile(fetchOptions(origin, { onStatus: (r) => reasons.push(r) }));
    assert.equal(result, null);
    assert.deepEqual(reasons, ["too-large"]);
  });
});

test("connection failures and timeouts resolve to null instead of throwing", async () => {
  // A recently released loopback port: nothing is listening there anymore.
  const releaser = net.createServer();
  await new Promise((resolve) => releaser.listen(0, "127.0.0.1", resolve));
  const deadPort = releaser.address().port;
  await new Promise((resolve) => releaser.close(resolve));

  const reasons = [];
  const refused = await fetchCompatProfile({
    url: `http://127.0.0.1:${deadPort}/compat/profile.json`,
    allowedOrigin: `http://127.0.0.1:${deadPort}`,
    publicKeys: [signingKey.base64],
    clientVersion: "1.7.1",
    localContract: LOCAL_CONTRACT,
    timeoutMs: 1000,
    onStatus: (reason) => reasons.push(reason),
  });
  assert.equal(refused, null, "a refused connection must resolve null");
  assert.equal(reasons.length, 1);
  assert.ok(reasons[0].length > 0, "the failure carries a reason code");

  await withServer((request, response) => {
    // Deliberately never respond; the client must hit its own deadline.
  }, async (origin) => {
    const timedOut = await fetchCompatProfile(fetchOptions(origin, {
      timeoutMs: 250,
      onStatus: (reason) => reasons.push(reason),
    }));
    assert.equal(timedOut, null, "a silent server must resolve null");
    assert.ok(reasons.includes("timeout"), JSON.stringify(reasons));
  });
});

test("expired profiles and high minClient versions are dropped", async () => {
  await withServer(jsonHandler(signed(makeProfile({ expiresAt: "2020-01-01T00:00:00Z" }))),
    async (origin) => {
      const reasons = [];
      const result = await fetchCompatProfile(fetchOptions(origin, { onStatus: (r) => reasons.push(r) }));
      assert.equal(result, null);
      assert.deepEqual(reasons, ["expired"]);
    });
  await withServer(jsonHandler(signed(makeProfile({ minClient: "9.9.9" }))), async (origin) => {
    const reasons = [];
    const result = await fetchCompatProfile(fetchOptions(origin, { onStatus: (r) => reasons.push(r) }));
    assert.equal(result, null);
    assert.deepEqual(reasons, ["client-too-old"]);
  });
});

test("transport rejections: wrong origin, redirects, non-text content types", async () => {
  const reasons = [];
  const wrongOrigin = await fetchCompatProfile({
    url: "http://127.0.0.1:9/compat/profile.json",
    allowedOrigin: COMPAT_PROFILE_ORIGIN,
    publicKeys: [signingKey.base64],
    clientVersion: "1.7.1",
    localContract: LOCAL_CONTRACT,
    onStatus: (reason) => reasons.push(reason),
  });
  assert.equal(wrongOrigin, null);
  assert.deepEqual(reasons, ["origin"]);

  const profile = signed(makeProfile());
  await withServer(jsonHandler(profile, { contentType: "application/octet-stream" }),
    async (origin) => {
      const result = await fetchCompatProfile(fetchOptions(origin, {
        onStatus: (reason) => reasons.push(reason),
      }));
      assert.equal(result, null);
      assert.deepEqual(reasons, ["origin", "content-type"]);
    });
  await withServer((request, response) => {
    response.writeHead(302, { Location: "/compat/elsewhere.json" });
    response.end();
  }, async (origin) => {
    const result = await fetchCompatProfile(fetchOptions(origin, {
      onStatus: (reason) => reasons.push(reason),
    }));
    assert.equal(result, null);
    assert.deepEqual(reasons, ["origin", "content-type", "redirect"]);
  });
  // raw.githubusercontent.com serves JSON blobs as text/plain; that must pass.
  await withServer(jsonHandler(profile, { contentType: "text/plain; charset=utf-8" }),
    async (origin) => {
      const result = await fetchCompatProfile(fetchOptions(origin, {
        onStatus: (reason) => reasons.push(reason),
      }));
      assert.ok(result, "GitHub RAW's text/plain JSON responses must be accepted");
    });
});

test("an unwritable cache path never fails an otherwise valid fetch", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "dreamskin-compat-"));
  const blocker = path.join(directory, "blocker");
  await fs.writeFile(blocker, "not a directory", "utf8");
  const profile = signed(makeProfile());
  await withServer(jsonHandler(profile), async (origin) => {
    const result = await fetchCompatProfile(fetchOptions(origin, {
      cachePath: path.join(blocker, "nested", "compat-profile.json"),
    }));
    assert.ok(result, "cache write failures are best-effort");
    assert.equal(result.profile.revision, 3);
  });
});

test("verifyCompatProfile accepts any trusted key and skips malformed entries", () => {
  const profile = signed(makeProfile(), rotatingKey);
  assert.equal(verifyCompatProfile(profile, [signingKey.base64]), false);
  assert.equal(verifyCompatProfile(profile, [signingKey.base64, rotatingKey.base64]), true);
  assert.equal(verifyCompatProfile(profile, ["not-base64-der", rotatingKey.base64]), true);
  assert.equal(verifyCompatProfile(profile, []), false);
  assert.equal(verifyCompatProfile({ ...profile, signature: "ed25519:short" }, null), false);
  assert.equal(verifyCompatProfile(null, [signingKey.base64]), false);
});

test("buildOverrides pure-function boundaries", () => {
  const valid = makeProfile();
  assert.deepEqual(buildOverrides(valid, LOCAL_CONTRACT), {
    "shell-main": valid.selectors[0].selector,
    "composer-chrome": valid.selectors[1].selector,
  });
  assert.deepEqual(buildOverrides({ ...valid, selectors: [] }, LOCAL_CONTRACT), {});
  assert.equal(buildOverrides({
    ...valid,
    selectors: [{ key: "never-shipped", selector: ".x" }],
  }, LOCAL_CONTRACT), null, "an entirely unknown key set must reject");
  assert.equal(buildOverrides(valid, new Set()), null, "an empty local contract must reject");
  assert.equal(buildOverrides(valid, null), null);
  assert.equal(buildOverrides(null, LOCAL_CONTRACT), null);
  assert.equal(buildOverrides({ ...valid, selectors: null }, LOCAL_CONTRACT), null);
});

test("canonicalCompatProfileJson sorts keys recursively and drops the signature", () => {
  const profile = {
    schema: "dreamskin-compat-profile/1",
    revision: 1,
    zeta: { b: 2, a: [3, { d: 1, c: 2 }] },
    alpha: "text",
    signature: "ed25519:ignored",
  };
  assert.equal(
    canonicalCompatProfileJson(profile),
    '{"alpha":"text","revision":1,"schema":"dreamskin-compat-profile/1","zeta":{"a":[3,{"c":2,"d":1}],"b":2}}',
  );
});

test("applyCompatOverridesToTemplate swaps the staged marker literally", () => {
  const template = "before\n  const COMPAT_PROFILE_OVERRIDES = {};\nafter";
  const patched = applyCompatOverridesToTemplate(template, { "shell-main": "main.$&keep" });
  assert.equal(
    patched,
    'before\n  const COMPAT_PROFILE_OVERRIDES = {"shell-main":"main.$&keep"};\nafter',
    "the $& construct inside a selector must stay literal",
  );
  assert.equal(applyCompatOverridesToTemplate(template, null), template);
  assert.equal(applyCompatOverridesToTemplate(template, {}), template);
  assert.equal(applyCompatOverridesToTemplate("no marker here", { a: "b" }), "no marker here");
});

test("exported endpoint constants and per-platform cache paths", () => {
  assert.equal(COMPAT_PROFILE_URL, `${COMPAT_PROFILE_ORIGIN}/CCDawn/Codex-Dynamic-Skin/main/compat/profile.json`);
  assert.equal(
    compatProfileCachePath("win32", { LOCALAPPDATA: "C:\\Users\\t\\AppData\\Local" }),
    "C:\\Users\\t\\AppData\\Local\\CodexDreamSkin\\compat-profile.json",
  );
  assert.equal(compatProfileCachePath("win32", {}), null);
  assert.equal(
    compatProfileCachePath("darwin", { HOME: "/Users/t" }),
    "/Users/t/Library/Application Support/CodexDreamSkin/compat-profile.json",
  );
  assert.equal(compatProfileCachePath("linux", {}), null);
});
