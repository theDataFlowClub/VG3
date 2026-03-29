# Layer 1: utilities.lisp — Core Utilities Guide

**File:** `src/utilities.lisp`  
**Lines:** 483  
**Priority:** HIGH — Everything in VivaceGraph depends on this  
**Status:** Phase 1 (documentation), Phase 2 (tests pending)

## Purpose

`utilities.lisp` is the **foundation of Layer 1**. It provides:

1. **Cross-type comparison** — `less-than` and `greater-than` generics that define a total order on all Lisp values (numbers, strings, symbols, UUIDs, timestamps, lists)
2. **UUID generation & parsing** — fast random ID generation and string↔byte conversions
3. **Cross-platform primitives** — time, locks, memory inspection across SBCL, CCL, LispWorks
4. **List/tree utilities** — flatten, find-anywhere, search operations
5. **Synchronization** — locks, semaphores, read-write locks
6. **Type checking & array creation** — proper-listp, make-byte-vector

**Without utilities.lisp, nothing else runs.** Every layer depends on at least one function here.

## Key Concepts

### 1. **Cross-Type Comparison (`less-than` / `greater-than`)**

These generics define a **total order on all Lisp types**, enabling mixed-type indexes in skip-lists.

**Order hierarchy:**
```
+min-sentinel+ < list < null < t < number < symbol < string < timestamp < uuid < +max-sentinel+
```

**Why?**
- VivaceGraph allows graph properties with any type (e.g., string keys and numeric values in the same index)
- Skip-lists need a total order to insert/find correctly
- `less-than` and `greater-than` provide it

**Behavior by type:**

| Comparison | Rule | Example |
|------------|------|---------|
| Same type | Type-specific operator | `(less-than 1 2)` → `(<1 2)` → T |
| number vs symbol | number < symbol | `(less-than 5 'x)` → T |
| string vs symbol | string < symbol | `(less-than "a" 'a)` → T |
| list vs anything | list is first | `(less-than '(a) 'x)` → T |
| +max-sentinel+ vs anything | max > everything | `(less-than 999 +max-sentinel+)` → T |

**50+ methods defined.** Used in:
- `skip-list.lisp` (key comparison in tree nodes)
- `vev-index.lisp` (index lookups)
- Any generic index by type or value

### 2. **UUID Generation & Parsing**

VivaceGraph uses **16-byte unsigned-byte vectors** as the canonical UUID representation (fast, persistent, binary-friendly).

| Function | Purpose | Input | Output |
|----------|---------|-------|--------|
| `gen-id` | Generate random v4 UUID | none | 16-byte vector |
| `read-uuid-from-string` | Parse `"550e8400-..."` → uuid:uuid | string | uuid:uuid object |
| `read-id-array-from-string` | Parse `"550e8400-..."` → byte-array | string | 16-byte vector |
| `parse-uuid-block` | Helper: hex block → int | string, start, end | integer |

**Example workflow:**

```lisp
;; Generate a new vertex ID
(let ((id (gen-id)))  ; => #(245 18 99 ... 77)  [16 random bytes]
  (save-vertex g "mytype" id))

;; Parse user input
(let* ((user-str "550e8400-e29b-41d4-a716-446655440000")
       (id-array (read-id-array-from-string user-str)))
  (lookup-vertex g id-array))
```

**Note:** The **byte order** in `read-id-array-from-string` is critical. It follows RFC 4122 layout:
- Bytes 0-3: time-low (first 8 hex chars)
- Bytes 4-5: time-mid (chars 9-12)
- Bytes 6-7: time-high-and-version (chars 13-16)
- Bytes 8-9: clock-seq (chars 17-20)
- Bytes 10-15: node/MAC (chars 21-32)

### 3. **Time Primitives (Cross-Platform)**

VivaceGraph must work on **SBCL, CCL, LispWorks**, and each has different time APIs.

