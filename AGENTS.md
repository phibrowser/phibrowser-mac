This document defines both general engineering rules and
Phi Browser–specific architectural constraints.

All code, comments, and documentation must be written in English.
No Chinese text is allowed except inside i18n translation files.

---

# Core Engineering Philosophy

Stability over perfection.  
Consistency over novelty.  
Clarity over abstraction.  

Long-term architectural stability is more important than local optimization.

---

# Pattern Stability Rule

Do NOT introduce new architectural patterns unless:

1. The existing pattern clearly fails to solve the problem
2. The limitation is explicitly identified
3. The new pattern replaces the old one (not coexist with it)

Avoid parallel patterns for the same responsibility.
Architectural drift is more dangerous than small imperfections.

---

# Ownership Rule

Every module must have a clear responsibility boundary.

Before adding logic to a file or module, verify:

- Is this responsibility already owned elsewhere?
- Does this violate separation of concerns?
- Is this the correct architectural layer?

Avoid cross-layer leakage.

---

# Complexity Control

Do not introduce abstraction unless it:

- Removes real duplication
- Clarifies ownership
- Reduces measurable complexity

Avoid:

- Base classes without multiple concrete implementations
- Protocols with a single implementation
- Indirection without a clear benefit
- “Future-proofing” abstractions

Premature abstraction increases long-term maintenance cost.

---

# Refactor Discipline

Architectural refactoring requires explicit intent.

Do NOT:

- Restructure core folders
- Rename foundational components
- Change ownership boundaries
- Move responsibilities across layers

Unless explicitly instructed.

Silent architectural shifts are prohibited.

---

# Git Rules

## Commit Messages
- Single concise summary line
- Describe what changed, not how
- No bullet lists
- No long explanations

## Commit Timing
- Do NOT commit immediately after making changes
- Wait for explicit instruction before committing

---

# Documentation Rules

Documentation must support engineering stability, not create overhead.

Document only:

- Architectural decisions
- Non-obvious behavior
- Integration boundaries
- Security-sensitive logic

Update documentation when:

- Architecture changes
- Public APIs change
- Core business rules change

Never allow documentation to diverge from actual behavior.

---

# Phi Browser — Project-Specific Architecture

## System Nature

Phi Browser is a hybrid system:

- Native macOS client (Swift + AppKit)
- Embedded custom Chromium framework (Phi Framework.framework)

Clear separation between these layers is critical.

---

# Architectural Boundaries

## UI Layer
- AppKit-based macOS UI
- Owns presentation and user interaction only
- Must not contain Chromium internal logic

## Chromium Integration Layer
- Interacts with Phi Framework.framework
- Acts as boundary adapter between UI and Chromium
- Must remain isolated from presentation logic

Do not blur these boundaries.

---

# State Model

## BrowserState
- Exactly one instance per window
- Owns tab state and browser lifecycle
- Window-scoped responsibility only

## AppState
- Application-scoped UI state only
- Must not contain per-window logic

Rules:

- Do not introduce additional global state containers
- Do not move window responsibility into AppState
- Do not create parallel state hierarchies

---

# Networking Constraint

All API communication must go through:

Sources/Networking/APIClient.swift

Rules:

- No direct URLSession usage outside networking layer
- No parallel networking abstractions
- Authentication logic must remain centralized

---

# Architectural Stability Rules

- Do not mix lifecycle control with presentation logic
- Do not allow Chromium concepts to leak into UI naming
- Keep ownership explicit and traceable
- Favor predictable state flow over reactive complexity

---

# Stability Enforcement Principle

Do not optimize architecture for theoretical elegance.
Optimize for predictability, ownership clarity, and team stability.

Consistency across time is more important than short-term improvement.