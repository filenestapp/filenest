# Agent Harness Adapter Architecture

FileNest treats an agent harness as a replaceable runtime behind a small adapter
boundary. OMP is one adapter, not a dependency of the chat orchestration layer.

## Runtime layers

1. `ChatService` prepares a unified `AgentHarnessRequest` containing the
   interaction mode, conversation history, capability-bounded evidence, a
   bounded projection of the active FileNest skills, and the active global
   generation configuration (provider, model, endpoint, and Thinking flag).
2. `AgentHarnessRegistry` resolves the selected `AgentHarnessKind` to an
   `AgentHarnessAdapter`.
3. The adapter creates an `AgentEngine` and owns runtime-specific process,
   workspace, session, and tool wiring.
4. `AgentEngine` exposes normalized lifecycle, text, tool, notice, cancellation,
   and completion events to FileNest.
5. `FileNestAgentToolGateway` remains the capability boundary. A harness never
   receives an attachment path or unrestricted FileNest process access.

## SKILL and feedback flow

FileNest resolves skills before selecting a harness. Defaults, explicit `$skill`
references, active session skills, and dynamic routing produce one
`AgentSkillActivation`. Retrieval and planning use that activation first, then
the adapter receives only `AgentHarnessSkillContext`: selected names plus a
length-limited instruction body with local skill-directory hints removed.

OMP renders that context as policy guidance in its prompt. It is explicitly not
a tool grant and cannot enable arbitrary file-system, network, or write access.
OMP still uses the FileNest host-tool gateway for attached-file reads.

The selected harness never owns a second model setting. OMP receives a
short-lived projection of FileNest's global Local Ollama or Cloud API selection,
including the configured model and Thinking state. Its generated model registry
is app-owned and its Cloud API key is supplied only through the isolated child
process environment; the key is not written to the generated registry file.

Assistant messages persist both the response provider and harness kind. Chat
feedback stores the same harness kind, so RAG learning can distinguish Classic
and OMP feedback while producing reusable managed skills.

## Adding another harness

Implement `AgentHarnessAdapter` in a separate adapter module:

```swift
struct ExampleHarnessAdapter: AgentHarnessAdapter {
    let kind: AgentHarnessKind = .custom("example")
    let displayName = "Example Harness"
    var isAvailable: Bool { true }
    var supportedModes: Set<AgentInteractionMode> {
        [.generalChat, .libraryReadOnly]
    }

    func makeEngine(for request: AgentHarnessRequest) throws -> any AgentEngine {
        // Create an AgentEngine for the selected runtime.
    }
}
```

Register the adapter in `AgentHarnessRegistry.builtIn` or in an injected registry
for tests and enterprise builds. Settings and the chat menu derive their choices
from the registry, so adding an adapter does not require another OMP-specific
enum branch. Do not add runtime-specific branching to `ChatService`, `ChatView`,
or `AppState`.

## Current scope

The unified route now covers three read-only chat modes:

- `general-chat` has no FileNest file capability and is sent as a direct user
  request with conversation history.
- `library-read-only` receives the bounded retrieval context prepared by the
  existing index/search pipeline. Citation markers are preserved, while the
  harness is explicitly forbidden from arbitrary file-system or network access.
- `attached-files` receives an immutable, chunked attachment snapshot through
  the FileNest host-tool gateway.

`workspace` is part of the contract so a future adapter can support explicit,
reviewable workspace actions. `AgentWorkspaceSnapshot` is a bounded, read-only
projection of workspace resources; it contains prepared text and labels, not
paths or writable handles. No write-capable workspace tool is exposed by the
current UI or OMP adapter. Classic remains the default provider pipeline and is
the fallback when a selected adapter is unavailable, does not support the mode,
or fails before producing an answer.

## Safety requirements

- Keep `AgentHarnessRequest` capability-bounded and free of live file handles or
  ambient URLs. Prepared library evidence may contain path-like text as
  read-only metadata, but it never grants the harness access to those paths.
- Expose tools through the FileNest gateway rather than enabling ambient runtime
  tools, MCP, LSP, or extension discovery by default.
- Require explicit user approval before adding write-capable workspace tools.
- Preserve cancellation, timeout, partial-output, and shutdown behavior across
  every adapter.
