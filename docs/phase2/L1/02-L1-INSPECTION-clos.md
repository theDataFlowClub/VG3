# Layer 1 Inspection Report: clos.lisp

**File:** `src/clos.lisp`  
**Lines:** 89 (actual), 88 (roadmap) — ✅ Match  
**Date:** March 31, 2026  
**Priority:** HIGH — MOP intercepts ALL slot operations  
**Complexity:** VERY HIGH (despite small size)

## File Summary

```
clos.lisp - Meta-Object Protocol Implementation

Core Purpose:
  Intercept ALL slot read/write operations on NODE instances
  Route non-meta slots through persistent data store (plist in %data)
  Trigger transaction enlistment on write
  
Structure:
  Lines 1-2     : Package declaration (1 line)
  Lines 3-5     : *meta-slots* definition (3 lines)
  Lines 7-8     : graph-class metaclass (2 lines)
  Lines 10-12   : validate-superclass method (3 lines)
  Lines 14-23   : Slot definition classes (10 lines)
  Lines 25-31   : Slot definition class methods (7 lines)
  Lines 33-36   : compute-effective-slot-definition :around (4 lines)
  Lines 38-43   : slot-value-using-class :around (6 lines)
  Lines 45-53   : (setf slot-value-using-class) :around (9 lines)
  Lines 55-61   : slot-makunbound-using-class :around (7 lines)
  Lines 63-87   : NODE class definition with 13 slots (25 lines)
  Lines 88-89   : Blank lines (2)
```

## Core Components

### 1. *meta-slots* Variable (Line 3-5)
**Type:** defvar constant  
**Contents:** List of slot names that are "meta" (infrastructure)  
**Critical:** YES — controls which slots bypass plist storage

**Meta-slot list:**
- `id` — Node UUID (16-byte array)
- `%type-id` — Type identifier (unsigned-byte 16)
- `%revision` — Version counter (unsigned-byte 32)
- `%deleted-p` — Deletion flag (boolean)
- `%heap-written-p` — Persistence flag (boolean)
- `%type-idx-written-p` — Index persistence flag (boolean)
- `%ve-written-p` — VE-index persistence flag (boolean)
- `%vev-written-p` — VEV-index persistence flag (boolean)
- `%views-written-p` — View index persistence flag (boolean)
- `%written-p` — Overall write flag (boolean)
- `%data-pointer` — Address in heap (unsigned-byte 64)
- `%data` — Plist container for user slots (any)
- `%bytes` — Serialized form (any)
- `from` — Edge source (for edges, not vertices)
- `to` — Edge destination (for edges, not vertices)
- `weight` — Edge weight (for edges, not vertices)

**Pattern:** Slots starting with `%` are meta; slots without `%` prefix are user-defined

### 2. Metaclass Hierarchy

```
standard-class
    ↓
graph-class ────────────────────────┐
    ↓                               ↓
(instances are objects         (has custom slot
 with graph-class metaclass)    definition classes)
    ↓
NODE (and subclasses like VERTEX, EDGE)
```

**Metaclasses involved:**
- `graph-class` — Metaclass (inherits from standard-class)
- `graph-slot-definition` — Marker class for graph slots
- `graph-direct-slot-definition` — Direct slot variant
- `graph-effective-slot-definition` — Effective slot variant (computed from direct)

### 3. Slot Storage Strategy (CRITICAL)

**Two-tier storage:**

| Slot Type | Storage Location | Example | Access |
|-----------|------------------|---------|--------|
| **Meta** (in *meta-slots*) | Direct slot in NODE instance | `(id node)` | Normal `slot-value` |
| **User** (not in *meta-slots*) | Plist in `(data node)` | `:name "Alice"` | Intercepted via `%data` |

**Why this design?**
- Meta-slots are **infrastructure** (persistence machinery)
- User slots are **application data** (what user defines via def-vertex)
- Separating them allows:
  - Fast access to meta-slots (normal slot-value)
  - Flexible user slots (no class redefinition needed)
  - Transactional tracking (only user writes trigger enlistment)

**Example:**
```lisp
;; Define custom vertex type:
(def-vertex person
  (name :string)
  (age :integer))

;; Create instance:
(let ((p (make-vertex "person")))
  ;; Meta-slot (direct):
  (id p)  ; => #(245 18 99 ... )  [16-byte UUID]
  
  ;; User slots (via plist):
  (setf (name p) "Alice")  ; => Intercepted, stored in %data as (:name . "Alice")
  (age p)                  ; => Read from plist
)
```

### 4. Method Interception Pipeline

#### **Read: `slot-value-using-class` :around (Lines 38-43)**

```
User calls: (slot-value node 'name)
    ↓
:around method intercepts
    ↓
Is 'name in *meta-slots*?
    ├─ YES → call-next-method (use standard slot-value)
    └─ NO  → Look up in (data node) plist
             (intern 'name :keyword) → :name
             (assoc :name (data node)) → (:name . value)
             (cdr ...) → value
    ↓
Return value
```

