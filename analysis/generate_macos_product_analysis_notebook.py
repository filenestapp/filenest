#!/usr/bin/env python3
"""Generate the reproducible FileNest macOS product-analysis notebook."""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "analysis" / "macos_product_business_analysis.ipynb"


def markdown(source: str) -> dict:
    return {
        "cell_type": "markdown",
        "metadata": {},
        "source": source.splitlines(keepends=True),
    }


def code(source: str) -> dict:
    return {
        "cell_type": "code",
        "execution_count": None,
        "metadata": {},
        "outputs": [],
        "source": source.splitlines(keepends=True),
    }


cells = [
    markdown(
        """# FileNest macOS Product & Business Analysis Companion

## tl;dr

- The macOS implementation is a strong beta candidate: the complete watch → index → search/chat → organize loop exists, and 255 tests pass.
- The largest gap is not feature depth but commercial proof: no acquisition, activation, retention, willingness-to-pay, licensing, or production distribution evidence is present.
- The recommended direction is a narrow document-heavy workflow wedge, with a zero-download first-run path and a measurement-enabled private beta before further feature expansion.
"""
    ),
    markdown(
        """## Context & Methods

This companion treats repository files, the current Xcode test run, and documented UI QA as implementation evidence. It does not treat code volume or test coverage as evidence of product-market fit. Current competitor facts are maintained in the reader-facing report because they require live web verification.

### Key Assumptions

- Audience: product owner or small product team deciding whether to launch, narrow, or keep building.
- Scope: the native macOS target only; Windows is excluded except as a signal that cross-platform expansion exists.
- Readiness scores are decision rubrics, not observed customer KPIs.
- The repository snapshot is analyzed as of July 16, 2026.
"""
    ),
    markdown("## Data\n\n### 1. Profile the macOS repository snapshot\n"),
    code(
        """from pathlib import Path
import json
import re

root = Path.cwd()
app_files = sorted((root / 'FileNest').rglob('*.swift'))
test_files = sorted((root / 'FileNestTests').rglob('*.swift'))

def line_count(paths):
    return sum(len(path.read_text(encoding='utf-8').splitlines()) for path in paths)

test_method_count = sum(
    len(re.findall(r'^\\s*func test', path.read_text(encoding='utf-8'), flags=re.MULTILINE))
    for path in test_files
)
localization_counts = {}
for locale in ('en', 'zh-Hans'):
    text = (root / 'FileNest' / f'{locale}.lproj' / 'Localizable.strings').read_text(encoding='utf-8')
    localization_counts[locale] = len(re.findall(r'^".*"\\s*=\\s*', text, flags=re.MULTILINE))

qa_text = (root / 'design' / 'qa' / 'README.md').read_text(encoding='utf-8')
qa_rounds = len(re.findall(r'^## .*QA —', qa_text, flags=re.MULTILINE))
qa_images = len([p for p in (root / 'design' / 'qa').rglob('*') if p.suffix.lower() in {'.png', '.jpg', '.jpeg'}])

repository_profile = {
    'mac_source_files': len(app_files),
    'mac_source_lines': line_count(app_files),
    'test_files': len(test_files),
    'test_lines': line_count(test_files),
    'test_methods': test_method_count,
    'english_localization_keys': localization_counts['en'],
    'chinese_localization_keys': localization_counts['zh-Hans'],
    'documented_ui_qa_rounds': qa_rounds,
    'ui_qa_images': qa_images,
}
print(json.dumps(repository_profile, indent=2))
"""
    ),
    markdown("### 2. Compare implementation investment by layer\n"),
    code(
        """layer_paths = {
    'App state & lifecycle': root / 'FileNest' / 'App',
    'Domain': root / 'FileNest' / 'Domain',
    'Extraction': root / 'FileNest' / 'Extraction',
    'Providers': root / 'FileNest' / 'Providers',
    'Services': root / 'FileNest' / 'Services',
    'Storage': root / 'FileNest' / 'Storage',
    'UI': root / 'FileNest' / 'UI',
}
layer_lines = {
    layer: line_count(sorted(path.rglob('*.swift')))
    for layer, path in layer_paths.items()
}
layer_total = sum(layer_lines.values())
layer_profile = [
    {'layer': layer, 'lines': lines, 'share': round(lines / layer_total, 4)}
    for layer, lines in sorted(layer_lines.items(), key=lambda item: item[1], reverse=True)
]
print(json.dumps(layer_profile, indent=2))
"""
    ),
    markdown("## Results\n\n### 3. Apply a decision-focused readiness rubric\n"),
    code(
        """readiness = [
    {'dimension': 'Core product loop', 'score': 5.0, 'evidence': 'Watch, index, search/chat, and organize paths are implemented.'},
    {'dimension': 'Reliability engineering', 'score': 4.0, 'evidence': '255 tests passed; core services are heavily exercised.'},
    {'dimension': 'UX and localization', 'score': 4.0, 'evidence': 'Onboarding, menu bar, previews, settings, English/Chinese, and 12 UI QA rounds exist.'},
    {'dimension': 'Distribution and security', 'score': 1.5, 'evidence': 'Production signing/appcast remain incomplete and cloud keys are stored in SQLite.'},
    {'dimension': 'Market validation', 'score': 0.5, 'evidence': 'No customer, activation, retention, or willingness-to-pay evidence is present.'},
    {'dimension': 'Monetization and GTM', 'score': 0.5, 'evidence': 'No licensing, trial, pricing, funnel, or release channel is implemented.'},
]
weighted_mean = round(sum(row['score'] for row in readiness) / len(readiness), 2)
print(json.dumps({'rubric_mean_out_of_5': weighted_mean, 'dimensions': readiness}, indent=2))
"""
    ),
    markdown("### 4. Quantify local-first onboarding weight\n"),
    code(
        """model_download_gb = {
    '8 GB Mac': (2_700_000_000 + 639_000_000 + 2_200_000_000) / 1_000_000_000,
    '16 GB Mac': (3_400_000_000 + 639_000_000 + 2_200_000_000) / 1_000_000_000,
    '24+ GB Mac': (6_600_000_000 + 639_000_000 + 2_200_000_000) / 1_000_000_000,
}
setup_burden = [
    {'device_tier': tier, 'estimated_required_model_download_gb': round(size, 2)}
    for tier, size in model_download_gb.items()
]
print(json.dumps(setup_burden, indent=2))
"""
    ),
    markdown(
        """## Takeaways

1. **Build quality is ahead of business readiness.** The repository supports a private beta, not an evidence-backed public launch.
2. **Activation friction is a strategic risk.** The local path asks users to install runtimes and download roughly 5.54–9.44 GB of models before experiencing the full promise.
3. **The next milestone should be learning, not breadth.** Ship a narrow beta with a zero-download starter path, secure credential storage, a signed distribution channel, and a small activation/retention measurement plan.
"""
    ),
]


