import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const pluginRoot = process.env.CODEX_DATA_ANALYTICS_PLUGIN_ROOT;
if (!pluginRoot) {
  throw new Error(
    "Set CODEX_DATA_ANALYTICS_PLUGIN_ROOT to the installed data-analytics plugin directory.",
  );
}

const reportScripts = resolve(pluginRoot, "skills/build-report/scripts");
const {
  buildPortableArtifact,
  readPackagedReaderRuntime,
} = await import(pathToFileURL(resolve(reportScripts, "build_portable_artifact.mjs")));
const { deliverPortableArtifact } = await import(
  pathToFileURL(resolve(reportScripts, "deliver_portable_artifact.mjs"))
);

const inputPath = resolve("analysis/macos_product_analysis_artifact.json");
const outputPath = resolve("analysis/FileNest_macOS_product_business_analysis.html");
const packagedRuntime = readPackagedReaderRuntime().html;
const originalTopBarLayout = [
  "  width: 100vw;",
  "  height: 48px;",
  "  min-height: 48px;",
  "  margin-right: calc(50% - 50vw);",
  "  margin-left: calc(50% - 50vw);",
].join("\n");
const macOSTopBarLayout = [
  "  width: 100%;",
  "  height: 48px;",
  "  min-height: 48px;",
  "  margin-right: 0;",
  "  margin-left: 0;",
].join("\n");
const runtimeHtml = packagedRuntime.replace(originalTopBarLayout, macOSTopBarLayout);
if (runtimeHtml === packagedRuntime) {
  throw new Error("The packaged reader top-bar layout contract changed; the macOS fix was not applied.");
}

const result = await deliverPortableArtifact(
  {
    inputPath,
    outputPath,
  },
  {
    build: (input, options = {}) => buildPortableArtifact(input, {
      ...options,
      runtimeHtml,
    }),
  },
);

process.stdout.write(`${JSON.stringify(result)}\n`);
if (!result.ok) process.exitCode = 1;
