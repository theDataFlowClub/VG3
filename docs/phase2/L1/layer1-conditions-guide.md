# Layer 1: Comprehensive Guide to Exception Hierarchy and Error Handling

**File:** `src/conditions.lisp`  
**Lines:** 84  
**Exceptions:** 12 classes  
**Purpose:** Define all custom error types and provide structured error handling

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Exception Hierarchy](#exception-hierarchy)
3. [Exception by Layer](#exception-by-layer)
4. [Usage Patterns](#usage-patterns)
5. [Error Recovery](#error-recovery)
6. [Design Rationale](#design-rationale)
7. [Integration Guide](#integration-guide)

## Quick Reference

| Exception | Layer | Raise When | Recover |
|-----------|-------|-----------|---------|
| **slave-auth-error** | 6 (Replication) | Slave auth fails | Check credentials, network |
| **transaction-error** | 3 (Transactions) | Generic txn failure | Retry txn |
| **serialization-error** | 4 (Serialization) | Object → bytes fails | Check slot types |
| **deserialization-error** | 4 (Serialization) | bytes → object fails | Check data integrity |
| **stale-revision-error** | 3 (MVCC) | Write conflict detected | Retry txn (automatic) |
| **duplicate-key-error** | 2/4 (Indexing) | Key already exists | Modify or update |
| **nonexistent-key-error** | 2/4 (Indexing) | Key not found | Check data, retry |
| **node-already-deleted-error** | 3/4 (Lifecycle) | Deleting deleted node | Check if idempotent |
| **vertex-already-deleted-error** | 3/4 (Lifecycle) | Vertex already gone | Check if idempotent |
| **edge-already-deleted-error** | 3/4 (Lifecycle) | Edge already gone | Check if idempotent |
| **invalid-view-error** | 5 (Views) | View doesn't exist | Define view or check name |
| **view-lock-error** | 5 (Views) | Locking fails | Retry, check config |

## Exception Hierarchy

```
error (CL:error — standard Common Lisp)
│
├─ slave-auth-error
│   └─ Raised by: Layer 6 (replication.lisp)
│   └─ Recovery: Automatic retry, user checks credentials
│
├─ transaction-error
│   └─ Raised by: Layer 3 (transactions.lisp)
│   └─ Recovery: Transaction framework retries
│
├─ serialization-error
│   └─ Raised by: Layer 4 (serialize.lisp)
│   └─ Recovery: User checks object structure
│
├─ deserialization-error
│   └─ Raised by: Layer 4 (serialize.lisp)
│   └─ Recovery: Check data integrity, restore from backup
│
├─ stale-revision-error
│   └─ Raised by: Layer 3 (transactions.lisp)
│   └─ Recovery: Automatic retry by transaction framework
│
├─ duplicate-key-error
│   └─ Raised by: Layer 2 (skip-list.lisp, lhash.lisp)
│   └─ Recovery: Use update instead of insert
│
├─ nonexistent-key-error
│   └─ Raised by: Layer 2 (skip-list.lisp, lhash.lisp)
│   └─ Recovery: Return NIL (query no result) or fail
│
├─ node-already-deleted-error [BASE CLASS]
│   │
│   ├─ vertex-already-deleted-error [SUBCLASS]
│   │   └─ Raised by: Layer 3 (transactions.lisp)
│   │   └─ Recovery: Check if delete is idempotent
│   │
│   └─ edge-already-deleted-error [SUBCLASS]
│       └─ Raised by: Layer 3 (transactions.lisp)
│       └─ Recovery: Check if delete is idempotent
│
├─ invalid-view-error
│   └─ Raised by: Layer 5 (views.lisp)
│   └─ Recovery: Define the missing view
│
└─ view-lock-error
    └─ Raised by: Layer 5 (views.lisp)
    └─ Recovery: Retry, check locking configuration
```

## Exception by Layer

### Layer 2: Indexing (skip-list.lisp, lhash.lisp)

**Exceptions:**
- `duplicate-key-error` — Key already exists in unique index
- `nonexistent-key-error` — Key not found during lookup

**Context:**
Layer 2 implements low-level indexing (skip lists, linear hash tables).
These exceptions signal constraint violations or lookup failures.

**When raised:**
```lisp
;; In skip-list operations
(insert-into-index index key value)
;; Raises: duplicate-key-error if key already exists

(lookup-in-index index key)
;; Returns: value if found, or raises nonexistent-key-error
```

**Usage:**
```lisp
(handler-case
  (insert-into-ve-index graph source-vertex edge-type edge-id)
  (duplicate-key-error (e)
    ;; Handle constraint violation
    (log-constraint-violation (duplicate-key-error-key e)))
  (nonexistent-key-error (e)
    ;; Handle lookup failure
    (return-no-results)))
```

### Layer 3: Transactions (transactions.lisp)

**Exceptions:**
- `transaction-error` — Generic transaction failure
- `stale-revision-error` — MVCC write conflict
- `node-already-deleted-error` (and subclasses) — Soft delete conflict

**Context:**
Layer 3 implements ACID transactions using MVCC (Multi-Version Concurrency Control).
Transactions provide isolation and consistency via versioning and optimistic locking.

**Key concept: Optimistic Locking**
```
Transaction A                  Transaction B
1. Read object (rev 3)
2. Compute changes
3. Check revision still 3   
   ↓
4. Rev is now 4!          ← Transaction B updated it
   (stale-revision-error!)

Recovery: Retry from step 1
```

**When raised:**

```lisp
;; Generic transaction error
(with-transaction graph
  (if constraint-violated-p
    (error 'transaction-error :reason "Duplicate vertex ID")))

;; Stale revision (automatic detection)
(with-transaction graph
  (let ((v (lookup-vertex graph id)))  ; Read at revision N
    (setf (vertex-age v) 30)
    ;; If another txn updated v to revision N+1, commit fails:
    ;; (error 'stale-revision-error :instance v :current-revision (1+ N))))

;; Already deleted
(with-transaction graph
  (delete-vertex vertex)  ; If vertex %deleted-p = T
  ;; Raises: (error 'vertex-already-deleted-error :node vertex)
```

**Usage:**
```lisp
(defun safe-update-vertex (graph id new-value)
  (loop
    (handler-case
      (with-transaction graph
        (let ((v (lookup-vertex graph id)))
          (setf (vertex-data v) new-value)))
      (stale-revision-error (e)
        ;; Retry: loop again
        (log-retry (stale-revision-error-revision e))))))
```

### Layer 4: Serialization (serialize.lisp)

**Exceptions:**
- `serialization-error` — Object → bytes conversion fails
- `deserialization-error` — bytes → object conversion fails

**Context:**
Layer 4 converts between Lisp objects and byte representations stored in mmap.
These exceptions signal type mismatches or corruption.

**When raised:**

```lisp
;; Serialization (object to bytes)
(serialize-vertex vertex)
;; If vertex has unsupported slot type:
;; (error 'serialization-error 
;;        :instance vertex 
;;        :reason "Unknown type code for slot")

;; Deserialization (bytes to object)
(deserialize-vertex mmap-pointer)
;; If bytes are corrupted or type code invalid:
;; (error 'deserialization-error 
;;        :instance mmap-pointer 
;;        :reason "Invalid type code: 255")
```

**Usage:**
```lisp
(handler-case
  (let ((bytes (serialize-vertex v)))
    (write-to-disk bytes))
  (serialization-error (e)
    ;; Object has unsupported type
    (log-serialization-failure v (serialization-error-reason e))
    (handle-error-dialog "Cannot save vertex: unsupported field type")))
```

### Layer 5: Views (views.lisp)

**Exceptions:**
- `invalid-view-error` — Requested view doesn't exist
- `view-lock-error` — Locking problem during view computation

**Context:**
Layer 5 implements views (named queries, aggregations, materializations).
Views can be expensive to compute, requiring locks for consistency.

**When raised:**

```lisp
;; Invalid view
(execute-view graph "PERSON" "AGE_DISTRIBUTION")
;; If view not defined:
;; (error 'invalid-view-error 
;;        :class-name "PERSON" 
;;        :view-name "AGE_DISTRIBUTION")

;; Locking error (deadlock, timeout)
(compute-view-aggregate ...)
;; If locks conflict:
;; (error 'view-lock-error :message "Deadlock in view reduction")
```

**Usage:**
```lisp
(handler-case
  (let ((results (execute-view graph "PERSON" "AVG_AGE")))
    (display-results results))
  (invalid-view-error (e)
    ;; View not defined
    (suggest-define-view (invalid-view-error-class e)
                         (invalid-view-error-view e)))
  (view-lock-error (e)
    ;; Deadlock/timeout
    (log-view-error (view-lock-error-message e))
    (retry-with-backoff)))
```

### Layer 6: Replication (replication.lisp)

**Exceptions:**
- `slave-auth-error` — Slave authentication fails with master

**Context:**
Layer 6 implements master-slave replication.
Slaves must authenticate before syncing with the master.

**When raised:**

```lisp
;; During replication setup
(connect-slave-to-master master-host slave-id replication-key)
;; If credentials don't match:
;; (error 'slave-auth-error 
;;        :host "192.168.1.100" 
;;        :reason "Replication key mismatch")
```

**Usage:**
```lisp
(handler-case
  (start-replication slave master-config)
  (slave-auth-error (e)
    ;; Authentication failed
    (format *error-output*
            "Cannot connect to ~A: ~A~%"
            (slave-auth-host e)
            (slave-auth-reason e))
    (alert-operator "Replication failed")))
```

## Usage Patterns

### Pattern 1: Simple catch for specific exception

```lisp
(handler-case
  (delete-vertex graph vertex-id)
  (vertex-already-deleted-error (e)
    ;; Already deleted; that's OK
    (format t "Vertex already gone~%")))
```

### Pattern 2: Catch exception family

```lisp
;; Catch both vertex and edge deletion errors
(handler-case
  (delete-node graph node)
  (node-already-deleted-error (e)
    ;; Either vertex or edge; don't care which
    (format t "Node ~A is gone~%" (node-already-deleted-node e))))
```

### Pattern 3: Access exception slots

```lisp
(handler-case
  (lookup-in-index index key)
  (nonexistent-key-error (e)
    ;; Get more info about what failed
    (format t "Key ~S not in ~A~%"
            (nonexistent-key-error-key e)
            (nonexistent-key-error-instance e))))
```

### Pattern 4: Retry logic

```lisp
(defun with-retry (fn max-attempts)
  (loop for attempt from 1 to max-attempts do
    (handler-case
      (return-from with-retry (funcall fn))
      (stale-revision-error (e)
        ;; Retry on conflict
        (when (= attempt max-attempts)
          (error "Max retries exceeded"))
        (sleep 0.01 (* attempt 0.001))))))
```

### Pattern 5: Re-raise with additional context

```lisp
(handler-case
  (load-vertex-from-disk mmap-ptr)
  (deserialization-error (e)
    ;; Add context and re-raise
    (error 'deserialization-error
           :instance (format nil "~A (at mmap offset ~A)" 
                           (deserialization-error-instance e)
                           mmap-offset)
           :reason (deserialization-error-reason e))))
```

### Pattern 6: Logging and alerting

```lisp
(handler-case
  (risky-operation)
  (serialization-error (e)
    ;; Log the error
    (log-event :error
               :exception-type 'serialization-error
               :instance (serialization-error-instance e)
               :reason (serialization-error-reason e))
    ;; Alert operator
    (send-alert "Serialization failure in graph DB")
    ;; Fail gracefully
    (return-failure)))
```

## Error Recovery

### By Exception Type

**slave-auth-error** — Replication Authentication Failure
- Automatic: Wait and retry (with backoff)
- User action: Check replication credentials
- Don't need: Code-level retry (operation will succeed if credentials fixed)

**transaction-error** — Generic Transaction Failure
- Automatic: Framework retries with backoff
- User action: May need to adjust data or constraints
- Code-level: Can catch and skip some operations

**serialization-error** — Object → Bytes Fails
- Automatic: No automatic recovery
- User action: Inspect object slots, remove unsupported types
- Code-level: Catch and warn user

**deserialization-error** — Bytes → Object Fails
- Automatic: No automatic recovery
- User action: Check data integrity, restore from backup
- Code-level: Catch, log, and skip corrupted records

**stale-revision-error** — MVCC Write Conflict
- Automatic: Transaction framework retries automatically
- User action: No action needed (transparent)
- Code-level: Handle in retry loop (see Pattern 4 above)

**duplicate-key-error** — Key Already Exists
- Automatic: No automatic recovery
- User action: Modify data or use update instead of insert
- Code-level: Catch and use upsert pattern

**nonexistent-key-error** — Key Not Found
- Automatic: No automatic recovery
- User action: Check if expected (not always an error)
- Code-level: Distinguish "not found" from "error"

**node-already-deleted-error** — Node Already Deleted
- Automatic: No automatic recovery
- User action: Check if delete is idempotent
- Code-level: Catch if safe to ignore

**vertex-already-deleted-error** / **edge-already-deleted-error**
- Same as node-already-deleted-error (specializations)

**invalid-view-error** — View Doesn't Exist
- Automatic: No automatic recovery
- User action: Define the missing view
- Code-level: Catch and suggest view definition

**view-lock-error** — Locking Problem
- Automatic: Retry with backoff (similar to transaction conflicts)
- User action: Check for circular lock dependencies
- Code-level: Implement retry loop with exponential backoff

## Design Rationale

### Why 12 exceptions?

Instead of using a few generic exceptions (e.g., `error`, `graph-db-error`),
VivaceGraph defines specific exceptions because:

1. **Type safety** — Catch only the errors you can handle
2. **Context** — Each exception carries relevant slot information
3. **Debugging** — Stack traces tell you exactly what went wrong
4. **Recovery** — Different errors need different recovery strategies
5. **Logging** — Can log by exception type for analysis

### Why not more exceptions?

Many systems have 50+ exception types. VivaceGraph has 12 because:

1. **Simplicity** — Easier to understand and remember
2. **Enough coverage** — Still identifies most error scenarios
3. **Composability** — Exceptions with rich slots (instance, reason, etc.) provide context

### Why inheritance (node-already-deleted-error)?

Only 3 exceptions use inheritance:
- `vertex-already-deleted-error` < `node-already-deleted-error`
- `edge-already-deleted-error` < `node-already-deleted-error`

Why?
- Allows **generic** handlers: `(catch 'node-already-deleted-error ...)`
- Allows **specific** handlers: `(catch 'vertex-already-deleted-error ...)`
- Minimizes duplication (:report method inherited)

### Why slots for context?

Each exception has 1-2 slots (instance, reason, host, etc.) because:
- **Debugging** — Know what object failed, not just the error type
- **Logging** — Log the actual values for post-mortem analysis
- **Recovery** — Retry logic may need the actual value (e.g., current-revision)
- **User communication** — Slot values appear in :report messages

## Integration Guide

### For Layer Developers

When implementing a layer (Layer X), follow these guidelines:

**1. Identify what can fail**
```
Example (Layer 4 - Serialization):
- Object has unsupported type → serialization-error
- Bytes are corrupted → deserialization-error
- Type code is invalid → deserialization-error
```

**2. Raise exceptions with context**
```lisp
;; Good: includes object and reason
(error 'serialization-error 
       :instance the-vertex 
       :reason "Unsupported slot type: CUSTOM-STRUCT")

;; Bad: just the error type
(error 'serialization-error)
```

**3. Document in code comments**
```lisp
;; In your function:
;; Raises: serialization-error when object has unsupported slots
;; Raises: transaction-error when constraint violated
```

**4. Don't create new exceptions**
- If none of the 12 exceptions fit, check with the core team
- Usually, an existing exception with a good :reason is better
- Avoid exception proliferation

### For Application Developers

When using VivaceGraph, follow these guidelines:

**1. Know when each exception can be raised**
- Read the layer documentation
- Understand the error scenarios

**2. Implement recovery logic**
```lisp
(handler-case
  (graph-operation ...)
  (stale-revision-error (e)
    ;; Transaction retried automatically
    )
  (serialization-error (e)
    ;; Probably a data/code bug
    (log-and-alert))
  (view-lock-error (e)
    ;; Retry with backoff
    (sleep 0.1)
    (retry-operation ...)))
```

**3. Don't over-catch**
```lisp
;; Bad: catches too much
(handler-case (operation) (error () "try again"))

;; Good: catch specific exceptions
(handler-case (operation)
  (stale-revision-error () (retry))
  (view-lock-error () (retry)))
```

**4. Use condition slots for debugging**
```lisp
(handler-case (operation)
  (nonexistent-key-error (e)
    (format *debug-io* 
            "Key ~S not in ~S~%"
            (nonexistent-key-error-key e)
            (nonexistent-key-error-instance e))))
```

## Common Mistakes and How to Avoid Them

### Mistake 1: Catching too broadly
```lisp
;; Bad
(handler-case (delete-vertex v) (error () "done"))

;; Good
(handler-case (delete-vertex v)
  (vertex-already-deleted-error () "OK, already gone")
  (transaction-error (e) (alert-user (transaction-error-reason e))))
```

### Mistake 2: Not accessing exception slots
```lisp
;; Bad
(handler-case (operation)
  (duplicate-key-error () "error occurred"))

;; Good
(handler-case (operation)
  (duplicate-key-error (e)
    (format t "Duplicate key ~S~%"
            (duplicate-key-error-key e))))
```

### Mistake 3: Raising exception without context
```lisp
;; Bad
(error 'transaction-error)

;; Good
(error 'transaction-error :reason "Foreign key constraint violated")
```

### Mistake 4: Creating new exceptions
```lisp
;; Bad
(define-condition my-custom-error (error) ...)

;; Good
(error 'transaction-error :reason "My custom condition")
```

### Mistake 5: Not documenting which exceptions are raised
```lisp
;; Bad
(defun risky-operation () ...)

;; Good
(defun risky-operation () 
  "Perform risky operation.
   
   Raises: transaction-error - if constraint violated
   Raises: stale-revision-error - if write conflict detected"
  ...)
```

## Summary Table: Exception Reference

| Exception | Layer | Slots | Recovery | Auto-Retry |
|-----------|-------|-------|----------|-----------|
| slave-auth-error | 6 | reason, host | Check creds | With backoff |
| transaction-error | 3 | reason | Depends | Sometimes |
| serialization-error | 4 | instance, reason | Manual | No |
| deserialization-error | 4 | instance, reason | Manual | No |
| stale-revision-error | 3 | instance, revision | Automatic | Yes |
| duplicate-key-error | 2/4 | instance, key | Use upsert | No |
| nonexistent-key-error | 2/4 | instance, key | Check if OK | No |
| node-already-deleted | 3/4 | node | Check type | No |
| vertex-already-deleted | 3/4 | node (inherited) | Check idempotent | No |
| edge-already-deleted | 3/4 | node (inherited) | Check idempotent | No |
| invalid-view-error | 5 | class-name, view-name | Define view | No |
| view-lock-error | 5 | message | Retry | With backoff |

## Next Steps

1. **Implement error handling in each layer** — Use appropriate exceptions
2. **Write layer documentation** — Document which exceptions can be raised
3. **Test exception scenarios** — Write tests for each exception path
4. **Log exceptions systematically** — For debugging and monitoring
5. **Monitor in production** — Track exception frequencies and types

**Ready to implement error handling across all layers!** 🚀