| Function | Purpose | Notes |
|----------|---------|-------|
| `gettimeofday()` | Current Unix time with microsecond precision | SBCL: native, CCL: FFI, LispWorks: FFI |
| `universal-to-unix-time(t)` | CL universal-time → Unix time | Subtract epoch offset (2208988800) |
| `unix-to-universal-time(t)` | Unix time → CL universal-time | Add epoch offset |
| `get-unix-time()` | Current Unix timestamp | Uses `get-universal-time()` (loses µs precision) |

**Why two formats?**
- CL universal-time: seconds since 1900-01-01 (large numbers)
- Unix time: seconds since 1970-01-01 (compact, widely used)
- VivaceGraph transaction logs use Unix time for compactness

**Conversion cached:**
```lisp
*unix-epoch-difference* = 2208988800  ; Pre-computed, never changes
```

### 4. **Synchronization Primitives (Cross-Platform)**

VivaceGraph uses locks for concurrent access. Implementations vary by Lisp.

| Macro/Function | SBCL | CCL | LispWorks | Notes |
|---|---|---|---|---|
| `with-lock` | sb-thread:with-recursive-lock | do-with-lock (custom) | mp:with-lock | Universal lock macro |
| `make-semaphore` | sb-thread:make-semaphore | ccl:make-semaphore | mp:make-semaphore | Counting semaphore |
| `with-locked-hash-table` | sb-ext:with-locked-hash-table | no-op | no-op | Only SBCL needs explicit locking |
| `with-read-lock` (CCL only) | N/A | ccl:with-read-lock | N/A | Multiple concurrent readers |
| `with-write-lock` (CCL only) | N/A | ccl:with-write-lock | N/A | Exclusive writer access |
| `make-rw-lock` (CCL only) | N/A | ccl:make-read-write-lock | N/A | Reader-writer lock |

**Example usage:**

```lisp
;; Simple exclusive lock
(with-lock (node-lock)
  (update-node-data node))

;; With timeout (CCL only, ignored on SBCL/LispWorks)
(with-lock (critical-lock :whostate "writing txn log" :timeout 5.0)
  (append-to-txn-log entry))

;; Read-write lock (CCL only)
(with-read-lock (graph-rw-lock)
  (let ((result (lookup-vertex g id)))
    result))  ; Multiple threads can do this simultaneously
```

**Critical:** The `with-lock` macro is used everywhere in Layer 3 (transactions) and Layer 4 (data structures). Must be reliable across all platforms.

### 5. **List & Tree Utilities**

Common operations for searching and manipulating nested structures.

| Function | Purpose | Example |
|----------|---------|---------|
| `flatten(x)` | Recursively flatten nested lists | `(flatten '(a (b (c)))) → (A B C)` |
| `find-anywhere(item tree)` | Depth-first search for item | `(find-anywhere 'x '(a (b x c))) → X` |
| `find-if-anywhere(pred tree)` | Find first atom matching predicate | `(find-if-anywhere #'numberp '(a (1 b))) → 1` |
| `unique-find-anywhere-if(pred tree)` | Find all matching atoms, no duplicates | `(unique-find-anywhere-if #'oddp '(1 (2 1 (3 2)) 1)) → (1 3)` |
| `find-all(item seq :test)` | Find all matching elements in sequence | `(find-all 'a '(a x a y a)) → (A A A)` |
| `last1(list)` | Last element (not cons cell) | `(last1 '(a b c)) → C` |
| `proper-listp(x)` | Check for proper (non-dotted) list | `(proper-listp '(a . b)) → NIL` |
| `length=1(list)` | Exactly one element? | `(length=1 '(x)) → T` |

**Note:** These are all from Norvig's PAIP (Paradigms of AI Programming). VivaceGraph inherits them for Prolog compilation and term rewriting.

### 6. **Array & Memory Utilities**

