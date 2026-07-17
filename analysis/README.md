# macOS Product and Business Analysis

This directory contains a decision-oriented FileNest macOS product report generated on July 16, 2026. It is retained as a historical analysis snapshot. Current product behavior, test status, and architecture are documented in [`docs/00-index.md`](../docs/00-index.md) and defined by the source tree.

## Contents

| File | Purpose |
| --- | --- |
| [`FileNest_macOS_product_business_analysis.html`](FileNest_macOS_product_business_analysis.html) | Self-contained reader-facing report |
| [`macos_product_analysis_artifact.json`](macos_product_analysis_artifact.json) | Structured report source used to build the HTML artifact |
| [`macos_product_business_analysis.ipynb`](macos_product_business_analysis.ipynb) | Executed companion notebook with repository metrics and decision rubric |
| [`generate_macos_product_analysis_notebook.py`](generate_macos_product_analysis_notebook.py) | Rebuilds and structurally validates the notebook |
| [`deliver_macos_product_report.mjs`](deliver_macos_product_report.mjs) | Builds the portable HTML through the optional Codex data-analytics plugin |
| [`test_run_summary.json`](test_run_summary.json) | Verification evidence captured for the report baseline |
| [`report_notes.md`](report_notes.md) | Scope, assumptions, chart map, omitted metrics, and validation notes |

## Reproduction

Regenerate the notebook from the repository root:

```bash
python3 analysis/generate_macos_product_analysis_notebook.py
```

The HTML delivery helper depends on the optional Codex data-analytics plugin. Point the helper at an installed plugin version rather than storing a machine-specific path:

```bash
CODEX_DATA_ANALYTICS_PLUGIN_ROOT=/path/to/data-analytics-plugin \
  node analysis/deliver_macos_product_report.mjs
```

The committed HTML is self-contained and does not require that plugin for viewing.

## Interpretation limits

- The captured test run contains 255 passing tests and reflects the July 16 baseline, not the latest suite size.
- Readiness values are a decision rubric, not observed customer KPIs.
- Competitor and pricing claims were current when the report was produced and require fresh source verification before a new decision.
- Repository metrics change when the notebook generator is rerun against a newer checkout.
- The report may identify risks that later commits have already addressed; verify every implementation claim against the current documentation and source.
