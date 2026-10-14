#!/usr/bin/env node
// Maintainer-side key generation for the remote compat profile
// (schema dreamskin-compat-profile/1, see docs/compat-profile-design.md).
//
// Generates the ed25519 keypair used to sign selector profiles:
//   compat-profile-private.pem  — PKCS8 PEM, NEVER committed, never printed
//   compat-profile-public.txt   — SPKI DER base64 + sha256 fingerprint
//
// Default output lives under .local-evidence/ (gitignored). If that folder
// does not exist yet, an explicit --out <dir> is required so key material is
// never written somewhere by accident.

import { generateKeyPairSync, createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DEFAULT_OUT_DIR = path.join(REPO_ROOT, ".local-evidence", "keys");
const PRIVATE_KEY_NAME = "compat-profile-private.pem";
const PUBLIC_KEY_NAME = "compat-profile-public.txt";

export function fingerprintSpkiDer(der) {
  return createHash("sha256").update(der).digest("hex");
}

// Best-effort tightening of the private key file. On POSIX chmod 0o600 is
// enough. On Windows chmod only toggles the read-only bit, so we also strip
// inheritance and re-grant access to the current user alone via icacls.
// Failures are warnings, never fatal: the key is already on disk by then.
function tightenPrivateKeyPermissions(filePath) {
  try {
    fs.chmodSync(filePath, 0o600);
  } catch {
    // Best effort on platforms without chmod semantics.
  }
  if (process.platform !== "win32") return;
  const account = `${process.env.USERDOMAIN || process.env.COMPUTERNAME || ""}\\${process.env.USERNAME || ""}`.replace(/^\\/, "");
  if (!account || account === "\\") return;
  try {
    execFileSync(
      "icacls",
      [filePath, "/inheritance:r", "/grant:r", `${account}:F`],
      { windowsHide: true, stdio: "ignore" },
    );
  } catch {
    console.warn(`warning: could not tighten the ACL on ${filePath}; keep the directory access-restricted manually.`);
  }
}

export function generateCompatKeypair({ outDir }) {
  if (!outDir || typeof outDir !== "string") {
    throw new Error("outDir is required");
  }
  const privateKeyPath = path.join(outDir, PRIVATE_KEY_NAME);
  const publicKeyPath = path.join(outDir, PUBLIC_KEY_NAME);
  if (fs.existsSync(privateKeyPath) || fs.existsSync(publicKeyPath)) {
    throw new Error(
      `refusing to overwrite existing key material in ${outDir}; move it away or choose another --out`,
    );
  }
  const { publicKey, privateKey } = generateKeyPairSync("ed25519", {
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "der" },
  });
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(privateKeyPath, privateKey, { mode: 0o600 });
  const publicKeyBase64 = Buffer.from(publicKey).toString("base64");
  const fingerprint = fingerprintSpkiDer(publicKey);
  fs.writeFileSync(
    publicKeyPath,
    [
      "# Codex Dream Skin compat profile verification key",
      `compat-profile-public-key: ${publicKeyBase64}`,
      `compat-profile-public-key-sha256: ${fingerprint}`,
      "",
    ].join("\n"),
    { mode: 0o644 },
  );
  tightenPrivateKeyPermissions(privateKeyPath);
  return { privateKeyPath, publicKeyPath, publicKeyBase64, fingerprint };
}

function usage(out) {
  out.write(`usage: node tools/generate-compat-keypair.mjs [--out <dir>]

Generates the ed25519 keypair that signs dreamskin-compat-profile/1 profiles.

  --out <dir>   output directory (default: .local-evidence/keys/ under the
                repo root; if .local-evidence/ does not exist, --out is
                required so keys are never written by accident)

Writes:
  ${PRIVATE_KEY_NAME}   PKCS8 PEM private key (never commit, never print)
  ${PUBLIC_KEY_NAME}    SPKI DER base64 public key + sha256 fingerprint
`);
}

function main(argv) {
  let outDir = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      usage(process.stdout);
      return 0;
    }
    const value = arg.startsWith("--out=") ? arg.slice("--out=".length) : null;
    if (arg === "--out" && i + 1 < argv.length) {
      outDir = argv[(i += 1)];
    } else if (value !== null) {
      outDir = value;
    } else {
      console.error(`unknown argument: ${arg}`);
      usage(process.stderr);
      return 1;
    }
  }
  if (!outDir) {
    if (!fs.existsSync(path.join(REPO_ROOT, ".local-evidence"))) {
      console.error(
        `refusing to default to ${DEFAULT_OUT_DIR}: .local-evidence/ does not exist.\n` +
          "Pass --out <dir> explicitly so key material is never created by accident.",
      );
      return 1;
    }
    outDir = DEFAULT_OUT_DIR;
  }
  try {
    const { privateKeyPath, publicKeyPath, publicKeyBase64, fingerprint } =
      generateCompatKeypair({ outDir: path.resolve(outDir) });
    console.log("compat profile keypair written:");
    console.log(`  private key: ${privateKeyPath} (PKCS8 PEM; keep local, never commit)`);
    console.log(`  public key:  ${publicKeyPath}`);
    console.log("public key (SPKI DER, base64):");
    console.log(`  ${publicKeyBase64}`);
    console.log("sha256 fingerprint (hex):");
    console.log(`  ${fingerprint}`);
    return 0;
  } catch (error) {
    console.error(`error: ${error.message}`);
    return 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(main(process.argv.slice(2)));
}