**Code:**
```lisp
(defmethod slot-value-using-class :around ((class graph-class) instance slot)
  (let ((slot-name (sb-mop:slot-definition-name slot)))
    (if (find slot-name *meta-slots*)
        (call-next-method)                        ; Meta: use standard slot-value
        (let ((key (intern (symbol-name slot-name) :keyword)))
          (cdr (assoc key (data instance)))))))   ; User: read from plist
```

**Risk:** If `(data instance)` is NIL or doesn't contain key, returns NIL (no error)

#### **Write: `(setf slot-value-using-class)` :around (Lines 45-53)**

```
User calls: (setf (slot-value node 'name) "Alice")
    ↓
:around method intercepts new-value, class, instance, slot
    ↓
Is slot-name in *meta-slots*?
    ├─ YES → call-next-method (use standard slot-value setter)
    └─ NO  → Update (data node) plist
             (intern slot-name :keyword) → :name
             (setf (cdr (assoc :name (data instance))) "Alice")
             
             Is *current-transaction* bound?
             ├─ YES → Enlist instance in txn-update-queue
             │        (pushnew instance (txn-update-queue txn) ...)
             └─ NO  → Immediately persist: (save-node instance)
    ↓
Return new-value
```

**Code:**
```lisp
(defmethod (setf slot-value-using-class) :around (new-value (class graph-class) instance slot)
  (let ((slot-name (sb-mop:slot-definition-name slot)))
    (if (find slot-name *meta-slots*)
        (call-next-method)
        (let ((key (intern (symbol-name slot-name) :keyword)))
          (setf (cdr (assoc key (data instance))) new-value)
          (if *current-transaction*
              (pushnew instance (txn-update-queue *current-transaction*) :test 'equalp :key 'id)
              (save-node instance))))))
```

**CRITICAL BEHAVIOR:**
- Write triggers **transaction enlistment** or **immediate persistence**
- Depends on `*current-transaction*` being bound by Layer 3 (transactions.lisp)
- `save-node` (Layer 6) must be defined before this works

#### **Unbind: `slot-makunbound-using-class` :around (Lines 55-61)**

```
User calls: (slot-makunbound node 'name)
    ↓
:around method intercepts
    ↓
Is slot-name in *meta-slots*?
    ├─ YES → call-next-method (use standard slot-makunbound)
    └─ NO  → Remove from plist
             (setf (data instance) 
                   (delete :name (data instance) :key 'car))
    ↓
Return instance
```

**Code:**
```lisp
(defmethod slot-makunbound-using-class :around ((class graph-class) instance slot)
  (let ((slot-name (sb-mop:slot-definition-name slot)))
    (if (find slot-name *meta-slots*)
        (call-next-method)
        (let ((key (intern (symbol-name slot-name) :keyword)))
          (setf (data instance) (delete key (data instance) :key 'car))
          instance))))
```

### 5. NODE Class Definition (Lines 63-87)

**13 slots, all meta-infrastructure:**

| Slot | Type | Initform | Purpose |
|------|------|----------|---------|
| `id` | 16-byte array | `+null-key+` | UUID identifier |
| `%type-id` | unsigned-byte 16 | 1 | Type registry ID |
| `%revision` | unsigned-byte 32 | 0 | MVCC version |
| `%deleted-p` | boolean | NIL | Soft-delete flag |
| `%heap-written-p` | boolean | NIL | Persisted to heap? |
| `%type-idx-written-p` | boolean | NIL | Persisted to type-index? |
| `%ve-written-p` | boolean | NIL | Persisted to VE-index? |
| `%vev-written-p` | boolean | NIL | Persisted to VEV-index? |
| `%views-written-p` | boolean | NIL | Persisted to views? |
| `%written-p` | boolean | NIL | Overall persisted? |
| `%data-pointer` | unsigned-byte 64 | 0 | Address in memory-mapped file |
| `%data` | any | NIL | Plist `(:key1 val1 :key2 val2 ...)` |
| `%bytes` | any | `:init` | Serialized bytes (lazy) |

**Metaclass:** `graph-class` (uses MOP interception)

**Key insight:** NODE has NO user-defined slots. Subclasses (VERTEX, EDGE) add them via `def-vertex`/`def-edge`.

## Dependencies

### Imports
- **utilities.lisp** — Uses `+null-key+` constant (sentinel value)
- **globals.lisp** — Likely defines `+null-key+`
- **SBCL MOP** — `sb-mop:slot-definition-name`

### Exports
- **node-class.lisp** — Inherits from NODE and graph-class
- **vertex.lisp** — Creates vertices (instances of VERTEX ← NODE)
- **edge.lisp** — Creates edges (instances of EDGE ← NODE)
- **transactions.lisp** — Reads/writes `*current-transaction*`
- **serialize.lisp** — Uses `%data`, `%bytes` for serialization

## Complexity Assessment

### Hotspots (High Risk)