| Function | Purpose | Example |
|----------|---------|---------|
| `make-byte-vector(n)` | Create zero-filled byte array | `(make-byte-vector 16) → #(0 0 ... 0)` |
| `free-memory()` | Available dynamic memory in bytes | `(free-memory) → 1024000000` |
| `print-byte-array(stream array)` | Format directive for bytes | `(format t "~@/print-byte-array/" bytes)` |

**Note on free-memory():**
- SBCL: `dynamic-space-size - dynamic-usage`
- CCL: `%freebytes` (direct)
- LispWorks: TODO (not yet implemented)

Used in Layer 3 (garbage collection) to decide when to trigger cleanup.

### 7. **Macro Utilities**

| Macro | Purpose | Example |
|-------|---------|---------|
| `with-gensyms(syms &body)` | Create N gensyms at once | `(with-gensyms (x y) ...)` |

Used in macro writing to avoid variable capture. Standard Lisp pattern from Graham's *On Lisp*.

### 8. **Debugging Utilities**

| Function | Purpose |
|----------|---------|
| `dbg(fmt &rest args)` | Printf-style debug output |
| `dump-hash(table)` | Pretty-print hash table contents |
| `ignore-warning(condition)` | Suppress compiler warnings |

## Dependencies

### Internal (within Layer 1)
- **globals.lisp** — Uses `+min-sentinel+`, `+max-sentinel+` constants
- **conditions.lisp** — Error signaling (not heavily used in utilities.lisp itself)

### External (libraries)
- **uuid** (Quicklisp) — `uuid:make-v4-uuid`, `uuid:uuid-to-byte-array`, `uuid:print-bytes`, `uuid:uuid` class
- **timestamp** (Quicklisp) — `timestamp<`, `timestamp>`, `timestamp` class
- **SBCL-specific:**
  - `sb-ext:get-time-of-day`, `sb-kernel::dynamic-space-size`, `sb-kernel:dynamic-usage`
  - `sb-thread:with-recursive-lock`, `sb-thread:make-semaphore`
  - `sb-ext:with-locked-hash-table`
- **CCL-specific:**
  - `ccl:external-call`, `ccl:rlet`, `ccl:pref`, `ccl:%null-ptr`
  - `ccl:try-lock`, `ccl:process-wait-with-timeout`, `ccl:grab-lock`, `ccl:with-lock-grabbed`
  - `ccl:make-read-write-lock`, `ccl:with-read-lock`, `ccl:with-write-lock`
  - `ccl::%freebytes`, `ccl:make-semaphore`
- **LispWorks-specific:**
  - `fli:define-c-struct`, `fli:define-c-typedef`, `fli:define-foreign-function`
  - `fli:with-dynamic-foreign-objects`, `fli:foreign-slot-value`, `fli:*null-pointer*`
  - `mp:with-lock`, `mp:make-semaphore`

## Who Depends on This?

**Every file in VivaceGraph uses at least one function from utilities.lisp:**

- **node-class.lisp** → `less-than` (for ordering in metaclass slots)
- **clos.lisp** → `with-lock`, `dbg`
- **graph-class.lisp** → `gen-id` (UUID generation)
- **uuid.lisp** → `read-uuid-from-string`, `read-id-array-from-string`
- **skip-list.lisp** → `less-than`, `greater-than` (core comparison)
- **linear-hash.lisp** → `less-than`, `with-lock`
- **transactions.lisp** → `get-unix-time`, `with-lock`
- **serialize.lisp** → `make-byte-vector`, `new-interned-symbol`
- **prologc.lisp** → `find-all`, `unique-find-anywhere-if`, `flatten`
- **rest.lisp** → `dbg`, `gen-id`

## Suggested Improvements / Issues

### 1. **Incomplete Cross-Platform Support**
- **free-memory()** — No LispWorks implementation (TODO comment exists)
- **gettimeofday()** — Untested on Windows (CCL/SBCL)
- **Solution:** Add LispWorks implementation, test on Windows

