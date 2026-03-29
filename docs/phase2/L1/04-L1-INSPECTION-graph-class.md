# Layer 1 Inspection Report: graph-class.lisp

**File:** `src/graph-class.lisp`  
**Lines:** 85 (actual), 84 (roadmap) — ✅ Match  
**Date:** March 31, 2026  
**Priority:** MEDIUM — Graph class definition (infrastructure)  
**Complexity:** MEDIUM (straightforward class definition + registry)

## Executive Summary

`graph-class.lisp` defines the **core GRAPH class** and its two specialized subclasses for replication (MASTER-GRAPH, SLAVE-GRAPH).

**Key components:**
- `*graphs*` — Global registry of open graphs (thread-safe hash table)
- `graph` class — 28 slots defining persistence infrastructure
- `master-graph` — For master-slave replication
- `slave-graph` — For replicating slave nodes
- Predicates and abstract methods for type checking

**Complexity is LOW** despite large number of slots because:
- No MOP metaclass customization (unlike clos.lisp, node-class.lisp)
- No method interception
- No slot property categorization
- Just straightforward CLOS class definitions

## Line Count Breakdown

```
  Lines | Section                                    | Type
────────────────────────────────────────────────────────────────────
  1-1   | Package declaration                        | Meta
  2-9   | *graphs* registry definition (7 lines)     | Code
  10-44 | GRAPH class (28 slots + 34 lines)          | Code
  45-48 | print-object method (4 lines)              | Code
  49-55 | MASTER-GRAPH subclass (5 slots, 7 lines)   | Code
  56-62 | SLAVE-GRAPH subclass (5 slots, 7 lines)    | Code
  63-74 | Predicates (graph-p, master-graph-p, etc)  | Code
  75-81 | Abstract generic methods (6 methods)       | Code
  82-84 | lookup-graph function (2 lines)            | Code
```

## Core Components

### 1. **\*graphs\* Variable** (Lines 3-9)

Global registry of all open graphs (thread-safe hash table).

```lisp
(defvar *graphs*
  #+sbcl
  (make-hash-table :test 'equal :synchronized t)
  #+lispworks
  (make-hash-table :test 'equal :single-thread nil)
  #+ccl
  (make-hash-table :test 'equal :shared t))
```

**Platform-specific threading:**
- **SBCL:** `:synchronized t` — thread-safe hash table
- **LispWorks:** `:single-thread nil` — NOT single-threaded (concurrent access)
- **CCL:** `:shared t` — shared among threads

**Purpose:** 
- Track all open graphs by name
- Lookup graphs by name (see `lookup-graph` function)
- Prevent duplicate graph names

**Example:**
```lisp
(gethash "my-graph" *graphs*)  ; => GRAPH instance or NIL
```

### 2. **GRAPH Class** (Lines 11-44)

**28 slots** organizing all persistence infrastructure:

| Category | Slots | Purpose |
|----------|-------|---------|
| **Identity** | graph-name, graph-open-p, location | Name, status, filesystem path |
| **Transactions** | txn-log, txn-file, txn-lock, transaction-manager | ACID logging and lock |
| **Replication** | replication-key, replication-port, views-lock | Master-slave sync |
| **Vertex/Edge Storage** | vertex-table, edge-table, heap | Where nodes are stored |
| **Indexes** | indexes, ve-index-in, ve-index-out, vev-index, vertex-index, edge-index | Query optimization |
| **Schema** | schema | Type registry (def-vertex, def-edge) |
| **Cache** | cache | In-memory object cache |
| **Views** | views, views-lock | Materialized views (Layer 5) |
| **Statistics** | write-stats, read-stats | Performance monitoring |

**Print method** (Lines 46-48):
```lisp
(defmethod print-object ((graph graph) stream)
  (print-unreadable-object (graph stream :type t :identity t)
    (format stream "~S ~S" (graph-name graph) (location graph))))
```

**Example output:**
```
#<GRAPH "my-graph" "/path/to/graph">
```

