const FALLBACK_RELEASE = {
  tagName: "v0.2.6",
  version: "0.2.6",
  url: "https://github.com/filenestapp/filenest/releases/tag/v0.2.6",
};

const repository = "filenestapp/filenest";

function updateText(selector, value) {
  document.querySelectorAll(selector).forEach((element) => {
    element.textContent = value;
  });
}

function releaseAssetURL(release, name) {
  return release.assets?.find((asset) => asset.name === name)?.browser_download_url;
}

function formatSize(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return "Signed DMG installer";
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

function applyRelease(release) {
  const version = release.tag_name.replace(/^v/, "");
  const macOSDMG = releaseAssetURL(release, `FileNest-${version}-macOS.dmg`);
  const windowsSetup = releaseAssetURL(release, `FileNest-Setup-${version}.exe`);
  const macOSAsset = release.assets?.find((asset) => asset.name === `FileNest-${version}-macOS.dmg`);

  updateText("[data-release-version]", version);
  updateText("[data-release-build-note]", `Version ${version} · macOS 13 or later · Developer ID signed and notarized`);
  updateText("[data-release-asset-details]", `DMG installer · ${formatSize(macOSAsset?.size)}`);
  document.querySelectorAll("[data-release-url]").forEach((element) => {
    element.href = release.html_url;
  });
  if (macOSDMG) {
    document.querySelectorAll('[data-release-download="macos-dmg"]').forEach((element) => {
      element.href = macOSDMG;
    });
  }
  if (windowsSetup) {
    document.querySelectorAll('[data-release-download="windows-setup"]').forEach((element) => {
      element.href = windowsSetup;
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
}

fetch(`https://api.github.com/repos/${repository}/releases/latest`, {
  headers: { Accept: "application/vnd.github+json" },
})
  .then((response) => response.ok ? response.json() : Promise.reject(new Error("release unavailable")))
  .then(applyRelease)
  .catch(() => applyRelease({
    tag_name: FALLBACK_RELEASE.tagName,
    html_url: FALLBACK_RELEASE.url,
    assets: [],
  }));