### 2. **Hash Functions Unused**
- **djb-hash()** and **fast-djb-hash()** — Both marked "Not used"
- **Solution:** Either remove or integrate with Layer 4 (serialize.lisp) if needed for checksumming

### 3. **Inefficient Recursion in key-vector<**
```lisp
(key-vector< (subseq v1 1) (subseq v2 1))  ; Creates new vectors at each step!
```
- **Problem:** O(n) space complexity for vectors of length n
- **Solution:** Use loop with index instead:
```lisp
(defun key-vector< (v1 v2 &optional (i1 0) (i2 0))
  (cond ((= i1 (length v1)) nil)  ; v1 exhausted, not <
        ((< (aref v1 i1) (aref v2 i2)) t)
        ((= (aref v1 i1) (aref v2 i2)) (key-vector< v1 v2 (1+ i1) (1+ i2)))
        (t nil)))
```

### 4. **CCL Lock API Incomplete**
- **acquire-write-lock()** and **release-write-lock()** have `declare (ignore wait-p)` but wait-p isn't a parameter
- **Solution:** Fix signatures or document as internal

### 5. **gettimeofday() Return Type Inconsistent**
- **SBCL:** Returns float (seconds + fractional microseconds)
- **CCL:** Returns two values (seconds, microseconds separately)
- **Current code** appears to merge them for SBCL but not CCL
- **Solution:** Normalize to single float return on all platforms

### 6. **no-op Macros Confusing**
- **with-locked-hash-table**, **with-read-lock**, **with-write-lock** are no-ops on some platforms
- **Solution:** Add compiler warnings or docstrings warning about limited platform support

## Testing Strategy (Phase 2, Layer 1)

See `tests/layer1/test-utilities.lisp` for comprehensive tests covering:

1. **Less-than / Greater-than**
   - Same-type comparisons (numbers, strings, symbols)
   - Cross-type comparisons (establish order)
   - Sentinel values (+min-sentinel+, +max-sentinel+)
   - Lists (recursive comparison)

2. **Key vectors**
   - Lexicographic ordering
   - Empty vectors
   - Prefix equality

3. **UUID**
   - Round-trip: string → uuid:uuid → byte-array → string
   - Random generation (no collisions in 1000 tries)
   - Byte order correctness

4. **Time**
   - Conversion round-trips: unix ↔ universal
   - gettimeofday() returns sensible values

5. **Locks**
   - Single-threaded: no deadlock
   - Multi-threaded: concurrent readers, exclusive writer

6. **List utilities**
   - flatten, find-anywhere, find-all (correctness, no side effects)

## Code Quality Summary

| Aspect | Status | Notes |
|--------|--------|-------|
| Docstrings | ❌ None | Upstream code; added in ANNOTATED version |
| Inline comments | ⚠️ Minimal | Complex sections (less-than methods, UUID parsing) need explanation |
| Cross-platform | ✅ Good | SBCL, CCL, LispWorks all supported |
| Completeness | ⚠️ Partial | Missing: Windows gettimeofday, LispWorks free-memory |
| Test coverage | ❌ Zero | Phase 2 deliverable |
| Performance | ✅ Good | Most functions O(1) or O(n); key-vector< could be optimized |
| Dependencies | ✅ Good | uuid, timestamp libraries are stable Quicklisp packages |

## Files in This Delivery

- **utilities-ANNOTATED.lisp** — Source with docstrings and inline comments
- **layer1-utilities-guide.md** — This file (human-readable summary)
- **test-utilities.lisp** — Comprehensive test suite (Phase 2)
- **diagrams/layer1/dependencies.md** — Dependency graph including utilities.lisp

## Next Steps

1. **Validate** docstrings by running code examples
2. **Create unit tests** (test-utilities.lisp)
3. **Fix suggested improvements** (especially key-vector< optimization)
4. **Add LispWorks free-memory** implementation
5. **Move to clos.lisp** (Layer 1, next file)
