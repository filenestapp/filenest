const DEFAULT_LOCALE = "en";
const SUPPORTED_LOCALES = ["zh-CN", "en"];

const header = document.querySelector("[data-header]");
const menuButton = document.querySelector("[data-menu-button]");
const navigation = document.querySelector("[data-nav]");
const localeSwitch = document.querySelector("[data-locale-switch]");
const localeLabel = document.querySelector("[data-locale-label]");
const githubLinks = [...document.querySelectorAll(".github-link")];
const githubStarValues = [...document.querySelectorAll("[data-github-stars]")];
const platformButtons = [...document.querySelectorAll("[data-platform]")];
const platformPanels = [...document.querySelectorAll("[data-platform-panel]")];
const demoLab = document.querySelector("[data-demo-lab]");
const demoButtons = [...document.querySelectorAll("[data-demo-tab]")];
const demoPanels = [...document.querySelectorAll("[data-demo-panel]")];
const demoProgressItems = [...document.querySelectorAll(".demo-progress span")];
const demoStatus = document.querySelector("[data-demo-status]");
const demoReplay = document.querySelector("[data-demo-replay]");
const demoAutoplay = document.querySelector("[data-demo-autoplay]");
const demoAutoplayLabel = document.querySelector("[data-demo-autoplay-label]");
const demoSidebarLibrary = document.querySelector("[data-demo-sidebar-library]");
const demoSidebarChat = document.querySelector("[data-demo-sidebar-chat]");
const demoRecentFind = document.querySelector("[data-demo-recent-find]");
const demoRecentFile = document.querySelector("[data-demo-recent-file]");
const heroDemoLinks = [...document.querySelectorAll("[data-hero-demo]")];
const productVideo = document.querySelector("[data-product-video]");
const productVideoToggle = document.querySelector("[data-product-video-toggle]");
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

let currentLocale = localStorage.getItem("filenest-locale") || DEFAULT_LOCALE;
if (!SUPPORTED_LOCALES.includes(currentLocale)) currentLocale = DEFAULT_LOCALE;
let currentMessages = null;
let githubStarCount = Number.parseInt(githubStarValues[0]?.textContent || "", 10);
let activeDemoIndex = 0;
let demoTimer = null;
let demoVisible = false;
let isDemoAutoplaying = !reducedMotion.matches;

const DEMO_INTERVAL = 5200;

function getNestedValue(object, path) {
  return path.split(".").reduce((value, key) => value?.[key], object);
}

function updateGitHubStarDisplay() {
  if (!Number.isInteger(githubStarCount) || githubStarCount < 0) return;
  const formattedCount = new Intl.NumberFormat(currentLocale, {
    notation: githubStarCount >= 1000 ? "compact" : "standard",
    maximumFractionDigits: 1,
  }).format(githubStarCount);

  githubStarValues.forEach((element) => {
    element.textContent = formattedCount;
  });

  const template = currentMessages?.nav.githubStarsLabel || "FileNest on GitHub, {count} stars";
  githubLinks.forEach((link) => {
    link.setAttribute("aria-label", template.replace("{count}", formattedCount));
  });
}

