# Layer 1: clos.lisp — Meta-Object Protocol Guide

**File:** `src/clos.lisp`  
**Lines:** 89  
**Priority:** HIGH — MOP intercepts ALL slot operations  
**Complexity:** VERY HIGH despite small size  
**Status:** Phase 2 (documentation)

## Purpose

`clos.lisp` implements the **Meta-Object Protocol (MOP)** interception layer that enables **flexible, schema-less slot storage** in VivaceGraph.

**The Problem It Solves:**
- How do you store user-defined slots without redefining the class?
- How do you track which slots have been modified (for transactions)?
- How do you persist heterogeneous data structures efficiently?

**The Solution: Two-Tier Storage**
```
META-SLOTS (fast, direct)          USER-SLOTS (flexible, plist)
┌───────────────────┐              ┌─────────────────┐
│ %type-id          │              │ :name           │
│ %revision         │   NODE ◄──── │ :age            │
│ %data-pointer     │              │ :email          │
│ %data ────────────┼──────────────►│ :phone          │
│ ... (10 more)     │              └─────────────────┘
└───────────────────┘              (stored as plist in %data)
```

## Key Concepts

### 1. **Meta-Slots vs User-Slots**

All NODE instances contain 13 **meta-slots** (infrastructure):

| Slot | Type | Purpose |
|------|------|---------|
| `id` | 16-byte UUID | Node identifier |
| `%type-id` | unsigned-byte 16 | Type registry reference |
| `%revision` | unsigned-byte 32 | MVCC version for isolation |
| `%deleted-p` | boolean | Soft-delete flag |
| `%heap-written-p`, `%type-idx-written-p`, etc. | boolean | Persistence flags (9 total) |
| `%data-pointer` | unsigned-byte 64 | Address in memory-mapped file |
| `%data` | plist | Container for user-defined slots |
| `%bytes` | any | Serialized representation |

**Meta-slots are stored directly in the NODE instance** (normal CLOS slots).

**User-slots are stored in a plist** inside `%data`:
```lisp
(def-vertex person (name :string) (age :integer))
(let ((p (make-vertex graph "person")))
  (setf (name p) "Alice")  ; Stored as (:name . "Alice") in (data p)
  (setf (age p) 30)        ; Stored as (:age . 30) in (data p)
  (data p))                ; => ((:age . 30) (:name . "Alice"))
```

**Why?**
- Meta-slots are fixed infrastructure (every node needs them)
- User-slots are flexible (different vertices have different properties)
- Plist storage allows unlimited user-defined slots without class redefinition

### 2. **The MOP Interception Layer**

VivaceGraph intercepts **all three** slot access operations:

#### **Operation 1: Reading a Slot (`slot-value-using-class` :around)**

```lisp
(slot-value node 'name)
    ↓
Is 'name a meta-slot?
    ├─ YES (e.g., 'id') → Standard slot-value (direct CPU access)
    └─ NO (e.g., 'name')  → Search plist in (data node)
                           (assoc :name (data node)) → (:name . "Alice")
                           (cdr ...) → "Alice"
```

**Implementation:**
```lisp
(defmethod slot-value-using-class :around ((class graph-class) instance slot)
  (let ((slot-name (sb-mop:slot-definition-name slot)))
    (if (find slot-name *meta-slots*)
        (call-next-method)  ; Meta: standard access
        (let ((key (intern (symbol-name slot-name) :keyword)))
          (cdr (assoc key (data instance)))))))  ; User: plist lookup
```

#### **Operation 2: Writing a Slot (`(setf slot-value-using-class)` :around) — CRITICAL**

```lisp
(setf (slot-value node 'name) "Alice")
    ↓
Is 'name a meta-slot?
    ├─ YES (e.g., '%revision') → Standard setf (direct)
    └─ NO (e.g., 'name')        → Update plist
                                (setf (cdr (assoc :name (data node))) "Alice")
                                
                                Are we in a transaction?
                                ├─ YES → Enlist in txn-update-queue (deferred save)
                                └─ NO  → Immediately call (save-node instance)
```

**Implementation:**
```lisp
(defmethod (setf slot-value-using-class) :around (new-value (class graph-class) instance slot)
  (let ((slot-name (sb-mop:slot-definition-name slot)))
    (if (find slot-name *meta-slots*)
        (call-next-method)
        (let ((key (intern (symbol-name slot-name) :keyword)))
          (setf (cdr (assoc key (data instance))) new-value)
          (if *current-transaction*
              (pushnew instance (txn-update-queue *current-transaction*) ...)
              (save-node instance))))))
```

**This is THE KEY TRANSACTION ENLISTMENT POINT.**

Every user-slot write either:
- **Inside transaction:** Deferred (saved at commit)
- **Outside transaction:** Immediate (saved now)

#### **Operation 3: Unbinding a Slot (`slot-makunbound-using-class` :around)**

