// Tests for the maintainer-side compat profile toolchain. Everything runs on
// throwaway keys in os.tmpdir(); .local-evidence/ and real key material are
// never touched. The CLI paths are exercised through subprocesses so argument
// handling and exit codes are covered end to end.

import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { generateCompatKeypair, fingerprintSpkiDer } from "./generate-compat-keypair.mjs";
import {
  buildCompatProfile,
  canonicalJson,
  profileSignaturePayload,
  selectProfileSelectors,
  verifyProfileSignature,
} from "./build-compat-profile.mjs";

const execFileAsync = promisify(execFile);
const TOOLS_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TOOLS_DIR, "..");
const BUILD_SCRIPT = path.join(TOOLS_DIR, "build-compat-profile.mjs");
const FIXED_ISSUED_AT = "2026-10-14T08:00:00Z";

let tmpRoot;
let keypair;
let privateKeyPem;
let publicKeyObject;
let selectorsSource;

before(async () => {
  tmpRoot = await fs.mkdtemp(path.join(os.tmpdir(), "dreamskin-compat-"));
  keypair = generateCompatKeypair({ outDir: path.join(tmpRoot, "keys") });
  privateKeyPem = await fs.readFile(keypair.privateKeyPath, "utf8");
  publicKeyObject = crypto.createPublicKey({
    key: Buffer.from(keypair.publicKeyBase64, "base64"),
    format: "der",
    type: "spki",
  });
  selectorsSource = JSON.parse(
    await fs.readFile(path.join(TOOLS_DIR, "selectors.json"), "utf8"),
  );
});

after(async () => {
  await fs.rm(tmpRoot, { recursive: true, force: true });
});

function runBuild(args) {
  return execFileAsync(process.execPath, [BUILD_SCRIPT, ...args], {
    cwd: REPO_ROOT,
  }).then(
    ({ stdout, stderr }) => ({ code: 0, stdout, stderr }),
    (error) => ({
      code: error.code ?? 1,
      stdout: error.stdout ?? "",
      stderr: error.stderr ?? "",
    }),
  );
}

function buildFixture(overrides = {}) {
  return buildCompatProfile({
    selectorsSource,
    privateKey: privateKeyPem,
    revision: 3,
    issuedAt: FIXED_ISSUED_AT,
    ...overrides,
  });
}

test("generate-compat-keypair writes a PKCS8 private key and a matching SPKI public key", async () => {
  const privateKeyPem = await fs.readFile(keypair.privateKeyPath, "utf8");
  assert.match(privateKeyPem, /^-----BEGIN PRIVATE KEY-----/m);
  assert.doesNotMatch(privateKeyPem, /BEGIN ED25519/);
  const publicKeyText = await fs.readFile(keypair.publicKeyPath, "utf8");
  // Literal includes, not RegExp: the base64 alphabet contains "+" and "/"
  // which are regex metacharacters, so a RegExp built from key material
  // would flake depending on the generated key.
  assert.ok(publicKeyText.includes(keypair.publicKeyBase64));
  assert.ok(publicKeyText.includes(keypair.fingerprint));
  const spkiDer = Buffer.from(keypair.publicKeyBase64, "base64");
  assert.equal(keypair.fingerprint, fingerprintSpkiDer(spkiDer));
  // The printed/published base64 must actually be a usable ed25519 public key,
  // and it must pair with the private key on disk.
  const derived = crypto.createPublicKey(
    crypto.createPrivateKey(await fs.readFile(keypair.privateKeyPath, "utf8")),
  );
  assert.equal(derived.export({ type: "spki", format: "der" }).toString("base64"), keypair.publicKeyBase64);
});

test("the built profile carries the source selectors verbatim and a verifiable signature", () => {
  const { profile } = buildFixture();
  assert.equal(profile.schema, "dreamskin-compat-profile/1");
  assert.equal(profile.revision, 3);
  assert.equal(profile.minClient, "1.7.2");
  assert.equal(profile.issuedAt, "2026-10-14T08:00:00.000Z");
  assert.equal(profile.expiresAt, "2027-04-12T08:00:00.000Z");
  assert.deepEqual(profile.selectors, selectorsSource.selectors);
  assert.equal(Object.keys(profile).length, 7);
  assert.match(profile.signature, /^ed25519:/);
  assert.equal(Buffer.from(profile.signature.slice("ed25519:".length), "base64").length, 64);
  assert.equal(verifyProfileSignature(profile, keypair.publicKeyBase64), true);
  assert.equal(verifyProfileSignature(profile, publicKeyObject), true);
});

test("canonicalJson sorts keys at every depth and emits no whitespace", () => {
  assert.equal(canonicalJson({ b: 1, a: { d: [2, { z: null, c: true }], c: "x" } }),
    '{"a":{"c":"x","d":[2,{"c":true,"z":null}]},"b":1}');
  const reordered = { a: { d: [2, { z: null, c: true }], c: "x" }, b: 1 };
  assert.equal(canonicalJson(reordered), canonicalJson({ b: 1, a: { d: [2, { z: null, c: true }], c: "x" } }));
  assert.throws(() => canonicalJson({ bad: Number.NaN }), /not canonicalizable/);
});

