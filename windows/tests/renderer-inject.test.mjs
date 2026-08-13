import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const windowsRoot = path.resolve(here, "..");
const template = await fs.readFile(path.join(windowsRoot, "assets", "renderer-inject.js"), "utf8");
const css = await fs.readFile(path.join(windowsRoot, "assets", "dream-skin.css"), "utf8");
const buildPayload = (config = {}, artDataUrl = "data:image/png;base64,AA==") => template
  .replace("__DREAM_CSS_JSON__", JSON.stringify(".fixture { color: blue; }"))
  .replace("__DREAM_ART_JSON__", JSON.stringify(artDataUrl))
  .replace("__DREAM_THEME_JSON__", JSON.stringify(config));
const payload = buildPayload();

assert.doesNotMatch(
  css,
  /main\.main-surface\s*>\s*header\.app-header-tint\s*\{[^}]*\b(?:position|z-index)\s*:/,
  "The skin must preserve Codex's native fixed header so the side-panel toggle remains reachable.",
);
assert.doesNotMatch(
  css,
  /\.dream-task\s*>\s*\*\s*\{[^}]*\bposition\s*:/,
  "Task styling must not turn the native fixed header into a positioned route child.",
);
assert.match(
  css,
  /main\.main-surface\.dream-task\s*>\s*header\.app-header-tint\s*\{[^}]*background:\s*transparent !important;/,
  "Fallback task routes must not paint a separate header band.",
);
assert.match(
  css,
  /main\.main-surface\.dream-task\s+\.app-shell-main-content-top-fade\s*\{[^}]*display:\s*none !important;/,
  "Fallback task routes must remove the native top fade seam.",
);
assert.match(
  css,
  /html\.codex-dream-skin \[class~="group\/application-menu-top-bar"\]\s*\{[^}]*background:\s*color-mix\([^}]*backdrop-filter:\s*blur\(/,
  "The native application menu must have a legibility layer in both light and dark themes.",
);
assert.match(
  css,
  /html\.codex-dream-skin \[class~="group\/application-menu-top-bar"\] button,[\s\S]*?\[class~="group\/application-menu-top-bar"\] svg\s*\{[^}]*color:\s*var\(--dream-text\) !important;/,
  "Application menu controls must use the opaque adaptive theme text color.",
);
assert.match(
  css,
  /\.dream-art-video main\.main-surface\s*>\s*header\.app-header-tint\s*\{[^}]*background:\s*var\(--dream-immersive-composer\) !important;[^}]*backdrop-filter:\s*none !important;/,
  "Dynamic wallpaper mode must keep the secondary Codex toolbar responsive to the shared veil without live blur.",
);
assert.match(
  css,
  /\.dream-art-video \[class~="group\/application-menu-top-bar"\]\s*\{[^}]*background:\s*var\(--dream-immersive-composer\) !important;[^}]*backdrop-filter:\s*none !important;/,
  "Dynamic wallpaper mode must avoid live blur on the native application menu.",
);
assert.match(
  css,
  /#codex-dream-skin-media\s*\{[^}]*opacity:\s*1\b/,
  "Dynamic wallpaper must stay at its original opacity.",
);
assert.match(
  css,
  /linear-gradient\(var\(--dream-media-overlay\),\s*var\(--dream-media-overlay\)\),\s*var\(--dream-art\)/,
  "Static wallpaper surfaces must blend with the canvas through the shared reveal control.",
);
assert.match(
  css,
  /--dream-immersive-edge:\s*color-mix\([^;]*var\(--dream-wallpaper-cover\)[^;]*transparent\)/,
  "The full-window foreground veil must disappear as wallpaper reveal reaches 100%.",
);
assert.match(
  css,
  /--dream-immersive-composer:\s*color-mix\([^;]*var\(--dream-wallpaper-cover\)[^;]*transparent\)/,
  "Composer and toolbar surfaces must be fully transparent at 100% wallpaper reveal.",
);
assert.match(
  css,
  /main\.main-surface\.dream-home-shell,[\s\S]*?background-position:\s*0 var\(--height-token-toolbar, 46px\) !important;/,
  "Home and task route veils must start below the fixed secondary toolbar to avoid a double tint.",
);