```lisp
(slot-makunbound node 'name)
    ↓
Is 'name a meta-slot?
    ├─ YES → Standard unbind
    └─ NO  → Remove from plist
             (setf (data node) (delete :name (data node) :key 'car))
             ; After: (data node) no longer contains (:name . "Alice")
```

### 3. **Metaclass Hierarchy**

```
standard-class (CL built-in metaclass)
    ↓
graph-class (VivaceGraph metaclass)
    ↓
NODE (base class with 13 meta-slots)
    ├─ VERTEX (created by def-vertex)
    ├─ EDGE (created by def-edge)
    └─ (other domain-specific types)
```

**graph-class:**
- Inherits from standard-class
- Provides customization points via methods:
  - `direct-slot-definition-class` → returns `graph-direct-slot-definition`
  - `effective-slot-definition-class` → returns `graph-effective-slot-definition`
  - `slot-value-using-class` :around → interception
  - `(setf slot-value-using-class)` :around → interception (CRITICAL)
  - `slot-makunbound-using-class` :around → interception

### 4. **Slot Definition Classes**

MOP requires custom slot definition classes to track metadata:

| Class | Purpose |
|-------|---------|
| `graph-slot-definition` | Marker class (base) |
| `graph-direct-slot-definition` | Slots as written in class definition |
| `graph-effective-slot-definition` | Slots after inheritance resolution |

These are **mostly empty** — they exist as markers for the MOP. The actual behavior is in the :around methods.

## The NODE Class

**13 meta-slots, all infrastructure:**

```lisp
(defclass node ()
  ((id :type (array (unsigned-byte 8) (16))
       :documentation "16-byte UUID, immutable")
   (%type-id :type (unsigned-byte 16)
            :documentation "Type registry ID")
   (%revision :type (unsigned-byte 32)
             :documentation "MVCC version (0, 1, 2, ...)")
   (%deleted-p :type boolean
              :documentation "Soft-delete flag")
   ;; ... 9 more persistence flags ...
   (%data-pointer :type (unsigned-byte 64)
                 :documentation "Address in memory-mapped file")
   (%data :documentation "Plist of user-defined slots")
   (%bytes :documentation "Serialized representation"))
  (:metaclass graph-class))
```

**Naming convention:**
- Slots with `%` prefix = meta-infrastructure
- Slots without `%` = user-defined (stored in %data plist)

**Example instance:**
```lisp
(let ((v (make-vertex graph "person")))
  (setf (name v) "Alice")
  (setf (age v) 30))

; What it looks like internally:
; NODE instance with direct slots:
;   id: #(245 18 99 ... 77)  ; Direct 16-byte UUID
;   %type-id: 2              ; Type ID for "person"
;   %revision: 0
;   %deleted-p: nil
;   %data: ((:name . "Alice") (:age . 30))
;   ... other meta-slots ...
```

## Dependencies

### Imports
- **globals.lisp** → `+null-key+` constant (sentinel UUID)
- **utilities.lisp** → `less-than`, `with-lock` (implicitly, via other modules)
- **SBCL MOP** → `sb-mop:slot-definition-name` (SBCL-specific)

### Exports / Used By
- **node-class.lisp** → Inherits from NODE
- **vertex.lisp** → Uses NODE interception for VERTEX instances
- **edge.lisp** → Uses NODE interception for EDGE instances
- **transactions.lisp** → Reads `*current-transaction*` for enlistment
- **serialize.lisp** → Reads `%data` for serialization

## The Transaction Enlistment Mechanism

**This is the CRITICAL behavior:**

When you write a user slot, the write interception checks if `*current-transaction*` is bound:

```lisp
(with-transaction (g)
  (let ((v (make-vertex g "person")))
    (setf (name v) "Alice")))  ; <= Triggers:
                               ;    1. Update plist: (:name . "Alice")
                               ;    2. *current-transaction* is bound => Enlist v
                               ;    3. At commit: save-node is called for all enlisted instances
```

**Outside a transaction:**
```lisp
(let ((v (make-vertex g "person")))
  (setf (name v) "Alice"))  ; <= Triggers:
                            ;    1. Update plist: (:name . "Alice")
                            ;    2. *current-transaction* is NIL => Immediate save
                            ;    3. (save-node v) called immediately
```

**Why this matters:**
- Transactions defer writes until commit (isolation)
- Non-transactional writes are saved immediately (durability)
- Without this interception, ACID properties would be impossible

## Complexity Analysis

### What's Simple ✅
- Metaclass definition (3 lines)
- Slot definition classes (empty, just markers)
- Unbind operation (straightforward plist removal)

### What's Complex ⚠️

**1. Read Interception (Medium)**
- Distinguishes meta vs user slots
- Plist lookup is O(n) in number of user slots
- Silent failure if key not found

**2. Write Interception (High)**
- Distinguishes meta vs user slots
- Updates plist
- **CRITICAL:** Transaction enlistment
  - Must know about `*current-transaction*`
  - Must know about `txn-update-queue` structure
  - Must know about `save-node` function
  - Failure here = corrupted state

