# Layer 1 Inspection Report: conditions.lisp

**File:** `src/conditions.lisp`  
**Lines:** 84 (actual), 83 (roadmap) — ✅ Match  
**Date:** April 1, 2026  
**Priority:** HIGH — Exception hierarchy (used by all layers)  
**Complexity:** LOW (pure class definitions, no algorithms)

## Executive Summary

`conditions.lisp` defines **10 exception classes** organized into a simple but effective hierarchy for error handling across all VivaceGraph layers.

**Key aspects:**
- **Replication errors:** slave-auth-error
- **Transaction errors:** transaction-error, stale-revision-error
- **Serialization errors:** serialization-error, deserialization-error
- **Index errors:** duplicate-key-error, nonexistent-key-error
- **Node lifecycle:** node-already-deleted-error (base), vertex-already-deleted-error, edge-already-deleted-error
- **View errors:** invalid-view-error, view-lock-error

**Design pattern:** Each exception has:
- Specific slots (context information)
- Custom :report method (human-readable error message)
- Inheritance for specialization (e.g., vertex-already-deleted-error < node-already-deleted-error)

## Line Count Breakdown

```
  Lines | Section                                    | Type
────────────────────────────────────────────────────────────────────
  1-2   | Package declaration                        | Meta
  3-8   | slave-auth-error (replication)             | Exception
  10-14 | transaction-error (ACID)                   | Exception
  16-22 | serialization-error (Layer 4)              | Exception
  24-30 | deserialization-error (Layer 4)            | Exception
  32-38 | stale-revision-error (MVCC)                | Exception
  40-46 | duplicate-key-error (Index)                | Exception
  48-54 | nonexistent-key-error (Index)              | Exception
  56-66 | node-already-deleted-error (lifecycle)     | Exception (base)
  62-63 | vertex-already-deleted-error               | Exception (subclass)
  65-66 | edge-already-deleted-error                 | Exception (subclass)
  68-75 | invalid-view-error (Layer 5)               | Exception
  77-84 | view-lock-error (Layer 5)                  | Exception
```

## Exception Classes (Detailed Analysis)

### 1. **slave-auth-error** (Lines 3-8)

```lisp
(define-condition slave-auth-error (error)
  ((reason :initarg :reason)
   (host :initarg :host))
  (:report (lambda (error stream)
             (with-slots (reason host) error
               (format stream "Slave auth error ~A: ~A." host reason)))))
```

**Layer:** Replication (Layer 6)

**Slots:**
- `reason` — Why authentication failed (string description)
- `host` — Which slave host had the error (hostname or IP)

**Report format:** `"Slave auth error <host>: <reason>."`

**Usage:** When slave fails to authenticate with master during replication

**Example:**
```lisp
(error 'slave-auth-error :host "192.168.1.100" :reason "Invalid replication key")
=> Slave auth error 192.168.1.100: Invalid replication key.
```

**Notes:**
- First exception (replication-specific)
- Inherits from standard `error` class
- Two informative slots for debugging

### 2. **transaction-error** (Lines 10-14)

```lisp
(define-condition transaction-error (error)
  ((reason :initarg :reason))
  (:report (lambda (error stream)
             (with-slots (reason) error
               (format stream "Transaction error: ~A." reason)))))
```

**Layer:** Transactions (Layer 3)

**Slots:**
- `reason` — Description of transaction failure

**Report format:** `"Transaction error: <reason>."`

**Usage:** Generic transaction failure (commit failed, rollback needed, constraint violation, etc.)

**Example:**
```lisp
(error 'transaction-error :reason "Constraint violation: duplicate vertex ID")
=> Transaction error: Constraint violation: duplicate vertex ID.
```

**Notes:**
- Generic transaction errors
- Simple single-slot design
- Intentionally not specialized (covers broad transaction failures)

### 3. **serialization-error** (Lines 16-22)

```lisp
(define-condition serialization-error (error)
  ((instance :initarg :instance)
   (reason :initarg :reason))
  (:report (lambda (error stream)
             (with-slots (instance reason) error
               (format stream "Serialization failed for ~a because of ~a."
                       instance reason)))))
```

**Layer:** Serialization (Layer 4)

**Slots:**
- `instance` — Object being serialized (the data structure that failed)
- `reason` — Why serialization failed (error description)

**Report format:** `"Serialization failed for <instance> because of <reason>."`

**Usage:** When converting object to byte array or mmap fails

**Example:**
```lisp
(error 'serialization-error 
       :instance my-vertex 
       :reason "Unknown field type: custom-type")
=> Serialization failed for #<VERTEX id:...> because of Unknown field type: custom-type.
```

**Notes:**
- Includes the problematic object (for debugging)
- Clear two-part error message (what + why)

### 4. **deserialization-error** (Lines 24-30)