### 3. **MASTER-GRAPH Subclass** (Lines 50-55)

**Replication master** — coordinates updates across slave nodes.

| Slot | Purpose |
|------|---------|
| `replication-mbox` | Mailbox for receiving slave updates |
| `replication-listener` | Thread listening for slave connections |
| `stop-replication-p` | Flag to stop replication (graceful shutdown) |
| `slaves` | List of connected slave graphs |
| `slaves-lock` | Lock for thread-safe slave list modification |

**Extends GRAPH** — inherits all 28 slots + adds 5 replication-specific slots.

### 4. **SLAVE-GRAPH Subclass** (Lines 57-62)

**Replication slave** — mirrors data from master.

| Slot | Purpose |
|------|---------|
| `master-host` | Hostname/IP of master node |
| `slave-socket` | Socket connection to master |
| `stop-replication-p` | Flag to stop replication |
| `slave-thread` | Background thread syncing from master |
| `master-txn-id` | Highest transaction ID replicated from master |

**Extends GRAPH** — inherits all 28 slots + adds 5 replication-specific slots.

### 5. **Type Predicates** (Lines 64-74)

Three generics for runtime type checking:

```lisp
(defgeneric graph-p (thing)
  (:method ((graph graph)) graph)
  (:method (thing) nil))

(defgeneric master-graph-p (thing)
  (:method ((graph master-graph)) graph)
  (:method (thing) nil))

(defgeneric slave-graph-p (thing)
  (:method ((graph slave-graph)) graph)
  (:method (thing) nil))
```

**Behavior:** Returns the object if it matches, NIL otherwise.

**Example:**
```lisp
(graph-p "not a graph")         => NIL
(graph-p some-graph-instance)   => some-graph-instance
(master-graph-p some-graph)     => some-graph-instance (if master) or NIL
```

### 6. **Abstract Generic Methods** (Lines 76-81)

Placeholder generics to be implemented in other layers:

```lisp
(defgeneric init-schema (graph))
(defgeneric update-schema (graph-or-name))
(defgeneric snapshot (graph &key &allow-other-keys))
(defgeneric scan-for-unindexed-nodes (graph))
(defgeneric start-replication (graph &key package))
(defgeneric stop-replication (graph))
```

**Notes:**
- No methods defined here (pure stubs)
- Implemented in Layer 3+ (transactions, replication, schema)
- Allow decoupling of graph definition from functionality

### 7. **lookup-graph Function** (Lines 83-84)

```lisp
(defun lookup-graph (name)
  (gethash name *graphs*))
```

**Simple registry lookup** — retrieve graph by name from `*graphs*` hash table.

**Example:**
```lisp
(lookup-graph "production-db")  => GRAPH instance or NIL
```

## Dependencies

### Imports
- **utilities.lisp** → `make-recursive-lock` (from synchronization primitives)
- **globals.lisp** → (implicitly, via other modules)

### Exports / Used By
- **All higher layers** → Must reference GRAPH instances
- **transactions.lisp** (Layer 3) → Uses graph slots (txn-log, transaction-manager)
- **serialize.lisp** (Layer 4) → Uses graph slots (heap, indexes, schema)
- **views.lisp** (Layer 5) → Uses graph slots (views, views-lock)
- **rest.lisp** (Layer 7) → Returns graph info via HTTP

## Complexity Assessment

### ✅ **Simple (No Complex Logic)**
- Straightforward class definitions
- No MOP magic (unlike clos.lisp, node-class.lisp)
- Simple hash table operations
- Predicates are trivial dispatch methods

### ⚠️ **Large (28 slots)**
- GRAPH class is **slot-heavy** (28 slots is a lot!)
- Requires understanding entire persistence architecture to appreciate each slot
- Hard to see relationships between slots from definition alone

### 🟡 **Incomplete (Abstract Methods)**
- 6 generic methods with NO implementations
- Implementations scattered across Layers 3-7
- Makes this file feel like a "forward declaration"

## Issues Found

### 🟡 **WARNINGS**