namespace: dict = {}
execution_count = 0
for cell in cells:
    if cell["cell_type"] != "code":
        continue
    execution_count += 1
    source = "".join(cell["source"])
    stream = io.StringIO()
    try:
        with contextlib.redirect_stdout(stream):
            compiled = compile(source, f"notebook-cell-{execution_count}", "exec")
            exec(compiled, namespace)
        output = stream.getvalue()
        if output:
            cell["outputs"] = [{"name": "stdout", "output_type": "stream", "text": output.splitlines(keepends=True)}]
    except Exception as error:
        raise RuntimeError(f"Notebook cell {execution_count} failed") from error
    cell["execution_count"] = execution_count


notebook = {
    "cells": cells,
    "metadata": {
        "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
        "language_info": {"name": "python", "version": "3"},
        "filenest_validation": {
            "method": "sequential Python execution fallback",
            "status": "passed",
            "note": "nbformat and Jupyter are not installed in this environment.",
        },
    },
    "nbformat": 4,
    "nbformat_minor": 5,
}

OUTPUT.write_text(json.dumps(notebook, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

# Validate the structural fields that Jupyter requires and confirm every code cell ran.
loaded = json.loads(OUTPUT.read_text(encoding="utf-8"))
assert loaded["nbformat"] == 4
assert isinstance(loaded["cells"], list) and loaded["cells"]
assert all(cell.get("cell_type") in {"markdown", "code"} for cell in loaded["cells"])
assert all(cell.get("execution_count") is not None for cell in loaded["cells"] if cell["cell_type"] == "code")
print(OUTPUT)