function createFixture({
  shellPresent,
  routeMainPresent = true,
  sidebarPresent = true,
  staleSkin = false,
  homePresent = false,
  utilityPresent = false,
  shellAppearance = "dark",
  computedColorScheme = "",
  osAppearance = "light",
  analysisFixture = null,
  streamFixture = null,
}) {
  const nodes = new Map();
  const rootClasses = new Set(staleSkin ? ["codex-dream-skin"] : []);
  const rootStyles = new Map(staleSkin ? [["--dream-art", "url(\"blob:stale\")"]] : []);
  const revokedUrls = [];
  const observers = [];
  const documentListeners = new Map();
  let objectUrlCount = 0;
  let styleWriteCount = 0;
  let intervalDelay = null;
  let mediaPlayCount = 0;
  let mediaPauseCount = 0;
  let streamAppendCount = 0;
  let streamFetchUrl = null;
  let streamAborted = false;
  let streamEnded = false;
  let hasShell = shellPresent;
  let documentHidden = false;
  let root;

  const queueRootClassMutation = () => {
    for (const observer of observers) {
      if (observer.target !== root || !observer.options?.attributes) continue;
      if (observer.options.attributeFilter && !observer.options.attributeFilter.includes("class")) continue;
      observer.records.push({ type: "attributes", attributeName: "class", target: root });
    }
  };
  const makeClassList = (classes = new Set(), onMutation = () => {}) => ({
    add(...values) {
      for (const value of values) classes.add(value);
      if (values.length > 0) onMutation();
    },
    remove(...values) {
      for (const value of values) classes.delete(value);
      if (values.length > 0) onMutation();
    },
    toggle(value, enabled) {
      if (enabled) classes.add(value);
      else classes.delete(value);
      onMutation();
    },
    contains(value) { return classes.has(value); },
  });

  root = {
    className: shellAppearance,
    classList: makeClassList(rootClasses, queueRootClassMutation),
    getAttribute() { return null; },
    style: {
      getPropertyValue(key) { return rootStyles.get(key) ?? ""; },
      setProperty(key, value) { styleWriteCount += 1; rootStyles.set(key, value); },
      removeProperty(key) { rootStyles.delete(key); },
    },
    appendChild(node) {
      node.parentElement = root;
      nodes.set(node.id, node);
    },
  };
  const body = {
    className: "",
    getAttribute() { return null; },
    appendChild(node) {
      node.parentElement = body;
      nodes.set(node.id, node);
    },
  };
  const shellMainClasses = new Set();
  const shellMain = {
    classList: makeClassList(shellMainClasses),
    getBoundingClientRect() {
      return { left: 290, top: 36, width: 990, height: 784 };
    },
  };
  const routeClasses = new Set();
  const utilityClasses = new Set();
  const utilityNode = { classList: makeClassList(utilityClasses) };
  const homeIcon = {
    closest(selector) {
      return selector === '[role="main"]' && hasShell && homePresent ? routeMain : null;
    },
  };
  const routeMain = {
    classList: makeClassList(routeClasses),
    querySelectorAll(selector) {
      if (selector === '[class*="_homeUtilityBar_"]' && utilityPresent) return [utilityNode];
      return [];
    },
  };
  const staleHome = { classList: makeClassList(new Set(["dream-home"])) };
  const staleShell = { classList: makeClassList(new Set(["dream-home-shell"])) };

  const createElement = (tagName) => {
    if (tagName === "canvas" && analysisFixture) {
      return {
        width: 0,
        height: 0,
        getContext() {
          return {
            drawImage() {},
            getImageData() { return { data: analysisFixture.pixels }; },
          };
        },
      };
    }
    return {
      id: "",
      dataset: {},
      style: {},
      classList: makeClassList(),
      parentElement: null,
      src: "",
      paused: true,
      textContent: "",
      innerHTML: "",
      setAttribute() {},
      removeAttribute(name) { if (name === "src") this.src = ""; },
      load() {},
      pause() { mediaPauseCount += 1; this.paused = true; },
      play() { mediaPlayCount += 1; this.paused = false; return Promise.resolve(); },
      remove() { nodes.delete(this.id); },
    };
  };
  if (staleSkin) {
    const style = createElement();
    style.id = "codex-dream-skin-style";
    nodes.set(style.id, style);
    const chrome = createElement();
    chrome.id = "codex-dream-skin-chrome";
    nodes.set(chrome.id, chrome);
  }

  const document = {
    documentElement: root,
    head: root,
    body,
    get hidden() { return documentHidden; },
    addEventListener(type, listener) { documentListeners.set(type, listener); },
    removeEventListener(type, listener) {
      if (documentListeners.get(type) === listener) documentListeners.delete(type);
    },
    createElement,
    getElementById(id) { return nodes.get(id) ?? null; },
    querySelector(selector) {
      if (selector === "main.main-surface") return hasShell ? shellMain : null;
      if (selector === "aside.app-shell-left-panel") return hasShell && sidebarPresent ? {} : null;
      if (selector === '[data-testid="home-icon"]') return hasShell && homePresent ? homeIcon : null;
      return null;
    },
    querySelectorAll(selector) {
      if (selector === '[role="main"]') return hasShell && routeMainPresent ? [routeMain] : [];
      if (selector === ".dream-task") {
        const candidates = [];
        if (routeClasses.has("dream-task")) candidates.push(routeMain);
        if (shellMainClasses.has("dream-task")) candidates.push(shellMain);
        return candidates;
      }
      if (selector === ".dream-home-utility") {
        return utilityClasses.has("dream-home-utility") ? [utilityNode] : [];
      }
      if (!staleSkin) return [];
      if (selector === ".dream-home") return [staleHome];
      if (selector === ".dream-home-shell") return [staleShell];
      return [];
    },
  };
  class FixtureUrl extends globalThis.URL {
    static createObjectURL() { objectUrlCount += 1; return `blob:fixture-${objectUrlCount}`; }
    static revokeObjectURL(value) { revokedUrls.push(value); }
  }
  class FixtureSourceBuffer {
    updating = false;
    buffered = { length: 0, start() { return 0; }, end() { return 0; } };
    listeners = new Map();
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    removeEventListener(type, listener) {
      if (this.listeners.get(type) === listener) this.listeners.delete(type);
    }
    appendBuffer() {
      this.updating = true;
      streamAppendCount += 1;
      queueMicrotask(() => {
        this.updating = false;
        this.listeners.get("updateend")?.();
      });
    }
    remove() {
      this.updating = true;
      queueMicrotask(() => {
        this.updating = false;
        this.listeners.get("updateend")?.();
      });
    }
  }
  class FixtureMediaSource {
    static isTypeSupported(mime) {
      return mime === 'video/mp4; codecs="avc1.42c01f"';
    }
    readyState = "closed";
    listeners = new Map();
    addEventListener(type, listener) {
      this.listeners.set(type, listener);
      if (type === "sourceopen") {
        queueMicrotask(() => {
          this.readyState = "open";
          listener();
        });
      }
    }
    addSourceBuffer() { return new FixtureSourceBuffer(); }
    endOfStream() { streamEnded = true; this.readyState = "ended"; }
  }
  class FixtureAbortController extends globalThis.AbortController {
    abort() { streamAborted = true; super.abort(); }
  }
  const context = {
    window: {
      matchMedia() { return { matches: osAppearance === "dark" }; },
    },
    document,
    MutationObserver: class {
      constructor(callback) {
        this.callback = callback;
        this.records = [];
        this.target = null;
        this.options = null;
        observers.push(this);
      }
      observe(target, options = {}) {
        this.target = target;
        this.options = options;
      }
      disconnect() {
        this.target = null;
        this.records = [];
      }
      takeRecords() {
        const records = this.records;
        this.records = [];
        return records;
      }
    },
    URL: FixtureUrl,
    Blob,
    Uint8Array,
    atob,
    setInterval: (_, delay) => { intervalDelay = delay; return 1; },
    clearInterval: () => {},
    setTimeout: () => 2,
    clearTimeout: () => {},
    getComputedStyle() { return { colorScheme: computedColorScheme }; },
  };
  if (streamFixture) {
    const chunks = streamFixture.chunks.map((chunk) => new Uint8Array(chunk));
    context.MediaSource = FixtureMediaSource;
    context.AbortController = FixtureAbortController;
    context.fetch = async (url) => {
      streamFetchUrl = url;
      if (streamFixture.error) throw new Error(streamFixture.error);
      let index = 0;
      return {
        ok: true,
        status: 200,
        body: {
          getReader() {
            return {
              async read() {
                if (index >= chunks.length) return { done: true, value: undefined };
                return { done: false, value: chunks[index++] };
              },
              async cancel() {},
            };
          },
        },
      };
    };
  }
  if (analysisFixture) {
    context.Image = class {
      naturalWidth = analysisFixture.naturalWidth;
      naturalHeight = analysisFixture.naturalHeight;
      set src(_) { this.onload(); }
    };
  }

  return {
    context,
    nodes,
    observers,
    rootClasses,
    rootStyles,
    get styleWriteCount() { return styleWriteCount; },
    get intervalDelay() { return intervalDelay; },
    get mediaPlayCount() { return mediaPlayCount; },
    get mediaPauseCount() { return mediaPauseCount; },
    get streamAppendCount() { return streamAppendCount; },
    get streamFetchUrl() { return streamFetchUrl; },
    get streamAborted() { return streamAborted; },
    get streamEnded() { return streamEnded; },
    revokedUrls,
    routeClasses,
    shellMainClasses,
    utilityClasses,
    setShellPresent(value) { hasShell = value; },
    setDocumentHidden(value) {
      documentHidden = value;
      documentListeners.get("visibilitychange")?.();
    },
  };
}