test("a tampered selector string fails signature verification", () => {
  const { profile } = buildFixture();
  const tampered = structuredClone(profile);
  tampered.selectors[0].selector = "main.evil-surface";
  assert.equal(verifyProfileSignature(tampered, publicKeyObject), false);
});

test("a tampered revision fails signature verification", () => {
  const { profile } = buildFixture();
  const tampered = structuredClone(profile);
  tampered.revision = 4;
  assert.equal(verifyProfileSignature(tampered, publicKeyObject), false);
});

test("a tampered expiresAt fails signature verification", () => {
  const { profile } = buildFixture();
  const tampered = structuredClone(profile);
  tampered.expiresAt = "2036-01-01T00:00:00.000Z";
  assert.equal(verifyProfileSignature(tampered, publicKeyObject), false);
});

test("a malformed or absent signature never verifies and never throws", () => {
  const { profile } = buildFixture();
  const noSignature = structuredClone(profile);
  delete noSignature.signature;
  const garbage = structuredClone(profile);
  garbage.signature = "ed25519:not-base64!!!";
  const short = structuredClone(profile);
  short.signature = `ed25519:${Buffer.alloc(32).toString("base64")}`;
  assert.equal(verifyProfileSignature(noSignature, publicKeyObject), false);
  assert.equal(verifyProfileSignature(garbage, publicKeyObject), false);
  assert.equal(verifyProfileSignature(short, publicKeyObject), false);
});

test("a selectors source with duplicate keys is rejected", () => {
  const duplicated = {
    schema: "codex-dream-skin-selectors/1",
    selectors: [
      { key: "shell-main", selector: "main.main-surface", tier: "L1" },
      { key: "shell-main", selector: "main.other", tier: "L1" },
    ],
  };
  assert.throws(() => selectProfileSelectors(duplicated), /duplicate selector key: shell-main/);
});

test("a selectors source with the wrong schema is rejected", () => {
  const wrongSchema = {
    schema: "something-else/2",
    selectors: [{ key: "shell-main", selector: "main.main-surface", tier: "L1" }],
  };
  assert.throws(() => selectProfileSelectors(wrongSchema), /schema must be "codex-dream-skin-selectors\/1"/);
});

test("the CLI rejects duplicate keys in its selectors input end to end", async () => {
  const badSource = path.join(tmpRoot, "duplicate-keys.json");
  await fs.writeFile(
    badSource,
    JSON.stringify({
      schema: "codex-dream-skin-selectors/1",
      selectors: [
        { key: "a", selector: "[data-a]" },
        { key: "a", selector: "[data-a2]" },
      ],
    }),
    "utf8",
  );
  const out = path.join(tmpRoot, "dup", "profile.json");
  const result = await runBuild([
    "--key", keypair.privateKeyPath,
    "--revision", "2",
    "--issued-at", FIXED_ISSUED_AT,
    "--selectors", badSource,
    "--out", out,
  ]);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /duplicate selector key/);
  await assert.rejects(fs.access(out));
});

test("the CLI fails without --key", async () => {
  const out = path.join(tmpRoot, "no-key.json");
  const result = await runBuild(["--revision", "2", "--issued-at", FIXED_ISSUED_AT, "--out", out]);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /--key/);
  await assert.rejects(fs.access(out));
});

test("the CLI fails without --revision", async () => {
  const out = path.join(tmpRoot, "no-revision.json");
  const result = await runBuild(["--key", keypair.privateKeyPath, "--issued-at", FIXED_ISSUED_AT, "--out", out]);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /--revision/);
  await assert.rejects(fs.access(out));
});

test("the CLI writes a verifiable, formatted profile and is deterministic for a fixed issued-at", async () => {
  const out = path.join(tmpRoot, "cli", "profile.json");
  const args = [
    "--key", keypair.privateKeyPath,
    "--revision", "7",
    "--min-client", "1.9.0",
    "--expires-days", "30",
    "--issued-at", FIXED_ISSUED_AT,
    "--out", out,
  ];
  const first = await runBuild(args);
  assert.equal(first.code, 0, first.stderr);
  const raw = await fs.readFile(out, "utf8");
  assert.ok(raw.endsWith("\n"));
  const profile = JSON.parse(raw);
  assert.equal(raw, `${JSON.stringify(profile, null, 2)}\n`);
  assert.equal(profile.revision, 7);
  assert.equal(profile.minClient, "1.9.0");
  assert.equal(profile.selectors.length, selectorsSource.selectors.length);
  assert.deepEqual(profile.selectors, selectorsSource.selectors);
  assert.equal(verifyProfileSignature(profile, keypair.publicKeyBase64), true);
  // The same arguments with a fixed --issued-at must be byte-identical.
  const second = await runBuild(args);
  assert.equal(second.code, 0, second.stderr);
  assert.equal(await fs.readFile(out, "utf8"), raw);
});
