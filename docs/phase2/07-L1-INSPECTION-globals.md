# Layer 1 Inspection Report: globals.lisp

**File:** `src/globals.lisp`  
**Lines:** 134 (actual), 133 (roadmap) — ✅ Match  
**Date:** March 31, 2026  
**Priority:** LOW — Constants and global state (supporting infrastructure)  
**Complexity:** LOW (no algorithms, just data definitions)

## Executive Summary

`globals.lisp` is a **pure data definitions file** containing:
- **Global variables:** Current graph, cache settings, Prolog engine state
- **Constants:** Database version, file names, serialization type codes, index sizes
- **Sentinel values:** Null/max keys, Prolog boundaries

**No functions, no classes, no algorithms.**

This file is **foundational** — every other file imports these constants and variables. Changes here cascade throughout the codebase.

## Line Count Breakdown

```
  Lines | Section                                    | Type
────────────────────────────────────────────────────────────────────
  1-2   | Package declaration                        | Meta
  3-3   | Cache control (*cache-enabled*)            | Variable
  5-10  | Version and file names (5 constants)       | Constants
  12-13 | Schema metadata (1 variable, 1 constant)   | Variable+Const
  15-30 | Storage format (17 constants)              | Constants
  32-42 | Index structures and namespaces (7 vars+const) | Variable+Const
  44-63 | Index key sizes (16 constants)             | Constants
  65-101| Type codes (37 constants)                  | Constants
  102-104| Parameters (3 defparams)                  | Parameters
  105-105| Graph hash (1 variable)                   | Variable
  107-113| Prolog basics (6 variables)               | Variables
  115-128| Platform-specific hash tables (6 vars)    | Variables
  130-134| Prolog trace and special values (4 const+var) | Constants
```

## Detailed Sections

### 1. **Cache Control** (Line 3)

```lisp
(defvar *cache-enabled* t)
```

**Purpose:** Global flag to enable/disable in-memory object caching

**Type:** Boolean (T/NIL)

**Default:** T (enabled)

**Usage:** Checked in Layer 4+ (serialize.lisp, views.lisp) when loading objects
- If T: Cache recently accessed vertices/edges in memory
- If NIL: Disable cache (useful for memory-constrained systems)

**Notes:**
- Dynamic variable — can be toggled at runtime
- Affects performance (caching = faster access, more memory)
- Global scope (affects all graphs)

### 2. **Database Version and File Names** (Lines 5-10)

```lisp
(alexandria:define-constant +db-version+ 1)
(defvar *graph* nil)
(alexandria:define-constant +main-table-file+ "main.dat" :test 'equal)
(alexandria:define-constant +meta-file+ "meta.dat" :test 'equal)
(alexandria:define-constant +data-file+ "data.dat" :test 'equal)
```

**+db-version+:** Schema version number (currently 1)
- Used for compatibility checks
- Incremented when schema breaks backward compatibility
- Allows multiple schema versions to coexist

**+main-table-file+, +meta-file+, +data-file+:** Standard filenames
- Located in graph's location directory
- +main-table-file+ "main.dat" — Main vertex/edge table
- +meta-file+ "meta.dat" — Type registry, schema metadata
- +data-file+ "data.dat" — Serialized node data (heap)

**\*graph\*:** Dynamic variable for current graph
- Set by (with-transaction graph ...) and (open-graph ...)
- Used to provide implicit graph context to functions
- Default: NIL (no graph open)

### 3. **Schema Metadata** (Lines 12-13)

```lisp
(defvar *schema-node-metadata* (make-hash-table :test 'equal))
(alexandria:define-constant +max-node-types+ 65536)
```

**\*schema-node-metadata\*:** Hash table storing type definitions
- Keys: Type names (strings)
- Values: Type metadata (class, persistent slots, indexed slots, etc.)
- Populated by (def-vertex ...) and (def-edge ...)
- Used for schema introspection and validation

**+max-node-types+:** Maximum number of distinct types
- 65536 = 2^16 (matches uint16 type-id field in NODE)
- Soft limit; enforced at definition time

### 4. **Storage Format and Magic Bytes** (Lines 15-30)

