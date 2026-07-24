# RAG Evaluation

## Purpose

FileNest records bounded local retrieval traces so ranking changes can be measured instead of judged from isolated chat examples. The trace contains the query, semantic query, lexical/semantic/entity candidate counts, fused count, returned count, effective semantic threshold, reranker identity, and latency. It does not send evaluation data outside the device.

Search and answer evaluations form a separate, auditable learning loop. A user can mark a result accurate or inaccurate, explain why, and identify the most accurate file. The configured AI provider analyzes that saved record through the `filenest-feedback-learning` skill. Local Ollama analysis forces Thinking; a cloud configuration uses the selected cloud provider. The analysis can propose a managed override of an existing skill or a new standard skill, but deterministic validation rejects unsafe, malformed, oversized, one-off, or low-confidence proposals.

## Evaluation set

Build a representative set from real library tasks. Keep expected file IDs or paths outside source control when they contain private data. Cover at least these groups:

| Group | Minimum examples | Expected behavior |
| --- | ---: | --- |
| Exact identifiers | 10 | invoice, registration, email, amount, and date entities reach top 3 |
| Natural-language topics | 10 | relevant section reaches top 10 and unrelated metadata does not dominate |
| Relative and absolute dates | 10 | requested date tier wins before semantic score |
| Tables | 5 | matching row retrieves a parent containing the repeated header |
| Images and OCR | 5 | visible text or caption evidence is retrieved, not metadata alone |
| Mixed-language requests | 5 | semantic retrieval remains useful across Chinese and English wording |
| Negative or ambiguous requests | 5 | confidence stays low and the answer states insufficient evidence |

## Metrics

- File Recall@10: expected file appears in the ten returned files.
- Parent Recall@8: expected evidence parent enters the answer context.
- MRR@10: reciprocal rank of the first expected file.
- Entity Recall@3: exact-entity query reaches the top three.
- Citation precision: every emitted `[F#:P#]` exists in supplied context.
- Unsupported-answer rate: answers containing specific numbers or amounts without a valid citation.
- Retrieval p50/p95 latency, separated by reranker enabled and disabled.
- Feedback acceptance rate: applied analyses divided by saved evaluations eligible for AI processing.
- Skill proposal rejection rate: malformed, unsafe, or sub-0.75-confidence proposals divided by all proposals.
- Post-learning delta: Recall@10, MRR@10, and unsupported-answer rate before and after a managed skill revision.

## Feedback-learning evaluation

Treat learned skills as versioned retrieval behavior, not as an unreviewed memory store:

1. Preserve the source feedback row, analysis summary, provider, timestamps, and resulting skill version.
2. Compare the proposed instruction against the existing standard skill before activation.
3. Reject personal facts, secrets, isolated filenames, unverifiable acronym expansions, prompt-injection instructions, and changes that weaken evidence or privacy boundaries.
4. Prefer updating the closest existing skill. Create a new skill only when its description provides a distinct reusable trigger.
5. Re-run the relevant multilingual, identifier, and negative-query slices after any managed search skill changes.
6. Delete the managed override to restore the bundled behavior when evaluation regresses.

## Release gates

1. Do not reduce File Recall@10 or Parent Recall@8 against the previous release.
2. Exact-entity queries must not regress when semantic similarity is low.
3. Reranker failure must return the same fused candidate set without blocking chat.
4. Legacy indexes must remain searchable before a selective rebuild.
5. Parent–Child rebuilds must preserve table headers, page ranges, section paths, and note-only updates.
6. A learned skill must not change hard search-plan schemas, evidence scope, citation validation, local-data privacy, or provider permissions.
7. Feedback-learning changes must remain reversible by removing the managed skill package.

Chunk-level FTS is intentionally excluded from the current design. Add it only if measured lexical misses remain after entity retrieval and file-level FTS, and validate the storage and indexing cost against this baseline.