const main = createFixture({ shellPresent: true });
const mainResult = vm.runInNewContext(payload, main.context);
assert.equal(mainResult.installed, true);
assert.equal(main.rootClasses.has("codex-dream-skin"), true);
assert.equal(main.rootStyles.get("--dream-art"), 'url("blob:fixture-1")');
assert.equal(main.nodes.has("codex-dream-skin-style"), true);
assert.equal(main.nodes.has("codex-dream-skin-chrome"), true);
assert.equal(main.rootClasses.has("dream-theme-dark"), true);
assert.equal(main.rootClasses.has("dream-art-standard"), true);
assert.equal(main.rootClasses.has("dream-task-ambient"), true);
assert.equal(main.routeClasses.has("dream-task"), true);
assert.equal(main.intervalDelay, 15000,
  "The periodic recovery pass must stay infrequent enough to avoid regular UI scans.");
assert.equal(main.observers.length, 2);
assert.equal(main.observers[0].options.attributes, undefined,
  "The subtree observer must not subscribe to high-frequency class mutations.");
assert.equal(main.observers[0].options.childList, true);
assert.equal(main.observers[1].target, main.context.document.documentElement);
assert.equal(main.observers[1].options.attributes, true,
  "Appearance changes should be observed only on the document root.");
const initialStyleWriteCount = main.styleWriteCount;
main.context.window.__CODEX_DREAM_SKIN_STATE__.ensure();
assert.equal(main.styleWriteCount, initialStyleWriteCount,
  "An unchanged ensure pass must not invalidate root styles.");