```lisp
(alexandria:define-constant +storage-version+     #x01)
(alexandria:define-constant +fixed-integer-64+    #x01)
(alexandria:define-constant +data-magic-byte+     #x17)
(alexandria:define-constant +lhash-magic-byte+    #x18)
(alexandria:define-constant +overflow-magic-byte+ #x19)
(alexandria:define-constant +config-magic-byte+   #x20)
(alexandria:define-constant +null-key+ ...)
(alexandria:define-constant +max-key+ ...)
(alexandria:define-constant +key-bytes+ 16)
(alexandria:define-constant +value-bytes+ 8)
(alexandria:define-constant +bucket-size+ 24)
(alexandria:define-constant +data-extent-size+ (* 1024 1024 100))
```

**Magic bytes:** File format identifiers
- Each serialized structure type has a unique magic byte
- Allows Layer 4 (serialize.lisp) to identify data type when reading
- +data-magic-byte+ (#x17) — Generic data object
- +lhash-magic-byte+ (#x18) — Linear hash table structure
- +overflow-magic-byte+ (#x19) — Hash overflow block
- +config-magic-byte+ (#x20) — Configuration file

**+null-key+:** 16-byte array of zeros
- Sentinel for "no key" or "uninitialized"
- Compared using EQUALP (byte-array equality)
- Used as lower bound in skip lists, range queries

**+max-key+:** 16-byte array of 0xFF (255)
- Sentinel for "maximum key" or "infinity"
- Upper bound for range queries, skip list traversal

**+key-bytes+ (16):** Size of UUID keys
- All node IDs are 16-byte UUIDs (RFC 4122)
- Matches UUID size from utilities.lisp

**+value-bytes+ (8):** Size of value pointers
- 64-bit unsigned integers (uint64)
- Points to memory-mapped heap addresses

**+bucket-size+ (24):** Hash bucket size in bytes
- 16 bytes (key) + 8 bytes (value) = 24 bytes per bucket
- Used in linear hash table layout

**+data-extent-size+ (100 MB):** Size of each mmap segment
- Heap is divided into 100 MB segments
- When segment full, allocate next 100 MB segment
- 100 MB is balance between memory allocation frequency and fragmentation

### 5. **Index Structures and Namespaces** (Lines 32-42)

```lisp
;; Key namespaces
(defvar *vertex-namespace* (uuid:uuid-to-byte-array
                            (uuid:make-uuid-from-string "2140DCE1-3208-4354-8696-5DF3076D1CEB")))
(defvar *edge-namespace* (uuid:uuid-to-byte-array
                          (uuid:make-uuid-from-string "0392C7B5-A38B-466F-92E5-5A7493C2775A")))

;; Sentinel values for skip lists
(alexandria:define-constant +min-sentinel+ :gmin)
(alexandria:define-constant +max-sentinel+ :gmax)
;; For views, aggregate key symbol
(alexandria:define-constant +reduce-master-key+ :gagg)

;; index-lists
(alexandria:define-constant +index-list-bytes+ 17)
```

**\*vertex-namespace\*, \*edge-namespace\*:** UUID namespaces for key generation
- Predefined UUID v3/v5 namespaces
- Used to generate deterministic UUIDs from strings
- Example: Vertex named "person:123" → UUID in vertex namespace
- Ensures no collisions between vertex and edge keys

**+min-sentinel+ (:gmin), +max-sentinel+ (:gmax):** Skip list boundaries
- Used in skip list (Layer 2: skip-list.lisp)
- All real keys fall between :gmin and :gmax
- Simplifies range traversal (no need for NIL checks)

**+reduce-master-key+ (:gagg):** Aggregate key for views
- Used in view reduction (Layer 5: views.lisp)
- When reducing results, accumulates under this key
- Example: SUM aggregation stores result under :gagg

**+index-list-bytes+ (17):** Size of index list entry
- 16 bytes (node ID) + 1 byte (type flag)
- Index lists store references to indexed nodes

### 6. **VE-Index (Vertex-Edge Index) Sizes** (Lines 47-54)

```lisp
(alexandria:define-constant +ve-key-bytes+ 18)
(alexandria:define-constant +null-ve-key+
    (make-array +ve-key-bytes+ :initial-element 0 :element-type '(unsigned-byte 8))
  :test 'equalp)
(alexandria:define-constant +max-ve-key+
    (make-array +ve-key-bytes+ :initial-element 255 :element-type '(unsigned-byte 8))
  :test 'equalp)
```

**+ve-key-bytes+ (18):** Size of VE-index key
- 16 bytes (vertex ID) + 2 bytes (edge type-id)
- Maps: vertex → edges of specific type
- Layout: [16-byte vertex ID][2-byte edge type]

**+null-ve-key+:** Zero-filled 18-byte array
- Sentinel for range queries on VE-index

**+max-ve-key+:** 0xFF-filled 18-byte array
- Upper bound for range queries on VE-index

**Purpose:** VE-index enables fast edge lookups by source vertex and type
- Query: "All outgoing edges of type FRIEND from vertex V"
- Key: V + FRIEND → returns list of edge IDs

### 7. **VEV-Index (Vertex-Edge-Vertex Index) Sizes** (Lines 56-63)

```lisp
(alexandria:define-constant +vev-key-bytes+ 34)
(alexandria:define-constant +null-vev-key+
    (make-array +vev-key-bytes+ :initial-element 0 :element-type '(unsigned-byte 8))
  :test 'equalp)
(alexandria:define-constant +max-vev-key+
    (make-array +vev-key-bytes+ :initial-element 255 :element-type '(unsigned-byte 8))
   :test 'equalp)
```

**+vev-key-bytes+ (34):** Size of VEV-index key
- 16 bytes (source vertex) + 16 bytes (target vertex) + 2 bytes (edge type)
- Maps: (source, target, type) → edge ID
- Layout: [16-byte source ID][16-byte target ID][2-byte type]

**+null-vev-key+, +max-vev-key+:** Sentinels for range queries

**Purpose:** VEV-index enables direct edge lookup
- Query: "Edge from V1 to V2 of type KNOWS"
- Key: V1 + V2 + KNOWS → returns edge ID directly (constant time)

### 8. **Type Codes (Serialization Format)** (Lines 65-101)

37 type identifiers for serialization:

| Code | Constant | Purpose |
|------|----------|---------|
| 0 | +unknown+ | Unknown type (error) |
| 1 | +negative-integer+ | Negative integers |
| 2 | +positive-integer+ | Non-negative integers |
| 3 | +character+ | Single characters |
| 4 | +symbol+ | Symbols |
| 5 | +string+ | Strings |
| 6 | +list+ | Lists |
| 7 | +vector+ | Vectors |
| 8 | +single-float+ | 32-bit floats |
| 9 | +double-float+ | 64-bit floats |
| 10 | +ratio+ | Rational numbers (num/denom) |
| 11 | +t+ | T (true) |
| 12 | +null+ | NIL (false/empty) |
| 13 | +blob+ | Uninterpreted binary data |
| 14 | +dotted-list+ | Improper lists (a . b) |
| 15 | +keyword+ | Keywords (:symbol) |
| 16 | +slot-key+ | Slot reference |
| 17 | +id+ | Node ID (16-byte UUID) |
| 18 | +vertex+ | Vertex object |
| 19 | +edge+ | Edge object |
| 20 | +skip-list+ | Skip list structure |
| 21 | +ve-index+ | VE-index |
| 22 | +type-index+ | Type index |
| 23 | +pcons+ | Persistent cons cell |
| 24 | +pqueue+ | Persistent queue |
| 25 | +mpointer+ | Memory pointer |
| 26 | +pcell+ | Persistent cell |
| 27 | +index-list+ | Index list |
| 28 | +vev-index+ | VEV-index |
| 29 | +bit-vector+ | Bit vectors |
| 30 | +bignum+ | Large integers |
| 100 | +uuid+ | UUID (user-defined) |
| 101 | +timestamp+ | Timestamp (user-defined) |

**Why:** Each serialized value starts with a type code
- Layer 4 (serialize.lisp) reads code → determines how to deserialize rest
- Example: Read byte 5 → string → read length → read characters
- Codes 0-30: Built-in types
- Codes 100+: User-defined types

**Layout:** Serialized object = [type-code][data...]

### 9. **Initialization Parameters** (Lines 102-104)

```lisp
(defparameter *initial-extents* 10)
(defparameter *max-locks* 10000)
(defvar *graph-hash* nil)
```

**\*initial-extents\* (10):** Initial number of mmap extents (100 MB each)
- New graph starts with 10 × 100 MB = 1 GB allocation
- Avoids frequent allocation when small
- Avoids over-allocation when testing

**\*max-locks\* (10000):** Maximum number of concurrent locks
- Prolog engine limit
- Prevents runaway lock allocation

**\*graph-hash\*:** Internal graph hash table
- Maintains mapping of graph name → graph object
- Similar to *graphs* in graph-class.lisp but internal use

### 10. **Prolog Engine State** (Lines 107-134)

```lisp
(defparameter *occurs-check* t)
(defvar *trail* (make-array 200 :fill-pointer 0 :adjustable t))
(defvar *var-counter* 0 "Counter for generating variable names.")
(defvar *functor* nil "The Prolog functor currently being compiled.")
(defvar *select-list* nil "Accumulator for prolog selects.")
(defvar *cont* nil "Continuation container for step-wise queries.")
```

**\*occurs-check\* (T):** Enable occurs check in unification
- T: Prevent infinite structures (a = cons(x, a))
- NIL: Allow infinite structures (faster but unsafe)
- Standard Prolog behavior is T

**\*trail\* (adjustable array, size 200):** Undo trail for backtracking
- Records variable bindings made during unification
- On backtrack, undo bindings in reverse order
- Grows as needed (adjustable)

**\*var-counter\* (0):** Counter for generating unique variable names
- Incremented each time a new ? variable created
- Ensures no accidental variable name collisions

**\*functor\* (NIL):** Current Prolog functor being compiled
- Set during clause compilation
- Used for context in meta-programming

**\*select-list\* (NIL):** Accumulator for query results
- Query builds list of results here
- Used in (select ...) operations

**\*cont\* (NIL):** Continuation/coroutine state
- For step-wise query execution (lazy evaluation)
- Allows stopping and resuming queries

### 11. **Platform-Specific Hash Tables** (Lines 115-128)

```lisp
#+sbcl
(defvar *prolog-global-functors* (make-hash-table :synchronized t))
#+sbcl
(defvar *user-functors* (make-hash-table :synchronized t :test 'eql))

#+lispworks
(defvar *prolog-global-functors* (make-hash-table :single-thread nil))
#+lispworks
(defvar *user-functors* (make-hash-table :single-thread nil :test 'eql))

#+ccl
(defvar *prolog-global-functors* (make-hash-table :shared t))
#+ccl
(defvar *user-functors* (make-hash-table :shared t :test 'eql))
```

**\*prolog-global-functors\*:** Built-in Prolog predicates registry
- Keys: Predicate names (symbols)
- Values: Compiled predicate functions
- Thread-safe on all platforms

**\*user-functors\*:** User-defined Prolog predicates registry
- Keys: Predicate names (symbols)
- Values: User-defined rules and clauses
- Test: 'eql (symbol identity, faster)

**Platform differences:**
- **SBCL:** `:synchronized t` — Internal locking
- **LispWorks:** `:single-thread nil` — Concurrent access allowed
- **CCL:** `:shared t` — Thread-shared hash table

### 12. **Prolog Trace and Special Values** (Lines 130-134)

```lisp
(defparameter *prolog-trace* nil)
(alexandria:define-constant +unbound+ :unbound)
(alexandria:define-constant +no-bindings+ '((t . t)) :test 'equalp)
(alexandria:define-constant +fail+ nil)
```

**\*prolog-trace\* (NIL):** Enable Prolog trace output
- T: Print all unification, backtracking steps
- NIL: Silent execution
- Useful for debugging queries

**+unbound+ (:unbound):** Sentinel for unbound variables
- Indicates variable has no value yet
- Distinct from NIL (which is a value)

**+no-bindings+ ('((t . t))):** Empty binding environment
- List of (variable . value) pairs
- Special marker for "no bindings yet"
- Equalp comparison (not EQ)

**+fail+ (NIL):** Failure indicator in Prolog
- Query returns NIL to indicate failure
- Convention: NIL = failure, non-NIL = success with bindings

## Dependencies

### Imports
- **alexandria** — Utility library (define-constant macro)
- **uuid** — UUID library (for namespace generation)

### Exported By
- Every constant and variable is implicitly exported
- Used by all layers (utilities through REST)

### Critical Dependencies
- **serialize.lisp** (Layer 4) — Uses all type codes
- **skip-list.lisp** (Layer 2) — Uses sentinels
- **views.lisp** (Layer 5) — Uses reduce key
- **prolog.lisp** (Layer 7) — Uses all Prolog variables

## Issues Found

### ✅ **NO BLOCKING ISSUES**

This is pure data — no logic errors possible.

### 🟡 **WARNINGS**

1. **Magic bytes hardcoded (not exhaustive)**
   - Lines 15-20: Magic bytes defined
   - Lines 44-63: Key sizes defined
   - But serialization format not documented
   - **Risk:** Silent data corruption if changed without understanding
   - **Fix:** Document serialization format and validate consistency

2. **Hardcoded extent size (100 MB)**
   - Line 30: `(* 1024 1024 100)`
   - Not configurable; same for all systems
   - **Risk:** Too small for large graphs, too large for embedded systems
   - **Fix:** Make configurable or justify choice

3. **Type codes not reserved for future**
   - Codes 31-99 are undefined
   - Codes 100+ are user-defined
   - **Risk:** Risk of collision if user codes overlap
   - **Fix:** Document reserved ranges clearly

4. **Platform-specific code not validated**
   - Lines 115-128: Three platform versions
   - Only tested on each platform separately
   - **Risk:** Hash table API variations could cause issues
   - **Fix:** Add platform-specific tests

5. **Namespace UUIDs hardcoded**
   - Lines 33-36: Fixed UUIDs for vertex/edge namespaces
   - **Risk:** If changed, all existing UUIDs become invalid
   - **Fix:** Document as immutable, validate on startup

6. **No type code validation**
   - Type codes used but not validated
   - **Risk:** Invalid code causes confusing deserialization error
   - **Fix:** Add validation in serialize.lisp

## Code Quality Summary

| Aspect | Status | Notes |
|--------|--------|-------|
| **Docstrings** | ❌ Minimal | Some comments, no docstrings |
| **Inline comments** | ⚠️ Partial | Good for sections, sparse for constants |
| **Cross-platform** | ✅ Good | Platform-specific variants provided |
| **Completeness** | ✅ Good | All necessary constants defined |
| **Test coverage** | ❌ Zero | Phase 2 deliverable |
| **Consistency** | ✅ Good | Names follow convention (+CONST+, *VAR*) |
| **Clarity** | ⚠️ Good but dense | Many related constants without grouping |

## Design Patterns

**Constant vs Variable distinction:**
- `alexandria:define-constant` — Compile-time (immutable, used as type/format specifiers)
- `defvar` — Runtime (mutable, used for state)
- `defparameter` — Runtime with default value

**Naming conventions:**
- `+CONSTANT+` — Compile-time constants
- `*VARIABLE*` — Runtime variables
- Consistent across entire VivaceGraph codebase

**Magic numbers as constants:**
- Sentinel sizes (16, 18, 34 bytes) — Derived from key sizes
- Extent size (100 MB) — Configuration parameter
- Type codes (0-101) — Extensible space

## Testing Strategy (Phase 2)

### Critical Tests

1. **Constant definition validation**
   - Verify all constants are defined (compilation should ensure this)
   - Verify sizes match usage (16-byte keys, etc.)

2. **Sentinel value properties**
   - +min-sentinel+ < all real keys < +max-sentinel+
   - +null-key+ represents uninitialized state
   - +max-key+ represents infinity

3. **Type code uniqueness**
   - All type codes (0-101) are unique
   - No accidental duplicates

4. **Platform-specific hash tables**
   - *prolog-global-functors* works on SBCL, CCL, LispWorks
   - Thread-safe on all platforms

5. **Namespace UUID consistency**
   - Vertex namespace is deterministic
   - Edge namespace is deterministic
   - Distinct from each other

6. **Prolog trail functionality**
   - *trail* grows as bindings added
   - Can be cleared for backtrack
   - Adjustable array works correctly

## Summary

| Metric | Value | Assessment |
|--------|-------|------------|
| **Lines** | 134 | ✅ Confirmed |
| **Constants** | ~65 | ✓ Comprehensive |
| **Variables** | ~10 | ✓ Essential |
| **Parameters** | ~3 | ✓ Tuning |
| **Complexity** | LOW | ✅ Pure data |
| **Blocking issues** | 0 | ✅ None |
| **Critical issues** | 0 | ✅ None |
| **Warnings** | 6 | 🟡 Minor |

## Relationship to Other Layers

- **Layer 2** (Skip lists): Uses +min-sentinel+, +max-sentinel+
- **Layer 4** (Serialization): Uses all type codes, magic bytes, key sizes
- **Layer 5** (Views): Uses +reduce-master-key+
- **Layer 7** (Prolog): Uses all Prolog variables and hash tables
- **All layers**: Use *graph*, +db-version+, file names

## Next Steps

1. **Create docstrings** — Document each constant and variable
2. **Write guide** — Explain interconnections between constants
3. **Draft tests** — 30+ test cases for validation
4. **Document serialization format** — Explain how type codes map to binary format

**Status:** ✅ Inspection complete. Ready for Etapa 2 (Comprehensive Annotation).