#### 1. **Method Resolution Order (MRO) with :around methods**
- **Risk:** Three :around methods on slot access
- **Chain:** :around → call-next-method → standard slot-value
- **Issue:** Debugging is hard; stack traces are deep
- **Mitigation:** Test thoroughly; use `trace` to debug

#### 2. **Plist as Data Store**
- **Risk:** `(assoc key plist)` returns NIL if key missing (silent failure)
- **Issue:** No type checking or validation of plist structure
- **Mitigation:** Ensure `%data` is always initialized to empty plist NIL, not unbound

#### 3. **Transaction Dependency**
- **Risk:** Setf method calls `(txn-update-queue *current-transaction*)` — assumes txn is bound
- **Issue:** If called outside transaction context, crashes
- **Mitigation:** Ensure *current-transaction* is always defined (even as NIL)

#### 4. **SBCL-only MOP**
- **Risk:** Uses `sb-mop:slot-definition-name` — SBCL-specific
- **Issue:** Will not work on CCL, LispWorks without compatibility layer
- **Mitigation:** Add #+sbcl guards; provide fallback for other Lisps

## Issues Found

### Blocking
1. **SBCL-specific MOP code** (Line 39, 46, 56)
   - Uses `sb-mop:slot-definition-name` directly
   - Will fail on CCL, LispWorks
   - **Fix:** Add #+sbcl guards or use portable MOP wrapper

### Critical
2. **Plist not initialized?**
   - NODE's `%data` initform is `nil`
   - But `(assoc :key nil)` returns NIL (not error)
   - Untested: Does (cdr nil) crash or return NIL?
   - **Fix:** Initialize %data to `'()` (empty plist) not nil, OR test heavily

3. **compute-effective-slot-definition is a no-op** (Lines 33-36)
   - Just calls `call-next-method` and returns slot unchanged
   - Why is this method defined at all?
   - **Fix:** Either document why it's needed, or remove it

### Warnings
4. **No docstrings** (all 0)
   - Methods have no documentation
   - MOP magic is hard to understand without comments
   - **Fix:** Add comprehensive docstrings (Phase 2)

## Test Strategy (Phase 2)

### Critical Tests
1. **Meta vs User Slots**
   - Create NODE instance
   - Read/write meta-slot (should use standard slot-value)
   - Read/write user-slot (should use plist)
   - Verify they don't interfere

2. **Plist Storage**
   - Write `:name "Alice"` to user slot
   - Verify it appears in `(data node)` as `(:name . "Alice")`
   - Verify read returns same value

3. **Transaction Enlistment**
   - Write user-slot inside transaction
   - Verify instance added to txn-update-queue
   - Outside transaction: verify save-node called

4. **Unbind**
   - Write user-slot, unbind it
   - Verify it's removed from plist
   - Verify subsequent read returns NIL

5. **Inheritance**
   - Create VERTEX subclass
   - Verify NODE slots still work
   - Verify VERTEX-specific slots route through plist

## Line-by-Line Breakdown

```
  1 : (in-package :graph-db)
  2 : (blank)
  3-5 : *meta-slots* definition
  6 : (blank)
  7-8 : graph-class definition
  9 : (blank)
 10-12 : validate-superclass method
 13 : (blank)
 14-23 : Slot definition classes (3 classes × 3-4 lines)
 24 : (blank)
 25-31 : Slot definition class methods (2 methods × 3-4 lines)
 32 : (blank)
 33-36 : compute-effective-slot-definition :around
 37 : (blank)
 38-43 : slot-value-using-class :around (READ interception)
 44 : (blank)
 45-53 : (setf slot-value-using-class) :around (WRITE interception)
 54 : (blank)
 55-61 : slot-makunbound-using-class :around (UNBIND interception)
 62 : (blank)
 63-87 : NODE class (13 slots)
 88-89 : Trailing blank lines
```

## Summary

| Metric | Value | Assessment |
|--------|-------|------------|
| **Lines** | 89 | ✅ Confirmed (roadmap: 88) |
| **Classes** | 4 (graph-class, 3 slot defs) | ✓ Small |
| **Methods** | 6 (validate-superclass + 3 slot defs + 3 slot intercepts) | ✅ Core functionality |
| **Variables** | 1 (*meta-slots*) | ✓ Critical constant |
| **Complexity** | VERY HIGH | ⚠️ Despite small size: MOP magic |
| **Docstrings** | 1 (validate-superclass) | ❌ Needs more |
| **FFI** | 1 (sb-mop, SBCL-specific) | ⚠️ Platform dependency |
| **Blocking issues** | 1 (SBCL-only) | 🔴 Must fix |
| **Critical issues** | 2 (plist init, no-op method) | 🟠 Must investigate |

## Next Steps

1. **Confirm SBCL requirement** — Is this intended to be SBCL-only, or should it support CCL/LispWorks?
2. **Proceed to documentation** — Add docstrings, inline comments
3. **Create tests** — 20+ test cases for slot interception
4. **Validate plist behavior** — Test nil vs empty list as initform

**Status:** ✅ Inspection complete. Ready for Etapa 2 (Documentation).