```lisp
(define-condition deserialization-error (error)
  ((instance :initarg :instance)
   (reason :initarg :reason))
  (:report (lambda (error stream)
             (with-slots (instance reason) error
               (format stream "Deserialization failed for ~a because of ~a."
                       instance reason)))))
```

**Layer:** Deserialization (Layer 4)

**Slots:**
- `instance` — Object being deserialized (or partial data)
- `reason` — Why deserialization failed

**Report format:** `"Deserialization failed for <instance> because of <reason>."`

**Usage:** When converting bytes/mmap back to object fails

**Example:**
```lisp
(error 'deserialization-error 
       :instance "corrupted-byte-array" 
       :reason "Invalid type code: 255")
=> Deserialization failed for corrupted-byte-array because of Invalid type code: 255.
```

**Notes:**
- Parallel to serialization-error
- Inverse operation (reading instead of writing)
- Same slot structure for symmetry

### 5. **stale-revision-error** (Lines 32-38)

```lisp
(define-condition stale-revision-error (error)
  ((instance :initarg :instance)
   (current-revision :initarg :current-revision))
  (:report (lambda (error stream)
             (with-slots (instance current-revision) error
               (format stream "Attempt to update stale revision ~S of ~S."
                       instance current-revision)))))
```

**Layer:** Transactions/MVCC (Layer 3)

**Slots:**
- `instance` — Object being updated
- `current-revision` — Revision number that was already updated

**Report format:** `"Attempt to update stale revision <revision> of <instance>."`

**Usage:** Write conflict in MVCC snapshot isolation
- User transaction saw revision N
- Another transaction updated to revision N+1
- User tries to update based on N (stale)

**Example:**
```lisp
(error 'stale-revision-error 
       :instance my-vertex 
       :current-revision 5)
=> Attempt to update stale revision 5 of #<VERTEX id:...>.
```

**Notes:**
- Critical for MVCC correctness
- Indicates serialization conflict
- User should retry transaction

### 6. **duplicate-key-error** (Lines 40-46)

```lisp
(define-condition duplicate-key-error (error)
  ((instance :initarg :instance)
   (key :initarg :key))
  (:report (lambda (error stream)
             (with-slots (instance key) error
               (format stream "Duplicate key ~S in ~S."
                       key instance)))))
```

**Layer:** Indexing (Layer 2/4)

**Slots:**
- `instance` — Which index/table received duplicate
- `key` — The duplicate key value

**Report format:** `"Duplicate key <key> in <instance>."`

**Usage:** Attempting to insert key that already exists in index

**Example:**
```lisp
(error 'duplicate-key-error 
       :instance type-index 
       :key vertex-id)
=> Duplicate key #(0xAB 0xCD...) in #<TYPE-INDEX>.
```

**Notes:**
- Affects constraints (UNIQUE indexes)
- Signals constraint violation

### 7. **nonexistent-key-error** (Lines 48-54)

```lisp
(define-condition nonexistent-key-error (error)
  ((instance :initarg :instance)
   (key :initarg :key))
  (:report (lambda (error stream)
             (with-slots (instance key) error
               (format stream "Nonexistent key ~S in ~S."
                       key instance)))))
```

**Layer:** Indexing (Layer 2/4)

**Slots:**
- `instance` — Which index/table being queried
- `key` — The missing key

**Report format:** `"Nonexistent key <key> in <instance>."`

**Usage:** Trying to delete/update a key that doesn't exist

**Example:**
```lisp
(error 'nonexistent-key-error 
       :instance ve-index 
       :key edge-id)
=> Nonexistent key #(0xDE 0xAD...) in #<VE-INDEX>.
```

**Notes:**
- Parallel to duplicate-key-error
- Indicates lookup failure
- May signal data corruption if unexpected

### 8. **node-already-deleted-error** (Lines 56-60)

```lisp
(define-condition node-already-deleted-error (error)
  ((node :initarg :node))
  (:report (lambda (error stream)
             (with-slots (node) error
               (format stream "Node ~A already deleted" node)))))
```

**Layer:** Node lifecycle (Layer 3/4)

**Slots:**
- `node` — The node that was already deleted

**Report format:** `"Node <node> already deleted"`

**Usage:** Attempting to delete a node that's already marked as deleted

**Example:**
```lisp
(error 'node-already-deleted-error :node my-vertex)
=> Node #<VERTEX id:123abc...> already deleted
```

**Notes:**
- Base class for vertex/edge specializations
- Soft-delete scenario (marked deleted, not removed)
- Simple single-slot design

### 9. **vertex-already-deleted-error** (Lines 62-63)

```lisp
(define-condition vertex-already-deleted-error (node-already-deleted-error)
  ())
```

**Layer:** Node lifecycle (Layer 3/4)

**Inheritance:** Subclass of `node-already-deleted-error`

