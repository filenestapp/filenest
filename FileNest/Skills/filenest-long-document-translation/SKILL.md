---
name: filenest-long-document-translation
description: Translate, summarize, outline, or analyze a long attached or indexed document without losing sections. Use for FileNest Chat with File requests that require processing most or all of a document, especially when it exceeds one model context window.
metadata:
  filenest-tools: "chunk-manifest,coverage-validator,structured-output-validator"
  filenest-execution-route: "map-reduce"
  filenest-route-priority: "100"
---

# Process a Long Document

Use only evidence from the attached file.

## Plan the work

1. Determine the requested target language and whether the user wants translation, summary, or both.
2. Load the complete ordered document manifest.
3. Preserve every section, page range, table, list, image caption, footnote, and transcript range.
4. Process source chunks in document order rather than semantic-relevance order.
5. Do not claim complete coverage when the complete manifest is unavailable.

## Process every batch

1. Preserve names, dates, numbers, currencies, identifiers, legal terms, and units exactly.
2. Translate faithfully without condensing unless the user explicitly requests condensation.
3. Preserve headings, tables, lists, and paragraph relationships.
4. Record the source chunk identifier, location, key facts, entities, numbers, dates, ambiguities, and cross-references.
5. Save each completed batch before loading the next batch.
6. Never infer missing text or continue a truncated sentence without source evidence.

## Reduce hierarchically

1. Combine chunk facts into batch summaries.
2. Combine batch summaries into section summaries.
3. Combine section summaries into the final document summary.
4. Base summaries on source facts, not only on generated translations.
5. Deduplicate repeated facts while retaining exceptions, qualifications, and contradictions.

## Verify completeness

Before finalizing:

- Confirm that processed source chunk identifiers equal the complete manifest.
- Confirm that no page or section range is missing.
- Confirm that tables and lists were not silently discarded.
- Confirm that names, dates, numbers, currencies, identifiers, and units remain consistent.
- Identify unreadable, empty, or ambiguous source sections explicitly.

Do not report completion below 100% coverage. Report missing chunk or page ranges instead.

## Produce the response

- Put the requested summary before the complete translation when both are requested.
- Preserve the source heading hierarchy and table structure.
- Include a compact coverage statement with processed and total source chunk counts.
- Answer in the language requested by the user.