1. **Large number of slots (28)**
   - Risk: Easy to miss initializing a required slot
   - Risk: Hard to understand what each slot is for
   - **Fix:** Add docstrings to each slot

2. **Platform-specific hash table creation**
   - Requires understanding #+feature syntax
   - Different keyword args per platform
   - **Fix:** Encapsulate in a helper function

3. **Abstract methods with no implementations**
   - 6 generics defined but not implemented here
   - Hard to know when/where they are implemented
   - **Fix:** Add comments referencing implementation locations (Layer 3, 4, 5, etc)

4. **Missing docstrings**
   - GRAPH class has no documentation
   - Slot purposes not explained
   - **Fix:** Add comprehensive docstrings (Phase 2)

5. **Replication code scattered**
   - Master/slave classes defined here
   - Implementation in other files (unknown location)
   - **Fix:** Document replication architecture

## Testing Strategy (Phase 2)

### Critical Tests

1. **Registry functionality**
   - Add graph to *graphs*
   - Lookup by name
   - Verify returns correct instance

2. **Class instantiation**
   - Create GRAPH instance
   - Create MASTER-GRAPH instance
   - Create SLAVE-GRAPH instance
   - Verify all slots accessible

3. **Type predicates**
   - graph-p works on GRAPH and subclasses
   - master-graph-p distinguishes master
   - slave-graph-p distinguishes slave

4. **Print method**
   - Verify print-object produces readable output
   - Format: #<GRAPH "name" "location">

5. **Inheritance**
   - MASTER-GRAPH has all GRAPH slots + 5 replication slots
   - SLAVE-GRAPH has all GRAPH slots + 5 replication slots
   - Subclass slots don't interfere

## Code Quality Summary

| Aspect | Status | Notes |
|--------|--------|-------|
| **Docstrings** | ❌ None | Phase 2 deliverable |
| **Inline comments** | ❌ None | Phase 2 deliverable |
| **Cross-platform** | ✅ Good | Platform-specific hash tables handled |
| **Completeness** | ⚠️ Partial | Abstract methods not implemented here |
| **Test coverage** | ❌ Zero | Phase 2 deliverable |
| **Performance** | ✅ Good | Hash table lookup is O(1) |
| **Complexity** | ⚠️ High | 28 slots to understand |

## Comparison with Previous Files

| File | Type | Complexity | Lines | Slots |
|------|------|-----------|-------|-------|
| utilities.lisp | Utilities | VERY HIGH | 483 | N/A |
| clos.lisp | MOP | VERY HIGH | 89 | 0 |
| node-class.lisp | MOP + categorization | VERY HIGH | 175 | 0 |
| **graph-class.lisp** | **Class definition** | **MEDIUM** | **85** | **28** |

**Easier than previous 3 files** because:
- No MOP magic (no method interception)
- No property inheritance logic
- No class introspection utilities
- Just straightforward class + subclasses + predicates

## Summary

| Metric | Value | Assessment |
|--------|-------|------------|
| **Lines** | 85 | ✅ Confirmed |
| **Classes** | 3 (GRAPH, MASTER-GRAPH, SLAVE-GRAPH) | ✓ |
| **Slots** | 28 (GRAPH) + 5 (MASTER) + 5 (SLAVE) | ⚠️ Many |
| **Methods** | 1 (print-object) + 3 (predicates) + 6 (abstract) | ✓ |
| **Complexity** | MEDIUM | ✅ Easier than previous 3 |
| **Blocking issues** | 0 | ✅ None |
| **Critical issues** | 0 | ✅ None |
| **Warnings** | 5 | 🟡 Minor |

## Next Steps

1. **Create docstrings** — Explain 28 slots, 3 classes, 10 methods
2. **Write guide** — Architecture diagram of slot relationships
3. **Draft tests** — 30+ test cases for classes, predicates, registry
4. **No blocking issues** — Proceed immediately to implementation

**Status:** ✅ Inspection complete. Ready for Etapa 2 (Documentation).