assert.equal(main.context.window.__CODEX_DREAM_SKIN_STATE__.cleanup(), true);
assert.equal(main.rootClasses.has("codex-dream-skin"), false);
assert.equal(main.rootClasses.has("dream-theme-dark"), false);
assert.equal(main.nodes.has("codex-dream-skin-style"), false);
assert.equal(main.nodes.has("codex-dream-skin-chrome"), false);
assert.deepEqual(main.revokedUrls, ["blob:fixture-1"]);

const currentShell = createFixture({
  shellPresent: true,
  routeMainPresent: false,
  sidebarPresent: false,
});
const currentShellResult = vm.runInNewContext(payload, currentShell.context);
assert.equal(currentShellResult.installed, true);
assert.equal(currentShell.rootClasses.has("codex-dream-skin"), true);
assert.equal(currentShell.shellMainClasses.has("dream-task"), true);
assert.equal(currentShell.context.window.__CODEX_DREAM_SKIN_STATE__.cleanup(), true);
assert.equal(currentShell.shellMainClasses.has("dream-task"), false);

const reinjected = createFixture({ shellPresent: true });
vm.runInNewContext(payload, reinjected.context);
const firstState = reinjected.context.window.__CODEX_DREAM_SKIN_STATE__;
vm.runInNewContext(payload, reinjected.context);
const secondState = reinjected.context.window.__CODEX_DREAM_SKIN_STATE__;
assert.notEqual(secondState.installToken, firstState.installToken);
assert.equal(secondState.artUrl, "blob:fixture-2");
assert.equal(reinjected.rootStyles.get("--dream-art"), 'url("blob:fixture-2")');
assert.deepEqual(reinjected.revokedUrls, ["blob:fixture-1"]);
assert.equal(firstState.cleanup(), false);
assert.equal(secondState.cleanup(), true);

