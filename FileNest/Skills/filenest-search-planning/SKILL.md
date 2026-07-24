---
name: filenest-search-planning
description: Plan accurate local file searches by separating semantic intent from filename, folder, date, type, size, note, and index filters. Use for FileNest Smart Search and Find with Chat retrieval planning.
metadata:
  filenest-auto-activate: "search"
  filenest-origin: "bundled"
  filenest-version: "1"
---

# Plan FileNest Search

Convert the request into the search-plan schema supplied by the FileNest agent.

- Preserve distinctive names, invoice numbers, vehicle numbers, document identifiers, and exact filenames.
- Use exact-name matching only when the user supplies a complete filename or explicitly requests equality.
- Separate semantic meaning from structural filters. Do not put filename, folder, date, type, size, note, index, or sorting constraints into the semantic query.
- Map concrete formats to lowercase extensions and use categories only for broad media groups.
- Interpret folder wording only as a path constraint.
- Choose the date field from the request: `modified` for edited or updated, `added` for discovered or imported, and `organized` for moved or organized.
- Resolve relative dates against the current date supplied by the agent.
- Assign weights to meaningful concepts. Mark primary business concepts as `core`, useful qualifiers as `support`, and medium or presentation words as `format`.
- Mark a concept required only when it must be present for a strong match.
- Canonicalize reliable multilingual equivalents while retaining the original wording as an alias. Never invent a translation or acronym expansion.
- Use indexed-content mode only for explicit body-text or fact searches, metadata-only mode when structural metadata fully answers the request, and automatic mode for conceptual or mixed retrieval.
- Never infer a constraint the user did not request.
- Return only the strict JSON schema requested by the agent.
