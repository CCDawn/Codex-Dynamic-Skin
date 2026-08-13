import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  isOpacityOnlyThemeChange,
  setOpacityOnSession,
  setStreamCspBypass,
  transferVideoToSession,
} from "../scripts/injector.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const windowsRoot = path.resolve(here, "..");
const injectorPath = path.resolve(here, "../scripts/injector.mjs");
const managerCommandPath = path.resolve(here, "../scripts/manager-command.ps1");
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "codex-dream-skin-video-"));
const themeDirectory = path.join(temporary, "theme");
const videoPath = path.join(themeDirectory, "loop.mp4");

const runInjector = (directory) => new Promise((resolve, reject) => {
  const child = spawn(process.execPath, [
    injectorPath,
    "--check-payload",
    "--theme-dir", directory,
  ], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  child.once("error", reject);
  child.once("close", (code) => resolve({ code, stdout, stderr }));
});

const runManagerCommand = (argumentsList) => new Promise((resolve, reject) => {
  const child = spawn("powershell.exe", [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    managerCommandPath,
    ...argumentsList,
  ], { stdio: ["ignore", "pipe", "pipe"] });
  const stdout = [];
  const stderr = [];
  child.stdout.on("data", (chunk) => { stdout.push(chunk); });
  child.stderr.on("data", (chunk) => { stderr.push(chunk); });
  child.once("error", reject);
  child.once("close", (code) => resolve({
    code,
    stdout: Buffer.concat(stdout),
    stderr: Buffer.concat(stderr).toString("utf8"),
  }));
});

try {
  await fs.mkdir(themeDirectory, { recursive: true });
  const videoBytes = Buffer.alloc(900_000, 0x2a);
  videoBytes.writeUInt32BE(24, 0);
  videoBytes.write("ftyp", 4, "ascii");
  videoBytes.write("isom", 8, "ascii");
  await fs.writeFile(videoPath, videoBytes);
  await fs.writeFile(path.join(themeDirectory, "theme.json"), JSON.stringify({
    schemaVersion: 1,
    id: "video-fixture",
    name: "Video Fixture",
    image: "loop.mp4",
    appearance: "dark",
    media: { type: "video", playbackRate: 1.25, opacity: 0.4 },
    art: { focusX: 0.5, focusY: 0.5, safeArea: "center", taskMode: "ambient" },
  }));

  const checked = await runInjector(themeDirectory);
  assert.equal(checked.code, 0, checked.stderr);
  const summary = JSON.parse(checked.stdout);
  assert.equal(summary.media.type, "video");
  assert.equal(summary.media.mime, "video/mp4");
  assert.equal(summary.media.size, videoBytes.length);
  assert.equal(summary.media.opacity, 0.4);
  assert.ok(summary.payloadBytes < videoBytes.length,
    "The CDP bootstrap payload must not embed the complete video.");

  const streamThemeDirectory = path.join(temporary, "scene-stream-theme");
  const streamUrl = "http://127.0.0.1:17866/1234567890abcdef1234567890abcdef/stream.mp4";
  await fs.mkdir(streamThemeDirectory);
  await fs.copyFile(
    path.join(windowsRoot, "assets", "dream-reference.jpg"),
    path.join(streamThemeDirectory, "preview.jpg"),
  );
  await fs.writeFile(path.join(streamThemeDirectory, "theme.json"), JSON.stringify({
    schemaVersion: 1,
    id: "scene-stream-fixture",
    name: "Scene Stream Fixture",
    image: "preview.jpg",
    media: {
      type: "scene",
      streamUrl,
      codec: "avc1.42c01f",
      opacity: 0.7,
    },
  }));
  const streamChecked = await runInjector(streamThemeDirectory);
  assert.equal(streamChecked.code, 0, streamChecked.stderr);
  const streamSummary = JSON.parse(streamChecked.stdout);
  assert.equal(streamSummary.media.type, "video");
  assert.equal(streamSummary.media.streamUrl, streamUrl);
  assert.equal(streamSummary.media.codec, "avc1.42c01f");
  assert.equal(streamSummary.media.mime, "video/mp4");

  const remoteStreamDirectory = path.join(temporary, "remote-scene-stream-theme");
  await fs.mkdir(remoteStreamDirectory);
  await fs.copyFile(
    path.join(windowsRoot, "assets", "dream-reference.jpg"),
    path.join(remoteStreamDirectory, "preview.jpg"),
  );
  await fs.writeFile(path.join(remoteStreamDirectory, "theme.json"), JSON.stringify({
    schemaVersion: 1,
    id: "remote-scene-stream-fixture",
    image: "preview.jpg",
    media: {
      type: "scene",
      streamUrl: "http://192.168.1.5:17866/1234567890abcdef1234567890abcdef/stream.mp4",
      codec: "avc1.42c01f",
    },
  }));
  const rejectedRemoteStream = await runInjector(remoteStreamDirectory);
  assert.notEqual(rejectedRemoteStream.code, 0);
  assert.match(rejectedRemoteStream.stderr, /loopback/i);

  const steamLibrary = path.join(temporary, "Steam Library");
  const workshopRoot = path.join(
    steamLibrary,
    "steamapps",
    "workshop",
    "content",
    "431960",
  );
  const workshopId = "1234567890";
  const workshopDirectory = path.join(workshopRoot, workshopId);
  const referencedThemeDirectory = path.join(temporary, "referenced-theme");
  await fs.mkdir(workshopDirectory, { recursive: true });
  await fs.mkdir(referencedThemeDirectory);
  await fs.copyFile(videoPath, path.join(workshopDirectory, "wallpaper.mp4"));
  await fs.writeFile(path.join(workshopDirectory, "project.json"), JSON.stringify({
    type: "video",
    file: "wallpaper.mp4",
    title: "本地动态壁纸",
  }));
  const sceneWorkshopId = "1234567891";
  const sceneWorkshopDirectory = path.join(workshopRoot, sceneWorkshopId);
  await fs.mkdir(sceneWorkshopDirectory);
  await fs.writeFile(path.join(sceneWorkshopDirectory, "project.json"), JSON.stringify({
    type: "scene",
    file: "scene.json",
    title: "本地场景壁纸",
  }));
  await fs.writeFile(path.join(sceneWorkshopDirectory, "scene.pkg"), Buffer.alloc(1024, 0x5a));
  await fs.copyFile(
    path.join(windowsRoot, "assets", "dream-reference.jpg"),
    path.join(sceneWorkshopDirectory, "preview.jpg"),
  );
  await fs.writeFile(path.join(referencedThemeDirectory, "theme.json"), JSON.stringify({
    schemaVersion: 1,
    id: "wallpaper-engine-fixture",
    name: "Wallpaper Engine Fixture",
    image: "wallpaper.mp4",
    media: {
      type: "video",
      source: "wallpaper-engine-local",
      workshopId,
      workshopRoot,
      relativePath: "wallpaper.mp4",
    },
  }));
  const referenced = await runInjector(referencedThemeDirectory);
  assert.equal(referenced.code, 0, referenced.stderr);
  const referencedSummary = JSON.parse(referenced.stdout);
  assert.equal(referencedSummary.media.type, "video");
  assert.equal(referencedSummary.media.size, videoBytes.length);

  if (process.platform === "win32") {
    const managerListing = await runManagerCommand([
      "-Action", "ListWallpaperEngine",
      "-SteamLibraryPath", steamLibrary,
    ]);
    assert.equal(managerListing.code, 0, managerListing.stderr);
    const managerPayload = JSON.parse(managerListing.stdout.toString("utf8"));
    assert.equal(managerPayload.items.find((item) => item.workshopId === workshopId)?.name, "本地动态壁纸",
      "Manager command JSON must stay UTF-8 when the Wallpaper Engine title contains Chinese.");
    const listedScene = managerPayload.items.find((item) => item.workshopId === sceneWorkshopId);
    assert.equal(listedScene?.name, "本地场景壁纸");
    assert.equal(listedScene?.mediaType, "scene");
    assert.equal(listedScene?.relativePath, "scene.pkg");

    const sceneStateRoot = path.join(temporary, "scene-state");
    const sceneApplied = await runManagerCommand([
      "-Action", "UseSceneStream",
      "-Path", path.join(sceneWorkshopDirectory, "scene.pkg"),
      "-StreamUrl", streamUrl,
      "-StateRoot", sceneStateRoot,
    ]);
    assert.equal(sceneApplied.code, 0, sceneApplied.stderr);
    const sceneAppliedPayload = JSON.parse(sceneApplied.stdout.toString("utf8"));
    assert.equal(sceneAppliedPayload.mediaType, "scene");
    const checkedAppliedScene = await runInjector(path.join(sceneStateRoot, "active-theme"));
    assert.equal(checkedAppliedScene.code, 0, checkedAppliedScene.stderr);
    assert.equal(JSON.parse(checkedAppliedScene.stdout).media.streamUrl, streamUrl);
  }

  const escapedReferenceDirectory = path.join(temporary, "escaped-reference");
  await fs.mkdir(escapedReferenceDirectory);
  await fs.writeFile(path.join(escapedReferenceDirectory, "theme.json"), JSON.stringify({
    schemaVersion: 1,
    id: "escaped-wallpaper-engine-fixture",
    image: "../wallpaper.mp4",
    media: {
      type: "video",
      source: "wallpaper-engine-local",
      workshopId,
      workshopRoot,
      relativePath: "../wallpaper.mp4",
    },
  }));
  const escapedReference = await runInjector(escapedReferenceDirectory);
  assert.notEqual(escapedReference.code, 0);
  assert.match(escapedReference.stderr, /remain inside|relative path/i);

  const macPaletteDirectory = path.join(temporary, "mac-palette");
  await fs.mkdir(macPaletteDirectory);
  await fs.copyFile(videoPath, path.join(macPaletteDirectory, "loop.mp4"));
  await fs.writeFile(path.join(macPaletteDirectory, "theme.json"), JSON.stringify({
    schemaVersion: 1,
    id: "mac-palette-fixture",
    image: "loop.mp4",
    colors: { accent: "#c93d4c" },
    media: { type: "video" },
  }));
  const macPaletteChecked = await runInjector(macPaletteDirectory);
  assert.equal(macPaletteChecked.code, 0, macPaletteChecked.stderr);
  const macPaletteSummary = JSON.parse(macPaletteChecked.stdout);
  assert.deepEqual(macPaletteSummary.palette, { accent: "#c93d4c" },
    "Windows must map the macOS colors.accent field to its palette contract.");

  const expressions = [];
  const session = {
    async evaluate(expression) {
      expressions.push(expression);
      return true;
    },
  };
  const transferred = await transferVideoToSession(session, {
    mediaPath: videoPath,
    mediaMime: "video/mp4",
    mediaSize: videoBytes.length,
  });
  assert.equal(transferred.bytes, videoBytes.length);
  assert.ok(transferred.chunks >= 2, "The fixture should exercise chunked CDP transfer.");
  assert.match(expressions[0], /\.beginMedia\(/);
  assert.match(expressions.at(-1), /\.commitMedia\(\)/);
  assert.ok(expressions.slice(1, -1).every((expression) => expression.includes(".appendMedia(")));
  assert.ok(expressions.every((expression) => Buffer.byteLength(expression) < 1024 * 1024));

  const opacityExpressions = [];
  const opacitySession = {
    async evaluate(expression) {
      opacityExpressions.push(expression);
      return true;
    },
  };
  assert.equal(await setOpacityOnSession(opacitySession, 0.65), 0.65);
  assert.match(opacityExpressions[0], /setWallpaperReveal/);

  const cspCommands = [];
  const cspSession = {
    async send(method, params) {
      cspCommands.push({ method, params });
      return {};
    },
  };
  assert.equal(await setStreamCspBypass(cspSession, true), true);
  assert.equal(await setStreamCspBypass(cspSession, true), true);
  assert.equal(await setStreamCspBypass(cspSession, false), false);
  assert.deepEqual(cspCommands, [
    { method: "Page.setBypassCSP", params: { enabled: true } },
    { method: "Page.setBypassCSP", params: { enabled: false } },
  ], "Scene streaming must scope CSP bypass to the active loopback stream.");

  const previousTheme = {
    mediaPath: videoPath,
    mediaType: "video",
    mediaMime: "video/mp4",
    mediaSize: videoBytes.length,
    theme: { id: "same", media: { type: "video", playbackRate: 1, opacity: 0.4 } },
  };
  const opacityTheme = structuredClone(previousTheme);
  opacityTheme.theme.media.opacity = 0.65;
  assert.equal(isOpacityOnlyThemeChange(previousTheme, opacityTheme), true);
  opacityTheme.theme.media.playbackRate = 1.25;
  assert.equal(isOpacityOnlyThemeChange(previousTheme, opacityTheme), false);

  const invalidDirectory = path.join(temporary, "invalid");
  await fs.mkdir(invalidDirectory);
  await fs.writeFile(path.join(invalidDirectory, "fake.mp4"), Buffer.from("not an mp4"));
  await fs.writeFile(path.join(invalidDirectory, "theme.json"), JSON.stringify({
    schemaVersion: 1,
    id: "invalid-video",
    image: "fake.mp4",
    media: { type: "video" },
  }));
  const rejected = await runInjector(invalidDirectory);
  assert.notEqual(rejected.code, 0);
  assert.match(rejected.stderr, /signature|container/i);

  const invalidOpacityDirectory = path.join(temporary, "invalid-opacity");
  await fs.mkdir(invalidOpacityDirectory);
  await fs.copyFile(videoPath, path.join(invalidOpacityDirectory, "loop.mp4"));
  await fs.writeFile(path.join(invalidOpacityDirectory, "theme.json"), JSON.stringify({
    schemaVersion: 1,
    id: "invalid-opacity",
    image: "loop.mp4",
    media: { type: "video", opacity: 1.1 },
  }));
  const rejectedOpacity = await runInjector(invalidOpacityDirectory);
  assert.notEqual(rejectedOpacity.code, 0);
  assert.match(rejectedOpacity.stderr, /opacity/i);

  const unsupportedSchemaDirectory = path.join(temporary, "unsupported-schema");
  await fs.mkdir(unsupportedSchemaDirectory);
  await fs.copyFile(videoPath, path.join(unsupportedSchemaDirectory, "loop.mp4"));
  await fs.writeFile(path.join(unsupportedSchemaDirectory, "theme.json"), JSON.stringify({
    schemaVersion: 2,
    id: "unsupported-schema",
    image: "loop.mp4",
    media: { type: "video" },
  }));
  const rejectedSchema = await runInjector(unsupportedSchemaDirectory);
  assert.notEqual(rejectedSchema.code, 0);
  assert.match(rejectedSchema.stderr, /schema/i);
} finally {
  await fs.rm(temporary, { recursive: true, force: true });
}

console.log("PASS: video themes stay out of bootstrap payloads and transfer in bounded CDP chunks.");
