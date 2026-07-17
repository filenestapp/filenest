# RAG Evaluation

## Purpose

FileNest records bounded local retrieval traces so ranking changes can be measured instead of judged from isolated chat examples. The trace contains the query, semantic query, lexical/semantic/entity candidate counts, fused count, returned count, effective semantic threshold, reranker identity, and latency. It does not send evaluation data outside the device.

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

## Release gates

1. Do not reduce File Recall@10 or Parent Recall@8 against the previous release.
2. Exact-entity queries must not regress when semantic similarity is low.
3. Reranker failure must return the same fused candidate set without blocking chat.
4. Legacy indexes must remain searchable before a selective rebuild.
5. Parent–Child rebuilds must preserve table headers, page ranges, section paths, and note-only updates.

Chunk-level FTS is intentionally excluded from the current design. Add it only if measured lexical misses remain after entity retrieval and file-level FTS, and validate the storage and indexing cost against this baseline.