**Slots:** Inherited from parent (just `node`)

**Usage:** Specific case of deleting a vertex that's already deleted

**Example:**
```lisp
(error 'vertex-already-deleted-error :node my-vertex)
=> Node #<VERTEX id:...> already deleted
```

**Notes:**
- Specialization of node-already-deleted-error
- Allows catch-by-type for vertex-specific handling
- No additional slots (inherits from parent)

### 10. **edge-already-deleted-error** (Lines 65-66)

```lisp
(define-condition edge-already-deleted-error (node-already-deleted-error)
  ())
```

**Layer:** Node lifecycle (Layer 3/4)

**Inheritance:** Subclass of `node-already-deleted-error`

**Slots:** Inherited from parent (just `node`)

**Usage:** Specific case of deleting an edge that's already deleted

**Example:**
```lisp
(error 'edge-already-deleted-error :node my-edge)
=> Node #<EDGE id:...> already deleted
```

**Notes:**
- Parallel to vertex-already-deleted-error
- Same inheritance pattern
- Enables differentiation in catch handlers

### 11. **invalid-view-error** (Lines 68-75)

```lisp
(define-condition invalid-view-error (error)
  ((class-name :initarg :class-name)
   (view-name :initarg :view-name))
  (:report (lambda (error stream)
             (with-slots (class-name view-name) error
               (format stream
                       "No such graph view: ~A/~A"
                       class-name view-name)))))
```

**Layer:** Views (Layer 5)

**Slots:**
- `class-name` — Class the view is defined on (e.g., "PERSON")
- `view-name` — Name of the missing view (e.g., "AGE_DISTRIBUTION")

**Report format:** `"No such graph view: <class-name>/<view-name>"`

**Usage:** Trying to invoke a view that doesn't exist

**Example:**
```lisp
(error 'invalid-view-error 
       :class-name "PERSON" 
       :view-name "MISSING_VIEW")
=> No such graph view: PERSON/MISSING_VIEW
```

**Notes:**
- Two-level namespace (class/view name)
- Clear identification of missing resource

### 12. **view-lock-error** (Lines 77-84)

```lisp
(define-condition view-lock-error (error)
  ((message :initarg :message))
  (:report (lambda (error stream)
             (with-slots (message) error
               (format stream
                       "View locking error: '~A'"
                       message)))))
```

**Layer:** Views (Layer 5)

**Slots:**
- `message` — Description of the locking error

**Report format:** `"View locking error: '<message>'"`

**Usage:** Deadlock, lock timeout, or other locking problem in view operations

**Example:**
```lisp
(error 'view-lock-error :message "Deadlock detected in view reduction")
=> View locking error: 'Deadlock detected in view reduction'
```

**Notes:**
- Generic locking error
- Simple message-only design
- Handles various lock-related failures

## Exception Hierarchy

```
error (CL standard)
├─ slave-auth-error
├─ transaction-error
├─ serialization-error
├─ deserialization-error
├─ stale-revision-error
├─ duplicate-key-error
├─ nonexistent-key-error
├─ node-already-deleted-error
│  ├─ vertex-already-deleted-error
│  └─ edge-already-deleted-error
├─ invalid-view-error
└─ view-lock-error
```

**Key insight:** Flat hierarchy (all inherit directly from `error`) with one exception:
- `node-already-deleted-error` is a base class
- `vertex-already-deleted-error` and `edge-already-deleted-error` are specializations

This enables:
- Catch all deletion errors: `(catch 'node-already-deleted-error ...)`
- Catch vertex-specific: `(catch 'vertex-already-deleted-error ...)`
- Catch all errors: `(catch 'error ...)`

## Layer Distribution

| Layer | Exceptions | Count |
|-------|-----------|-------|
| **Layer 3 (Transactions)** | transaction-error, stale-revision-error | 2 |
| **Layer 4 (Serialization)** | serialization-error, deserialization-error | 2 |
| **Layer 2/4 (Indexing)** | duplicate-key-error, nonexistent-key-error | 2 |
| **Layer 3/4 (Node lifecycle)** | node-already-deleted-error, vertex-already-deleted-error, edge-already-deleted-error | 3 |
| **Layer 5 (Views)** | invalid-view-error, view-lock-error | 2 |
| **Layer 6 (Replication)** | slave-auth-error | 1 |
| **Total** | | **12** |

## Design Patterns

### Pattern 1: Slots + :report method

Every exception follows:
```lisp
(define-condition NAME (error)
  ((slot1 :initarg :slot1)
   (slot2 :initarg :slot2))
  (:report (lambda (error stream)
             (with-slots (slot1 slot2) error
               (format stream "message ~A ~A" slot1 slot2)))))
```

**Advantage:** 
- User can access raw slots programmatically
- :report provides user-friendly string message
- Both available simultaneously

