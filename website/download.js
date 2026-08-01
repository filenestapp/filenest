const FALLBACK_RELEASE = {
  tagName: "v0.2.9",
  version: "0.2.9",
  url: "https://github.com/filenestapp/filenest/releases/tag/v0.2.9",
};

const repository = "filenestapp/filenest";
let activeRelease = null;

function updateText(selector, value) {
  document.querySelectorAll(selector).forEach((element) => {
    element.textContent = value;
  });
}

function releaseAssetURL(release, name) {
  return release.assets?.find((asset) => asset.name === name)?.browser_download_url;
}

function releaseAsset(release, name) {
  return release.assets?.find((asset) => asset.name === name);
}

function formatSize(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return "";
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

function detectPlatform() {
  const platform = navigator.userAgentData?.platform || navigator.platform || navigator.userAgent || "";
  if (/win/i.test(platform)) return "windows";
  if (/mac|iphone|ipad|ipod/i.test(platform)) return "macos";
  return "unknown";
}

function message(key, fallback, values = {}) {
  const localized = window.FileNestLocale?.messages?.downloads?.[key] || fallback;
  return localized.replace(/\{(\w+)\}/g, (_, name) => values[name] ?? "");
}

function releaseData(release) {
  const version = release.tag_name.replace(/^v/, "");
  return {
    version,
    macOS: releaseAssetURL(release, `FileNest-${version}-macOS.dmg`),
    windows: releaseAssetURL(release, `FileNest-Setup-${version}.exe`),
    macOSAsset: releaseAsset(release, `FileNest-${version}-macOS.dmg`),
  };
}

function renderAutoDownload() {
  if (!activeRelease) return;

  const release = releaseData(activeRelease);
  const platform = detectPlatform();
  const platformLabel = platform === "macos"
    ? message("macos", "macOS")
    : platform === "windows"
      ? message("windows", "Windows")
      : message("unknownPlatform", "your computer");
  const directDownload = platform === "macos" ? release.macOS : platform === "windows" ? release.windows : null;
  const primaryLabel = directDownload
    ? message("downloadFor", "Download for {platform}", { platform: platformLabel })
    : message("chooseDownload", "Choose your download");
  const statusLabel = directDownload
    ? message("detectedPlatform", "Detected: {platform}", { platform: platformLabel })
    : message("selectPlatform", "Choose macOS or Windows");
  const buildNote = directDownload
    ? message("installerNote", "{platform} installer · Version {version} · Signed release", { platform: platformLabel, version: release.version })
    : message("selectPlatformNote", "Select a supported desktop platform to download the right installer.");

  updateText("[data-release-auto-label]", primaryLabel);
  updateText("[data-release-auto-platform]", statusLabel);
  updateText("[data-release-auto-build]", buildNote);
  document.querySelectorAll("[data-release-auto-download]").forEach((element) => {
    element.href = directDownload || "download.html#platform-status-title";
  });
}

function applyRelease(release) {
  activeRelease = release;
  const data = releaseData(release);
  const macOSSize = formatSize(data.macOSAsset?.size);

  updateText("[data-release-version]", data.version);
  updateText("[data-release-build-note]", `Version ${data.version} · macOS 13 or later · Developer ID signed and notarized`);
  updateText("[data-release-asset-details]", macOSSize
    ? `DMG installer · ${macOSSize}`
    : "Signed DMG installer");
  document.querySelectorAll("[data-release-url]").forEach((element) => {
    element.href = release.html_url;
  });
  if (data.macOS) {
    document.querySelectorAll('[data-release-download="macos-dmg"]').forEach((element) => {
      element.href = data.macOS;
    });
  }
  if (data.windows) {
    document.querySelectorAll('[data-release-download="windows-setup"]').forEach((element) => {
      element.href = data.windows;
    });
  }

  const checksumAsset = releaseAssetURL(release, "SHA256SUMS-macOS.txt");
  if (checksumAsset) {
    fetch(checksumAsset)
      .then((response) => response.ok ? response.text() : Promise.reject(new Error("checksum unavailable")))
      .then((text) => {
        const digest = text.match(/^[a-f0-9]{64}(?=\s+FileNest-.*-macOS\.dmg$)/im)?.[0];
        if (digest) updateText("[data-release-checksum]", `SHA-256 ${digest}`);
      })
      .catch(() => {});
  }

  renderAutoDownload();
}

window.addEventListener("filenest:localechange", renderAutoDownload);

fetch(`https://api.github.com/repos/${repository}/releases/latest`, {
  headers: { Accept: "application/vnd.github+json" },
})
  .then((response) => response.ok ? response.json() : Promise.reject(new Error("release unavailable")))
  .then(applyRelease)
  .catch(() => applyRelease({
    tag_name: FALLBACK_RELEASE.tagName,
    html_url: FALLBACK_RELEASE.url,
    assets: [
      {
        name: `FileNest-${FALLBACK_RELEASE.version}-macOS.dmg`,
        browser_download_url: `https://github.com/filenestapp/filenest/releases/download/${FALLBACK_RELEASE.tagName}/FileNest-${FALLBACK_RELEASE.version}-macOS.dmg`,
      },
      {
        name: `FileNest-Setup-${FALLBACK_RELEASE.version}.exe`,
        browser_download_url: `https://github.com/filenestapp/filenest/releases/download/${FALLBACK_RELEASE.tagName}/FileNest-Setup-${FALLBACK_RELEASE.version}.exe`,
      },
    ],
  }));