async function loadGitHubStarCount() {
  try {
    const response = await fetch("https://api.github.com/repos/filenestapp/filenest", {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!response.ok) return;
    const repository = await response.json();
    if (!Number.isInteger(repository.stargazers_count) || repository.stargazers_count < 0) return;
    githubStarCount = repository.stargazers_count;
    updateGitHubStarDisplay();
  } catch {
    // Keep the server-rendered count when GitHub is unavailable.
  }
}

async function applyLocale(locale) {
  try {
    const response = await fetch(`locales/${locale}.json?v=20260731-2`);
    if (!response.ok) throw new Error(`Locale request failed with status ${response.status}`);
    const messages = await response.json();

    document.querySelectorAll("[data-i18n]").forEach((element) => {
      const value = getNestedValue(messages, element.dataset.i18n);
      if (typeof value === "string") element.textContent = value;
    });

    document.querySelectorAll("[data-i18n-alt]").forEach((element) => {
      const value = getNestedValue(messages, element.dataset.i18nAlt);
      if (typeof value === "string") element.alt = value;
    });

    document.querySelectorAll("[data-i18n-aria-label]").forEach((element) => {
      const value = getNestedValue(messages, element.dataset.i18nAriaLabel);
      if (typeof value === "string") element.setAttribute("aria-label", value);
    });

    document.documentElement.lang = locale;
    document.title = messages.meta.title;
    document.querySelector('meta[name="description"]').content = messages.meta.description;
    localeLabel.textContent = locale === "zh-CN" ? "EN" : "ZH";
    localStorage.setItem("filenest-locale", locale);
    currentLocale = locale;
    currentMessages = messages;
    updateGitHubStarDisplay();
    updateDemoLabels();
    updateProductVideoLabel();
  } catch (error) {
    console.error("Unable to load the selected locale.", error);
  }
}

function updateProductVideoLabel() {
  if (!productVideoToggle) return;
  const isPlaying = !productVideo?.paused;
  productVideoToggle.textContent = isPlaying
    ? currentMessages?.video.pause || "Pause motion"
    : currentMessages?.video.play || "Play motion";
  productVideoToggle.setAttribute("aria-pressed", String(isPlaying));
}

function closeMenu() {
  menuButton.setAttribute("aria-expanded", "false");
  navigation.classList.remove("is-open");
  document.body.classList.remove("menu-open");
}

menuButton.addEventListener("click", () => {
  const isOpen = menuButton.getAttribute("aria-expanded") === "true";
  menuButton.setAttribute("aria-expanded", String(!isOpen));
  navigation.classList.toggle("is-open", !isOpen);
  document.body.classList.toggle("menu-open", !isOpen);
});

navigation.addEventListener("click", (event) => {
  if (event.target.closest("a")) closeMenu();
});

localeSwitch.addEventListener("click", () => {
  const nextLocale = currentLocale === "zh-CN" ? "en" : "zh-CN";
  applyLocale(nextLocale);
});

window.addEventListener("scroll", () => {
  header.classList.toggle("is-scrolled", window.scrollY > 16);
}, { passive: true });

platformButtons.forEach((button) => {
  button.addEventListener("click", () => {
    const platform = button.dataset.platform;
    platformButtons.forEach((item) => item.setAttribute("aria-selected", String(item === button)));
    platformPanels.forEach((panel) => {
      panel.hidden = panel.dataset.platformPanel !== platform;
    });
  });
});

function clearDemoTimer() {
  if (demoTimer !== null) window.clearTimeout(demoTimer);
  demoTimer = null;
}

function restartDemoPanel(panel) {
  panel.classList.remove("is-running");
  if (reducedMotion.matches) return;
  void panel.offsetWidth;
  panel.classList.add("is-running");
}

function updateDemoLabels() {
  if (!demoButtons.length) return;
  const activeButton = demoButtons[activeDemoIndex];
  demoStatus.textContent = activeButton.textContent.trim();
  demoAutoplayLabel.textContent = isDemoAutoplaying
    ? currentMessages?.demo.pause || "Pause"
    : currentMessages?.demo.play || "Play";
  demoAutoplay.setAttribute("aria-pressed", String(isDemoAutoplaying));
}

function scheduleNextDemo() {
  clearDemoTimer();
  if (!isDemoAutoplaying || !demoVisible || reducedMotion.matches) return;
  demoTimer = window.setTimeout(() => {
    activateDemo((activeDemoIndex + 1) % demoButtons.length);
  }, DEMO_INTERVAL);
}

function updateDemoSidebar(mode) {
  const libraryMode = ["indexing", "search", "smart"].includes(mode);
  demoSidebarLibrary?.classList.toggle("is-selected", libraryMode);
  demoSidebarChat?.classList.toggle("is-selected", !libraryMode);
  demoRecentFind?.classList.toggle("is-selected", mode === "find-chat");
  demoRecentFile?.classList.toggle("is-selected", mode === "file-chat");
}

function activateDemo(index, options = {}) {
  const normalizedIndex = (index + demoButtons.length) % demoButtons.length;
  activeDemoIndex = normalizedIndex;

  demoButtons.forEach((button, buttonIndex) => {
    const isActive = buttonIndex === normalizedIndex;
    button.setAttribute("aria-selected", String(isActive));
    button.tabIndex = isActive ? 0 : -1;
  });

  demoPanels.forEach((panel, panelIndex) => {
    const isActive = panelIndex === normalizedIndex;
    panel.hidden = !isActive;
    if (isActive) restartDemoPanel(panel);
    else panel.classList.remove("is-running");
  });

  demoProgressItems.forEach((item, itemIndex) => {
    item.classList.toggle("is-active", itemIndex === normalizedIndex);
  });

  updateDemoSidebar(demoButtons[normalizedIndex].dataset.demoTab);
  updateDemoLabels();
  if (options.focus) demoButtons[normalizedIndex].focus();
  if (options.scroll) demoButtons[normalizedIndex].scrollIntoView({ block: "nearest", inline: "center", behavior: reducedMotion.matches ? "auto" : "smooth" });
  scheduleNextDemo();
}

demoButtons.forEach((button, index) => {
  button.addEventListener("click", () => activateDemo(index, { scroll: true }));
  button.addEventListener("keydown", (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    let nextIndex = index;
    if (event.key === "ArrowLeft") nextIndex = index - 1;
    if (event.key === "ArrowRight") nextIndex = index + 1;
    if (event.key === "Home") nextIndex = 0;
    if (event.key === "End") nextIndex = demoButtons.length - 1;
    activateDemo(nextIndex, { focus: true, scroll: true });
  });
});

heroDemoLinks.forEach((link) => {
  link.addEventListener("click", () => {
    const index = demoButtons.findIndex((button) => button.dataset.demoTab === link.dataset.heroDemo);
    if (index >= 0) activateDemo(index);
  });
});

if (productVideo && productVideoToggle) {
  const syncProductVideo = () => updateProductVideoLabel();
  productVideo.addEventListener("play", syncProductVideo);
  productVideo.addEventListener("pause", syncProductVideo);
  productVideoToggle.addEventListener("click", () => {
    if (productVideo.paused) productVideo.play().catch(() => {});
    else productVideo.pause();
  });

  if (reducedMotion.matches) productVideo.pause();
}

demoReplay.addEventListener("click", () => {
  restartDemoPanel(demoPanels[activeDemoIndex]);
  scheduleNextDemo();
});

demoAutoplay.addEventListener("click", () => {
  isDemoAutoplaying = !isDemoAutoplaying;
  updateDemoLabels();
  if (isDemoAutoplaying) {
    restartDemoPanel(demoPanels[activeDemoIndex]);
    scheduleNextDemo();
  } else {
    clearDemoTimer();
  }
});

const demoObserver = new IntersectionObserver((entries) => {
  demoVisible = entries[0].isIntersecting;
  if (demoVisible) {
    restartDemoPanel(demoPanels[activeDemoIndex]);
    scheduleNextDemo();
  } else {
    clearDemoTimer();
  }
}, { threshold: 0.24 });

demoObserver.observe(demoLab);
reducedMotion.addEventListener("change", () => {
  isDemoAutoplaying = !reducedMotion.matches;
  demoPanels.forEach((panel) => panel.classList.remove("is-running"));
  updateDemoLabels();
  scheduleNextDemo();
  if (productVideo) {
    if (reducedMotion.matches) productVideo.pause();
    else productVideo.play().catch(() => {});
  }
});

const tiltTarget = document.querySelector("[data-tilt]");
const canTilt = window.matchMedia("(pointer: fine) and (prefers-reduced-motion: no-preference)");

if (tiltTarget && canTilt.matches) {
  tiltTarget.parentElement.addEventListener("pointermove", (event) => {
    const bounds = tiltTarget.parentElement.getBoundingClientRect();
    const x = (event.clientX - bounds.left) / bounds.width - 0.5;
    const y = (event.clientY - bounds.top) / bounds.height - 0.5;
    tiltTarget.style.transform = `rotateY(${x * 5 - 4}deg) rotateX(${y * -4 + 2}deg) translateY(-3px)`;
  });

  tiltTarget.parentElement.addEventListener("pointerleave", () => {
    tiltTarget.style.transform = "rotateY(-5deg) rotateX(2deg)";
  });
}

document.querySelector("[data-year]").textContent = new Date().getFullYear();
applyLocale(currentLocale);
loadGitHubStarCount();