**3. SBCL Specificity (High)**
- Uses `sb-mop:slot-definition-name` directly
- Will NOT work on CCL, LispWorks without changes
- This is a blocking issue

## Issues Found

### 🔴 BLOCKING

1. **SBCL-only MOP code**
   - Lines 39, 46, 56: `(sb-mop:slot-definition-name slot)`
   - Will crash on CCL, LispWorks
   - **Fix:** Add `#+sbcl` guard or use portable MOP library

### 🟠 CRITICAL

2. **Plist Initialization Unclear**
   - `%data` initform is `nil`
   - Is this correct? Should it be `'()` (empty list)?
   - If `(data instance)` is `nil`, does `(assoc key nil)` work?
   - **Fix:** Test plist behavior; clarify initialization

3. **compute-effective-slot-definition is a No-Op**
   - Lines 33-36: Just calls `call-next-method`
   - Why is this method even defined?
   - **Fix:** Document purpose or remove

4. **No Persistence Layer Guarantee**
   - `save-node` is called but defined in Layer 6
   - If called before Layer 6 is loaded, crashes
   - **Fix:** Forward-declare or ensure load order

### 🟡 WARNINGS

5. **No Error Handling in Read**
   - If `(data instance)` is corrupted, returns NIL silently
   - **Fix:** Add validation or error signaling

## Testing Strategy (Phase 2)

### Critical Test Cases

**1. Meta-Slot Access**
```lisp
(let ((n (make-instance 'node)))
  (is (= 0 (%revision n)))     ; Direct read
  (setf (%revision n) 5)       ; Direct write
  (is (= 5 (%revision n))))    ; Verify write
```

**2. User-Slot Storage**
```lisp
(let ((n (make-instance 'node)))
  (setf (data n) '())          ; Initialize plist
  (setf (slot-value n 'name) "Alice")
  (is (equal (slot-value n 'name) "Alice"))
  (is (equal (data n) '((:name . "Alice")))))
```

**3. Transaction Enlistment**
```lisp
(with-transaction (g)
  (let ((v (make-vertex g "person")))
    (setf (name v) "Alice")
    (is (member v (txn-update-queue *current-transaction*)))))
```

**4. Unbind**
```lisp
(let ((n (make-instance 'node)))
  (setf (data n) '((:name . "Alice") (:age . 30)))
  (slot-makunbound n 'name)
  (is (null (assoc :name (data n))))
  (is (equal (data n) '((:age . 30)))))
```

**5. SBCL Compatibility**
```lisp
(let ((n (make-instance 'node)))
  (slot-value n 'id)  ; Should work on SBCL
  ;; Should signal error on CCL/LispWorks (without fixes)
)
```

## Code Quality Summary

| Aspect | Status | Notes |
|--------|--------|-------|
| **Docstrings** | ❌ None → ✅ ANNOTATED | Added via ANNOTATED version |
| **Inline comments** | ❌ Minimal | High complexity, needs more |
| **Cross-platform** | ❌ SBCL-only | Critical issue |
| **Completeness** | ⚠️ Partial | Depends on Layer 3, 6 |
| **Test coverage** | ❌ Zero | Phase 2 deliverable |
| **Performance** | ✅ Good | Plist lookup is weak point |
| **Dependencies** | ⚠️ Hidden | Depends on runtime state (`*current-transaction*`) |

## Key Insights

### Why This Design?

1. **Flexible Schema**
   - User-slots stored in plist = no class redefinition needed
   - def-vertex/def-edge just define accessor functions
   - Each vertex type can have unique properties

2. **Transaction Support**
   - Write interception = automatic enlistment
   - Users don't manually track modified instances
   - Just (setf (slot-value obj 'prop) val) inside with-transaction

3. **Persistence Tracking**
   - Meta-slots track which indexes have persisted the node
   - `%written-p` = all indexes synchronized
   - Efficient incremental persistence

### Why the Complexity?

- **MOP is powerful but cryptic** — intercepts at lowest level (unfamiliar to most Lispers)
- **Three layers of access patterns** — meta vs user, reads vs writes vs unbind
- **Transaction integration** — must know about transaction context
- **Platform-specific code** — SBCL MOP is different from CCL/LispWorks

## Recommendations

### Before Release
1. Fix SBCL-only issue (add portable MOP wrapper)
2. Document plist initialization (nil vs '())
3. Clarify compute-effective-slot-definition purpose
4. Add error handling for corrupted plist
5. Add comprehensive tests (20+ test cases)

### Future Optimization
1. Cache plist key positions (avoid O(n) lookup per read)
2. Use hash table instead of plist (O(1) lookup)
3. Add slot type checking and validation
4. Add documentation on schema evolution

## Next Steps

- [ ] Execute clos tests (20+ cases)
- [ ] Fix SBCL-only issue
- [ ] Proceed to node-class.lisp (174 lines)

**Status:** ✅ Documentation complete. Ready for testing.