### Pattern 2: Context information

Each exception includes enough context to:
- Identify what failed (instance/node/key)
- Understand why (reason/type/revision)

**Example:** `stale-revision-error` includes:
- `instance` (WHAT: which node)
- `current-revision` (WHY: what revision is now current)

### Pattern 3: Specialization for type-specific handling

```lisp
(node-already-deleted-error)
├─ (vertex-already-deleted-error)  ; Can catch vertex-specific
└─ (edge-already-deleted-error)    ; Can catch edge-specific
```

Enables:
```lisp
(catch 'node-already-deleted-error (delete-vertex v))    ; Catches both
(catch 'vertex-already-deleted-error (delete-vertex v))  ; Catches vertex-only
```

## Issues Found

### ✅ **NO BLOCKING ISSUES**

Exception definitions are syntactically correct and complete.

### 🟡 **WARNINGS**

1. **No class documentation comments**
   - Each exception has a :report method
   - But no docstring explaining when to use
   - **Fix:** Add docstrings (Phase 2)

2. **Report messages could be more consistent**
   - Some use "error" in message: "Slave auth error"
   - Others don't: "Serialization failed"
   - Minor inconsistency in wording

3. **No error recovery hints**
   - Exceptions tell you WHAT went wrong
   - But not how to recover
   - Example: stale-revision-error should hint "retry transaction"
   - **Fix:** Add documentation in guide

4. **Hierarchy could be deeper**
   - All index errors (duplicate, nonexistent) inherit from `error`
   - Could have `index-error` base class
   - Current design is simpler but less structured
   - **Note:** This is a design choice, not a bug

5. **No sentinel exceptions for common operations**
   - Missing: `no-transaction-in-progress` (exported but not defined here)
   - Missing: `prolog-error` (likely defined elsewhere)
   - **Note:** Some exceptions may be in other files

## Code Quality Summary

| Aspect | Status | Notes |
|--------|--------|-------|
| **Docstrings** | ❌ None | Phase 2 deliverable |
| **Inline comments** | ❌ None | Phase 2 deliverable |
| **Completeness** | ✅ Good | 12 exceptions covering all layers |
| **Consistency** | ✅ Good | Pattern followed for all exceptions |
| **Error messages** | ✅ Good | Clear, informative :report output |
| **Hierarchy design** | ✅ Good | Simple and practical (flat + one subclass) |
| **Test coverage** | ❌ Zero | Phase 2 deliverable |

## Testing Strategy (Phase 2)

### Critical Tests

1. **Exception instantiation**
   - Each exception can be created with required slots
   - All slots accessible via slot-value

2. **Report messages**
   - :report method produces correct string format
   - Includes all slot values

3. **Hierarchy**
   - vertex-already-deleted-error IS-A node-already-deleted-error
   - Can catch by parent type
   - Specialized catch handlers work

4. **Integration**
   - Exceptions can be raised with (error ...)
   - Can be caught with (catch ...)
   - Condition handlers work correctly

## Summary

| Metric | Value | Assessment |
|--------|-------|------------|
| **Lines** | 84 | ✅ Confirmed |
| **Exception classes** | 12 | ✓ Comprehensive |
| **Inheritance levels** | 2 (flat + 1 subclass) | ✓ Simple but sufficient |
| **Slots per exception** | 1-2 (average 1.5) | ✓ Minimal, focused |
| **Blocking issues** | 0 | ✅ None |
| **Critical issues** | 0 | ✅ None |
| **Warnings** | 5 | 🟡 Minor (documentation) |

## Relationship to Other Layers

- **Layer 2 (Indexing):** Raises duplicate-key-error, nonexistent-key-error
- **Layer 3 (Transactions):** Raises transaction-error, stale-revision-error, node deletion errors
- **Layer 4 (Serialization):** Raises serialization-error, deserialization-error
- **Layer 5 (Views):** Raises invalid-view-error, view-lock-error
- **Layer 6 (Replication):** Raises slave-auth-error
- **All layers:** Catch/handle these exceptions in error handlers

## Design Strengths

1. **Focused scope** — Each exception represents one specific error
2. **Rich context** — Slots provide debugging information
3. **User-friendly** — :report methods create readable messages
4. **Flexible hierarchy** — Can catch by parent or specific type
5. **Minimal overhead** — Only what's necessary, nothing extra

## Next Steps

1. **Create docstrings** — Document each exception (purpose, when raised, how to recover)
2. **Write guide** — Explain hierarchy and usage patterns
3. **Draft tests** — 30+ test cases for instantiation, reporting, hierarchy
4. **Create examples** — Show how to raise and catch each exception

**Status:** ✅ Inspection complete. Ready for Etapa 2 (Comprehensive Annotation with Docstrings & Inline Comments).