const auxiliary = createFixture({ shellPresent: false, staleSkin: true });
const auxiliaryResult = vm.runInNewContext(payload, auxiliary.context);
assert.equal(auxiliaryResult.installed, true);
assert.equal(auxiliary.rootClasses.has("codex-dream-skin"), false);
assert.equal(auxiliary.rootStyles.has("--dream-art"), false);
assert.equal(auxiliary.nodes.has("codex-dream-skin-style"), false);
assert.equal(auxiliary.nodes.has("codex-dream-skin-chrome"), false);

auxiliary.setShellPresent(true);
auxiliary.context.window.__CODEX_DREAM_SKIN_STATE__.ensure();
assert.equal(auxiliary.rootClasses.has("codex-dream-skin"), true);
assert.equal(auxiliary.nodes.has("codex-dream-skin-style"), true);
assert.equal(auxiliary.nodes.has("codex-dream-skin-chrome"), true);

const configured = createFixture({
  shellPresent: true,
  homePresent: true,
  utilityPresent: true,
});
const configuredPayload = buildPayload({
  appearance: "light",
  palette: { accent: "#d45a70" },
  art: { focusX: .15, focusY: .8, safeArea: "right", taskMode: "off" },
  media: { opacity: 0.35 },
});
const configuredResult = vm.runInNewContext(configuredPayload, configured.context);
assert.equal(configuredResult.adaptive, true);
assert.equal(configured.rootClasses.has("dream-theme-light"), true);
assert.equal(configured.rootClasses.has("dream-theme-dark"), false);
assert.equal(configured.rootClasses.has("dream-focus-left"), true);
assert.equal(configured.rootClasses.has("dream-safe-right"), true);
assert.equal(configured.rootClasses.has("dream-task-off"), true);
assert.equal(configured.rootStyles.get("--dream-art-position"), "15% 80%");
assert.equal(configured.rootStyles.get("--dream-accent"), "#d45a70");
assert.equal(configured.rootStyles.get("--dream-wallpaper-reveal"), "0.35");
assert.equal(configured.rootStyles.get("--dream-wallpaper-cover"), "65%");
assert.equal(configured.routeClasses.has("dream-home"), true);
assert.equal(configured.routeClasses.has("dream-task"), false);
assert.equal(configured.utilityClasses.has("dream-home-utility"), true);
assert.equal(configured.context.window.__CODEX_DREAM_SKIN_STATE__.cleanup(), true);
assert.equal(configured.utilityClasses.has("dream-home-utility"), false);

const analysisPixels = new Uint8ClampedArray(48 * 12 * 4);
for (let index = 0; index < 48 * 12; index += 1) {
  const offset = index * 4;
  const x = index % 48;
  const subject = x >= 34 && x <= 42;
  analysisPixels[offset] = subject ? 210 : 246;
  analysisPixels[offset + 1] = subject ? 84 : 239;
  analysisPixels[offset + 2] = subject ? 112 : 237;
  analysisPixels[offset + 3] = 255;
}
const analyzed = createFixture({
  shellPresent: true,
  analysisFixture: { naturalWidth: 1200, naturalHeight: 400, pixels: analysisPixels },
});
vm.runInNewContext(payload, analyzed.context);
await Promise.resolve();
assert.equal(analyzed.rootClasses.has("dream-theme-dark"), true);
assert.equal(analyzed.rootClasses.has("dream-theme-light"), false);
assert.equal(analyzed.rootClasses.has("dream-art-wide"), true);
assert.equal(analyzed.rootClasses.has("dream-task-banner"), true);
assert.equal(analyzed.rootClasses.has("dream-safe-left"), true);
assert.notEqual(analyzed.rootStyles.get("--dream-accent"), "rgb(216 104 119)");

