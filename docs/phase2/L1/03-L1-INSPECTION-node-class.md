# Layer 1 Inspection Report: node-class.lisp

**File:** `src/node-class.lisp`  
**Lines:** 175 (actual), 174 (roadmap) — ✅ Match  
**Date:** March 31, 2026  
**Priority:** HIGH — Slot categorization protocol  
**Complexity:** VERY HIGH (2.5x clos.lisp)

## Executive Summary

`node-class.lisp` implements a **sophisticated slot categorization system** that enables:
- **Persistent vs ephemeral** slots (what gets saved vs what's temporary)
- **Indexed vs non-indexed** slots (for query performance)
- **Meta vs data** slots (infrastructure vs user data)
- **Class hierarchy utilities** (find all subclasses, ancestors)

**Key innovation:** Uses `:meta t`, `:persistent t`, `:ephemeral t`, `:indexed t` slot properties (compile-time metadata) instead of runtime list comparisons like clos.lisp.

## Line Count Breakdown

```
  Lines | Section                                    | Type | Notes
────────────────────────────────────────────────────────────────────────
  1-2   | Package + eval-when                        | Meta | eval-when wraps entire file
  3-4   | node-class metaclass definition            | Code | Similar to graph-class
  6-8   | validate-superclass method                 | Code | Standard MOP
  10-14 | node-slot-definition class (4 slots!)      | Code | CRITICAL: persistent, indexed, ephemeral, meta
  16-26 | Default persistent-p/indexed-p methods     | Code | Catch-all for non-node-slot-definition
  28-34 | Direct/Effective slot definition classes   | Code | Markers like clos.lisp
  36-41 | data-slots method                          | Code | Filter: persistent OR ephemeral
  43-53 | meta-slot-names method                     | Code | Filter: meta=t
  55-64 | persistent-slot-names method               | Code | Filter: persistent=t
  66-75 | ephemeral-slot-names method                | Code | Filter: ephemeral=t
  77-85 | Slot definition class methods              | Code | MOP hooks + logging
  87-106| compute-effective-slot-definition :around  | Code | CRITICAL: Inherits properties
  108-119| find-all-subclasses method                | Code | Recursive subclass discovery
  121-122| find-all-subclass-names method            | Code | Names of subclasses
  124-133| find-ancestor-classes method              | Code | Filter out built-ins
  135-144| find-graph-parent-classes method          | Code | Domain-specific ancestors
  147-174| NODE class definition (13 slots)          | Code | Meta-based slot categorization
  175   | Closing paren for eval-when                | Meta |
```

## Core Components

### 1. **node-class Metaclass** (Lines 3-8)

```lisp
(defclass node-class (standard-class) nil)
```

Similar to clos.lisp's `graph-class` but:
- Different name (node-class vs graph-class)
- Provides MORE functionality (slot categorization)
- Used by NODE and subclasses (VERTEX, EDGE, etc)

**Validation:**
```lisp
(defmethod validate-superclass ((class node-class) (super standard-class))
  t)  ; node-class inherits from standard-class
```

### 2. **node-slot-definition Class** (Lines 10-14) — CRITICAL

```lisp
(defclass node-slot-definition (standard-slot-definition)
  ((persistent :accessor persistent-p :initarg :persistent :initform t :allocation :instance)
   (indexed :accessor indexed-p :initarg :index :initform nil :allocation :instance)
   (ephemeral :accessor ephemeral-p :initarg :ephemeral :initform nil :allocation :instance)
   (meta :accessor meta-p :initarg :meta :initform nil :allocation :instance)))
```

**Four slot properties:**

| Property | Type | Default | Purpose |
|----------|------|---------|---------|
| `persistent` | boolean | T | Should this slot be persisted to disk? |
| `indexed` | boolean | NIL | Create an index for this slot? |
| `ephemeral` | boolean | NIL | Temporary slot (exists only in memory)? |
| `meta` | boolean | NIL | Infrastructure slot (like id, type-id)? |

**Usage in NODE class definition:**
```lisp
(defclass node ()
  ((id :meta t :persistent nil)      ; Infrastructure, not persisted separately
   (type-id :meta t :persistent nil)  ; Type registry ID
   (my-data :persistent t :indexed t) ; User data, persisted & indexed
   (cache :ephemeral t)               ; Temporary, never saved
   ))
  (:metaclass node-class))
```

### 3. **Slot Categorization Methods** (Lines 36-75)

#### **data-slots(instance)** (Lines 36-41)
**Returns:** List of slot names that are persistent OR ephemeral

```lisp
(defmethod data-slots ((instance node-class))
  (map 'list 'slot-definition-name
       (remove-if-not #'(lambda (i)
                          (or (persistent-p i) (ephemeral-p i)))
                      (class-slots instance))))
```

**Logic:** Include if `:persistent t` OR `:ephemeral t`

**Example:**
```lisp
(data-slots (find-class 'vertex))
=> (my-name my-age my-email)  ; User data slots
```

#### **meta-slot-names(instance)** (Lines 43-53)
**Returns:** List of slot names that are infrastructure (meta)

```lisp
(defmethod meta-slot-names ((instance node-class))
  (let ((names (map 'list 'slot-definition-name
                    (remove-if-not #'meta-p (class-slots instance)))))
    names))
```

**Example:**
```lisp
(meta-slot-names (find-class 'node))
=> (id type-id revision heap-written-p ...)  ; All 13 meta-slots
```

#### **persistent-slot-names(instance)** (Lines 55-64)
**Returns:** List of slot names that are persistent (saved to disk)

#### **ephemeral-slot-names(instance)** (Lines 66-75)
**Returns:** List of slot names that are ephemeral (temporary)

### 4. **compute-effective-slot-definition :around** (Lines 87-106) — CRITICAL

This method **inherits slot properties** from direct slot definitions (consider inheritance chains).

```lisp
(defmethod compute-effective-slot-definition :around
    ((class node-class) slot-name direct-slots)
  (let ((slot (call-next-method)))
    ;; If ANY direct-slot has :meta t, mark effective slot as meta
    (cond ((or (meta-p slot) (some 'meta-p direct-slots))
           (setf (slot-value slot 'meta) t)
           (setf (slot-value slot 'persistent) nil))
          ;; Else if ANY direct-slot has :persistent t, mark as persistent
          ((or (persistent-p slot) (some 'persistent-p direct-slots))
           (setf (slot-value slot 'persistent) t))
          ;; Else default to ephemeral
          (t
           (setf (slot-value slot 'persistent) nil)
           (setf (slot-value slot 'ephemeral) t)))
    ;; If ANY direct-slot has :indexed t, mark as indexed
    (when (or (indexed-p slot) (some 'indexed-p direct-slots))
      (setf (slot-value slot 'indexed) t)
      ;; FIXME: Generate index if needed
      )
    slot))
```

**Inheritance rules:**
1. If slot (or any direct) has `:meta t` → Mark as meta, set persistent=nil
2. Else if slot (or any direct) has `:persistent t` → Mark as persistent
3. Else → Default to ephemeral (but not meta)
4. If ANY direct has `:indexed t` → Mark as indexed

**Why:** Allows subclasses to override slot properties via inheritance.

### 5. **Class Hierarchy Utilities** (Lines 108-144)

#### **find-all-subclasses(class)** (Lines 108-119) — CRITICAL

Recursively finds ALL subclasses (not just direct).

```lisp
(defmethod find-all-subclasses ((class class))
  (let ((result nil))
    (labels ((find-them (class)
               (let ((subclasses (class-direct-subclasses class)))
                 (dolist (subclass subclasses)
                   (unless (find subclass result)
                     (push subclass result)
                     (find-them subclass))))))
      (find-them class)
      result)))
```

**Algorithm:**
1. Start with direct subclasses
2. For each, recursively find their subclasses
3. Accumulate into result (no duplicates)

**Example:**
```lisp
(find-all-subclasses (find-class 'node))
=> (VERTEX EDGE PERSON COMPANY EMPLOYEE ...)
; Including EMPLOYEE even if EMPLOYEE < PERSON < VERTEX < NODE
```

**Usage:** Layer 5+ uses this for type-index (find all instances of a type).

#### **find-ancestor-classes(class)** (Lines 124-133)

Returns class hierarchy, filtering out built-in classes.

```lisp
(defmethod find-ancestor-classes ((class node-class))
  (delete-if (lambda (class)
               (find (class-name class)
                     #+sbcl '(edge vertex node STANDARD-OBJECT SB-PCL::SLOT-OBJECT T)
                     #+lispworks '(edge vertex node standard-object T)
                     #+ccl '(edge vertex node STANDARD-OBJECT T)))
             (compute-class-precedence-list class)))
```

**Filters out:**
- STANDARD-OBJECT (CL built-in)
- SB-PCL::SLOT-OBJECT (SBCL internal)
- T (root class)
- edge, vertex, node (domain-specific)

**Returns only:** Custom ancestor classes

#### **find-graph-parent-classes(class)** (Lines 135-144)

Returns custom parent classes (for def-vertex inheritance chains).

```lisp
(defmethod find-graph-parent-classes ((class node-class))
  (let ((classes
         (remove-if (lambda (class)
                      (or (eq (class-name class) 'vertex)
                          (eq (class-name class) 'edge)
                          (eq (class-name class) 'primitive-node)))
                    (class-direct-superclasses class))))
    (remove-duplicates
     (nconc classes
            (mapcan 'find-graph-parent-classes classes)))))
```

**Filters:** Removes vertex, edge, primitive-node from hierarchy
**Returns:** Custom parent classes only

**Example:**
```lisp
; Define hierarchy:
(def-vertex person (name :string))
(def-vertex employee (person) (salary :float))

; Then:
(find-graph-parent-classes (find-class 'employee))
=> (PERSON)  ; Just PERSON, not VERTEX or NODE
```

### 6. **NODE Class** (Lines 147-174)

Defines base persistent object with 13 meta-slots **using new slot properties**:

| Slot | :meta | :persistent | Purpose |
|------|-------|-------------|---------|
| `id` | T | NIL | 16-byte UUID |
| `type-id` | T | NIL | Type registry ID |
| `revision` | T | NIL | MVCC version |
| `%revision-table` | T | NIL | Hash table for version tracking |
| `heap-written-p` | T | NIL | Persistence flag |
| `type-idx-written-p` | T | NIL | Persistence flag |
| `ve-written-p` | T | NIL | Persistence flag |
| `vev-written-p` | T | NIL | Persistence flag |
| `views-written-p` | T | NIL | Persistence flag |
| `written-p` | T | NIL | Overall persistence flag |
| `data-pointer` | T | NIL | Address in memory-mapped file |
| `deleted-p` | T | NIL | Soft-delete flag |
| `data` | T | NIL | Plist container |
| `bytes` | T | NIL | Serialized form |

**All marked `:meta t :persistent nil`** — They are infrastructure, not persisted as data (persisted as system metadata).

## Dependencies

### Imports
- **globals.lisp** → `+null-key+` constant
- **utilities.lisp** → (implicitly via globals)
- **Log library** (optional) → `log:debug`, `log:trace` (for debugging)
- **SBCL/CCL/LispWorks MOP** → `class-direct-subclasses`, `compute-class-precedence-list`

### Exports / Used By
- **vertex.lisp** → (def-vertex uses node-class)
- **edge.lisp** → (def-edge uses node-class)
- **type-index.lisp** → Uses `find-all-subclasses` to find all instances
- **views.lisp** → Uses slot categorization for index generation
- **serialize.lisp** → Uses `persistent-slot-names` to know what to save

## Complexity Hotspots

### 🔴 BLOCKING

1. **eval-when wraps entire file** (Lines 3-145)
   - Code is wrapped in `(eval-when (:compile-toplevel :load-toplevel :execute) ...)`
   - Means metaclass definition happens at COMPILE TIME
   - If metaclass not available, subclasses fail to compile
   - **Risk:** Circular dependency if node-class.lisp is loaded before something that defines node-class

### 🟠 CRITICAL

2. **compute-effective-slot-definition complexity** (Lines 87-106)
   - Three-way conditional on meta/persistent/ephemeral
   - Uses `some` with lambda to check direct slots
   - FIXME comment: "Generate index if needed" (unimplemented)
   - **Risk:** Slot property inheritance may be unexpected (esp. in multi-level hierarchies)

3. **find-all-subclasses recursion** (Lines 108-119)
   - Recursive traversal with accumulator
   - Uses `(unless (find subclass result) ...)` for duplicate check
   - **Risk:** Stack overflow on very deep hierarchies (unlikely in practice)
   - **Performance:** find check is O(n) for each subclass; should use set/hash

4. **Platform-specific ancestor filtering** (Lines 130-132)
   - Different built-in class names on SBCL vs CCL vs LispWorks
   - Hard-coded platform-specific lists
   - **Risk:** Breaks on new platform or new CL implementation
   - **Risk:** If CL vendor adds new internal class, breaks silently

### 🟡 WARNINGS

5. **Logging calls throughout** (Lines 45, 79, 84, 91, 109, 113)
   - `log:debug` and `log:trace` called but often commented out
   - Logging library may not be loaded
   - **Fix:** Either load logging lib or remove calls

6. **Default methods for non-node-slots** (Lines 16-26)
   - Generic `persistent-p`, `indexed-p`, etc. return NIL for unknown slots
   - Silent failure if slot is not node-slot-definition
   - **Risk:** No error for typos in slot names

## Comparison with clos.lisp

| Aspect | clos.lisp | node-class.lisp | Better? |
|--------|-----------|-----------------|---------|
| **Slot classification** | Runtime list `*meta-slots*` | Compile-time properties (:meta, :persistent) | node-class.lisp ✅ |
| **Categorization** | Binary (meta or not) | 4-level (meta, persistent, ephemeral, indexed) | node-class.lisp ✅ |
| **Inheritance** | Not handled (no :around) | Explicit property inheritance | node-class.lisp ✅ |
| **Class utilities** | None | find-all-subclasses, find-ancestor-classes | node-class.lisp ✅ |
| **Metaclass** | graph-class | node-class | Both similar |
| **MOP hooks** | Slot interception (:around) | Slot definition + interception | Both needed |

**Relationship:** Both are used! clos.lisp provides slot-value interception; node-class.lisp provides slot categorization.

## Issues Found

### 🔴 BLOCKING

1. **eval-when wraps entire file**
   - May cause load-order issues
   - **Fix:** Consider moving metaclass definition to separate file OR ensure loaded first

### 🟠 CRITICAL

2. **compute-effective-slot-definition logic unclear**
   - Default to ephemeral if not meta and not persistent
   - Is this correct? Should it error instead?
   - **Fix:** Document reason or add clarification

3. **find-all-subclasses O(n²) duplicate detection**
   - Uses `(find subclass result)` which is O(n) per subclass
   - Should use hash set for O(1) lookup
   - **Fix:** Optimize for large hierarchies

4. **FIXME: Generate index if needed** (Line 104)
   - Index generation not implemented
   - Slot can be marked `:indexed t` but no index created
   - **Fix:** Implement or remove FIXME

### 🟡 WARNINGS

5. **Logging library not explicitly loaded**
   - `log:debug` and `log:trace` called
   - May cause error if logging not available
   - **Fix:** Add (require 'cl-log) or guard with #+ feature

6. **Platform-specific class filtering**
   - Hard-coded lists for SBCL/CCL/LispWorks
   - Breaks on new platform
   - **Fix:** Use feature-based dispatch or runtime detection

## Testing Strategy (Phase 2)

### Critical Tests

1. **Slot categorization**
   - Create node with persistent/ephemeral/indexed/meta slots
   - Verify data-slots, meta-slot-names, etc. return correct lists

2. **Inheritance of properties**
   - Define subclass that overrides :persistent property
   - Verify compute-effective-slot-definition merges correctly

3. **find-all-subclasses**
   - Create multi-level hierarchy
   - Verify all subclasses found (including deep ones)

4. **Class utilities**
   - find-ancestor-classes filters correctly
   - find-graph-parent-classes excludes domain types

## Code Quality Summary

| Aspect | Status | Notes |
|--------|--------|-------|
| **Docstrings** | ⚠️ Minimal | Some methods have docs, many don't |
| **Inline comments** | ❌ Very minimal | Complex logic needs more explanation |
| **Cross-platform** | ⚠️ Partial | Platform-specific class filtering |
| **Completeness** | ⚠️ Partial | FIXME for index generation |
| **Test coverage** | ❌ Zero | Phase 2 deliverable |
| **Performance** | ⚠️ Suboptimal | O(n²) duplicate detection in find-all-subclasses |
| **Complexity** | 🔴 VERY HIGH | Despite only 175 lines, dense MOP code |

## Summary

| Metric | Value | Assessment |
|--------|-------|------------|
| **Lines** | 175 | ✅ Confirmed |
| **Methods** | 12 (6 MOP + 4 categorization + 2 utilities) | ✓ |
| **Metaclasses** | 1 (node-class) | ✓ |
| **Slot definition classes** | 3 (node-slot-definition + direct + effective) | ✓ |
| **Complexity** | VERY HIGH | ⚠️ Despite small size |
| **Blocking issues** | 1 (eval-when wrap) | 🔴 |
| **Critical issues** | 3 | 🟠 |
| **Warnings** | 2 | 🟡 |

## Relationship to clos.lisp

**NOT a replacement** — both files work together:

- **clos.lisp:** Intercepts slot reads/writes at runtime (MOP slot access)
- **node-class.lisp:** Categorizes slots at compile-time (MOP slot definition)

**Together they enable:**
- Flexible schema (MOP interception)
- Type-safe categorization (persistent/ephemeral/indexed/meta)
- Inheritance of properties (compute-effective-slot-definition)
- Class introspection (find-all-subclasses)

## Next Steps

1. **Confirm eval-when necessity** — Can it be moved to separate file?
2. **Proceed to documentation** — Add docstrings, explain complex logic
3. **Create tests** — 25+ test cases for categorization, inheritance, utilities
4. **Fix 3 critical issues** — Property inheritance, index generation, duplicate detection

**Status:** ✅ Inspection complete. Ready for Etapa 2 (Documentation).