const standardArt = createFixture({
  shellPresent: true,
  analysisFixture: { naturalWidth: 800, naturalHeight: 800, pixels: analysisPixels },
});
vm.runInNewContext(payload, standardArt.context);
await Promise.resolve();
assert.equal(standardArt.rootClasses.has("dream-art-standard"), true);
assert.equal(standardArt.rootClasses.has("dream-task-ambient"), true);
assert.equal(standardArt.rootClasses.has("dream-task-banner"), false);

const mediumWide = createFixture({
  shellPresent: true,
  analysisFixture: { naturalWidth: 2100, naturalHeight: 1000, pixels: analysisPixels },
});
vm.runInNewContext(payload, mediumWide.context);
await Promise.resolve();
assert.equal(mediumWide.rootClasses.has("dream-art-wide"), true);
assert.equal(mediumWide.rootClasses.has("dream-task-ambient"), true);
assert.equal(mediumWide.rootClasses.has("dream-task-banner"), false);

const nativeLight = createFixture({ shellPresent: true, shellAppearance: "light" });
vm.runInNewContext(payload, nativeLight.context);
assert.equal(nativeLight.rootClasses.has("dream-theme-light"), true);
assert.equal(nativeLight.rootClasses.has("dream-theme-dark"), false);

const nativeComputedDark = createFixture({
  shellPresent: true,
  shellAppearance: "",
  computedColorScheme: "dark",
  osAppearance: "light",
});
vm.runInNewContext(payload, nativeComputedDark.context);
assert.equal(nativeComputedDark.rootClasses.has("dream-theme-dark"), true);
assert.equal(nativeComputedDark.rootClasses.has("dream-theme-light"), false);
nativeComputedDark.context.window.__CODEX_DREAM_SKIN_STATE__.ensure();
assert.equal(nativeComputedDark.rootClasses.has("dream-theme-dark"), true);
const nativeObserver = nativeComputedDark.observers[0];
nativeObserver.takeRecords();
nativeComputedDark.context.window.__CODEX_DREAM_SKIN_STATE__.ensure();
assert.equal(nativeObserver.takeRecords().length, 0,
  "Sampling the native computed color-scheme must not queue a self-triggering root mutation pass.");

const metadataWide = createFixture({ shellPresent: true });
vm.runInNewContext(buildPayload({ artMetadata: { ratio: 16 / 9 } }), metadataWide.context);
assert.equal(metadataWide.rootClasses.has("dream-art-wide"), true);
assert.equal(metadataWide.rootClasses.has("dream-art-standard"), false);

const videoTheme = createFixture({ shellPresent: true });
vm.runInNewContext(buildPayload({
  media: { type: "video", mime: "video/mp4", size: 4, playbackRate: 1, opacity: 0.6 },
  artMetadata: { ratio: 16 / 9 },
}, ""), videoTheme.context);
assert.equal(videoTheme.rootClasses.has("dream-art-video"), true);
assert.equal(videoTheme.rootStyles.get("--dream-wallpaper-reveal"), "0.60");
const videoState = videoTheme.context.window.__CODEX_DREAM_SKIN_STATE__;
assert.equal(videoState.beginMedia({ mime: "video/mp4", size: 4 }), true);
assert.equal(videoState.appendMedia("AAECAw=="), true);
assert.equal(videoState.commitMedia(), true);
assert.equal(videoTheme.nodes.has("codex-dream-skin-media"), true);
assert.equal(videoTheme.nodes.get("codex-dream-skin-media").muted, true);
assert.equal(videoTheme.nodes.get("codex-dream-skin-media").loop, true);
assert.equal(videoTheme.nodes.get("codex-dream-skin-media").paused, false);
const initialMediaPlayCount = videoTheme.mediaPlayCount;
videoState.ensure();
assert.equal(videoTheme.mediaPlayCount, initialMediaPlayCount,
  "An unchanged ensure pass must not call play() again for an already playing video.");
assert.equal(videoState.setWallpaperReveal(0), 0);
assert.equal(videoTheme.rootStyles.get("--dream-wallpaper-cover"), "100%");
assert.equal(videoTheme.nodes.get("codex-dream-skin-media").paused, true,
  "A fully covered dynamic wallpaper must stop decoding invisible frames.");
assert.equal(videoState.setWallpaperReveal(0.25), 0.25);
assert.equal(videoTheme.rootStyles.get("--dream-wallpaper-reveal"), "0.25");
assert.equal(videoTheme.rootStyles.get("--dream-wallpaper-cover"), "75%");
assert.equal(videoTheme.nodes.get("codex-dream-skin-media").paused, false);
assert.equal(videoState.setWallpaperReveal(2), null);
videoTheme.setDocumentHidden(true);
assert.equal(videoTheme.nodes.get("codex-dream-skin-media").paused, true);
videoTheme.setDocumentHidden(false);
assert.equal(videoTheme.nodes.get("codex-dream-skin-media").paused, false);
assert.equal(videoTheme.rootStyles.get("--dream-art"), "none");
assert.equal(videoState.cleanup(), true);
assert.equal(videoTheme.nodes.has("codex-dream-skin-media"), false);
assert.deepEqual(videoTheme.revokedUrls, ["blob:fixture-1"]);

const streamUrl = "http://127.0.0.1:17866/1234567890abcdef1234567890abcdef/stream.mp4";
const sceneStream = createFixture({
  shellPresent: true,
  streamFixture: { chunks: [[0, 0, 0, 24], [102, 116, 121, 112]] },
});
vm.runInNewContext(buildPayload({
  media: {
    type: "video",
    mime: "video/mp4",
    streamUrl,
    codec: "avc1.42c01f",
    opacity: 1,
  },
  artMetadata: { ratio: 16 / 9 },
}, ""), sceneStream.context);
for (let index = 0; index < 8; index += 1) await new Promise((resolve) => setImmediate(resolve));
const sceneStreamState = sceneStream.context.window.__CODEX_DREAM_SKIN_STATE__;
assert.equal(sceneStreamState.config.streamUrl, streamUrl);
assert.equal(sceneStream.streamFetchUrl, streamUrl);
assert.equal(sceneStream.streamAppendCount, 2);
assert.equal(sceneStream.streamEnded, true);
assert.equal(sceneStreamState.streamStats.status, "ended");
assert.equal(sceneStreamState.streamStats.chunks, 2);
assert.equal(sceneStreamState.streamStats.bytes, 8);
assert.equal(sceneStreamState.streamStats.error, null);
assert.equal(sceneStream.nodes.get("codex-dream-skin-media").loop, false,
  "A continuous scene stream must not loop the MediaSource URL.");
assert.equal(sceneStreamState.cleanup(), true);
assert.equal(sceneStream.streamAborted, true);

const failedStream = createFixture({
  shellPresent: true,
  streamFixture: { chunks: [], error: "Refused to connect by Content Security Policy" },
});
vm.runInNewContext(buildPayload({
  media: {
    type: "video",
    mime: "video/mp4",
    streamUrl,
    codec: "avc1.42c01f",
  },
}, ""), failedStream.context);
for (let index = 0; index < 4; index += 1) await new Promise((resolve) => setImmediate(resolve));
const failedStreamStats = failedStream.context.window.__CODEX_DREAM_SKIN_STATE__.streamStats;
assert.equal(failedStreamStats.status, "error");
assert.equal(failedStreamStats.error, "Refused to connect by Content Security Policy");

const remoteStream = createFixture({ shellPresent: true, streamFixture: { chunks: [] } });
vm.runInNewContext(buildPayload({
  media: {
    type: "video",
    mime: "video/mp4",
    streamUrl: "http://192.168.1.5:17866/1234567890abcdef1234567890abcdef/stream.mp4",
  },
}, ""), remoteStream.context);
await new Promise((resolve) => setImmediate(resolve));
assert.equal(remoteStream.context.window.__CODEX_DREAM_SKIN_STATE__.config.streamUrl, null);
assert.equal(remoteStream.streamFetchUrl, null,
  "Renderer defense-in-depth must reject non-loopback stream URLs.");

console.log("PASS: renderer applies adaptive theme metadata and preserves transparent auxiliary windows.");
