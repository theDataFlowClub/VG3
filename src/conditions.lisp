;;;; -*- Mode: Lisp; Package: :graph-db -*-
;;;; src/conditions.lisp
;;;;
;;;; Exception Class Definitions for VivaceGraph
;;;;
;;;; Purpose:
;;;;   Define all custom exception types used throughout the codebase.
;;;;   These conditions provide structured error information while
;;;;   also offering human-readable :report output for end users.
;;;;
;;;;   Exception hierarchy enables:
;;;;   - Specific catch handlers for different error types
;;;;   - Generic catch handlers for error families
;;;;   - Programmatic access to error context (via slots)
;;;;   - User-friendly error messages (via :report)
;;;;
;;;; Design Pattern:
;;;;   Each exception class includes:
;;;;   1. Named slots for context (what failed, why, where)
;;;;   2. :initarg for each slot (required at instantiation)
;;;;   3. :report method (converts exception to readable string)
;;;;
;;;; Usage Example:
;;;;   (error 'transaction-error :reason "Constraint violation")
;;;;   ;; User sees: "Transaction error: Constraint violation."
;;;;
;;;;   (handler-case
;;;;     (risky-operation)
;;;;     (stale-revision-error (e)
;;;;       ;; Access slot: (slot-value e 'current-revision)
;;;;       (retry-with-newer-revision (slot-value e 'instance))))
;;;;
;;;; Hierarchy:
;;;;   error (standard CL condition)
;;;;   ├─ slave-auth-error (replication authentication failure)
;;;;   ├─ transaction-error (ACID transaction failure)
;;;;   ├─ serialization-error (object → bytes conversion fails)
;;;;   ├─ deserialization-error (bytes → object conversion fails)
;;;;   ├─ stale-revision-error (MVCC conflict)
;;;;   ├─ duplicate-key-error (index uniqueness violation)
;;;;   ├─ nonexistent-key-error (index lookup failure)
;;;;   ├─ node-already-deleted-error (attempted re-delete) [BASE CLASS]
;;;;   │  ├─ vertex-already-deleted-error (vertex-specific)
;;;;   │  └─ edge-already-deleted-error (edge-specific)
;;;;   ├─ invalid-view-error (view does not exist)
;;;;   └─ view-lock-error (view locking/deadlock failure)

(in-package :graph-db)

;;;; ============================================================================
;;;; REPLICATION LAYER EXCEPTIONS
;;;; ============================================================================

(define-condition slave-auth-error (error)
  ((reason :initarg :reason
           :reader slave-auth-reason
           :documentation "Description of why authentication failed.")
   (host :initarg :host
         :reader slave-auth-host
         :documentation "Hostname or IP of the slave attempting to connect."))
  
  (:documentation
   "Exception raised when a slave database fails to authenticate with master.
    
    This is raised during replication setup or sync operations when a slave
    cannot authenticate its credentials with the master database.
    
    Slots:
      REASON - String explaining the authentication failure
               (e.g., \"Invalid replication key\", \"Incorrect credentials\")
      HOST - Hostname or IP address of the slave attempting connection
    
    When to raise:
      When a slave connects to master and fails authentication.
    
    Example:
      (error 'slave-auth-error 
             :host \"192.168.1.100\" 
             :reason \"Replication key mismatch\")
    
    User sees: \"Slave auth error 192.168.1.100: Replication key mismatch.\"
    
    Recovery:
      Check replication credentials on both master and slave.
      Verify network connectivity to master.
      Ensure replication is properly configured.")
  
  (:report (lambda (error stream)
             ;; Format: "Slave auth error <HOST>: <REASON>."
             ;; Provides immediate identification of which slave and why it failed
             (with-slots (reason host) error
               (format stream "Slave auth error ~A: ~A." host reason)))))

;;;; ============================================================================
;;;; TRANSACTION LAYER EXCEPTIONS
;;;; ============================================================================

(define-condition transaction-error (error)
  ((reason :initarg :reason
           :reader transaction-error-reason
           :documentation "Description of the transaction failure."))
  
  (:documentation
   "Exception raised when an ACID transaction fails.
    
    This is a generic transaction error covering various failures such as:
    - Constraint violations
    - Deadlocks
    - Lock timeouts
    - Rollback requests
    - Commit failures
    
    Slots:
      REASON - String explaining why the transaction failed
               (e.g., \"Constraint violation\", \"Deadlock detected\")
    
    When to raise:
      When any transaction operation fails and no more specific exception applies.
    
    Example:
      (error 'transaction-error 
             :reason \"Foreign key constraint violated\")
    
    User sees: \"Transaction error: Foreign key constraint violated.\"
    
    Recovery:
      Typically requires retrying the transaction.
      May need to modify data to satisfy constraints.
      May need to adjust locking behavior or timeout settings.")
  
  (:report (lambda (error stream)
             ;; Format: "Transaction error: <REASON>."
             ;; Simple, direct message for generic transaction failures
             (with-slots (reason) error
               (format stream "Transaction error: ~A." reason)))))

;;;; ============================================================================
;;;; SERIALIZATION LAYER EXCEPTIONS
;;;; ============================================================================

(define-condition serialization-error (error)
  ((instance :initarg :instance
             :reader serialization-error-instance
             :documentation "The object that failed to serialize.")
   (reason :initarg :reason
           :reader serialization-error-reason
           :documentation "Explanation of why serialization failed."))
  
  (:documentation
   "Exception raised when an object cannot be serialized to bytes.
    
    Serialization is the process of converting Lisp objects into a
    byte representation for storage in the mmap heap.
    
    This exception indicates the conversion process failed, typically because:
    - The object contains unsupported data types
    - A slot has an invalid value
    - Memory allocation failed
    - Type code resolution failed
    
    Slots:
      INSTANCE - The object being serialized (vertex, edge, etc.)
                 Useful for identifying which object caused the problem
      REASON - String explaining why serialization failed
               (e.g., \"Unknown type code: CUSTOM-TYPE\")
    
    When to raise:
      When Layer 4 (serialize.lisp) attempts to convert an object
      and encounters a type or format error.
    
    Example:
      (error 'serialization-error 
             :instance my-vertex 
             :reason \"Unsupported slot type: #<STRUCTURE>\")
    
    User sees: \"Serialization failed for #<VERTEX ...> because of Unsupported slot type: #<STRUCTURE>.\"
    
    Recovery:
      Verify the object's slots contain only serializable types.
      Check that custom types are properly registered.
      Ensure sufficient memory for serialization.")
  
  (:report (lambda (error stream)
             ;; Format: "Serialization failed for <INSTANCE> because of <REASON>."
             ;; Two-part message: what failed and why
             ;; Helps debug by showing both object and error reason
             (with-slots (instance reason) error
               (format stream "Serialization failed for ~a because of ~a."
                       instance reason)))))

(define-condition deserialization-error (error)
  ((instance :initarg :instance
             :reader deserialization-error-instance
             :documentation "The data (bytes or reference) being deserialized.")
   (reason :initarg :reason
           :reader deserialization-error-reason
           :documentation "Explanation of why deserialization failed."))
  
  (:documentation
   "Exception raised when bytes cannot be deserialized back to an object.
    
    Deserialization is the inverse of serialization: reading bytes from
    the mmap heap and reconstructing them as Lisp objects.
    
    This exception indicates the conversion process failed, typically because:
    - Type code is invalid or unknown
    - Byte format is corrupted
    - Type mismatch between expected and actual
    - Memory is uninitialized or pointing to invalid location
    
    Slots:
      INSTANCE - The data being deserialized (byte array, mmap pointer, etc.)
                 Useful for identifying which data caused the problem
      REASON - String explaining why deserialization failed
               (e.g., \"Invalid type code: 255\")
    
    When to raise:
      When Layer 4 (serialize.lisp) attempts to read bytes and
      encounters a type, format, or corruption error.
    
    Example:
      (error 'deserialization-error 
             :instance corrupted-bytes 
             :reason \"Invalid type code: 255\")
    
    User sees: \"Deserialization failed for #(255 0 0...) because of Invalid type code: 255.\"
    
    Recovery:
      Check for data corruption (checksum, parity).
      Verify the byte format matches the expected schema version.
      May indicate disk corruption or memory corruption.
      Consider backing up and recovering from backup.")
  
  (:report (lambda (error stream)
             ;; Format: "Deserialization failed for <INSTANCE> because of <REASON>."
             ;; Mirror of serialization-error for symmetry
             ;; Helps debug by showing what data failed and why
             (with-slots (instance reason) error
               (format stream "Deserialization failed for ~a because of ~a."
                       instance reason)))))

;;;; ============================================================================
;;;; CONCURRENCY CONTROL EXCEPTIONS
;;;; ============================================================================

(define-condition stale-revision-error (error)
  ((instance :initarg :instance
             :reader stale-revision-error-instance
             :documentation "The object whose update conflicted.")
   (current-revision :initarg :current-revision
                     :reader stale-revision-error-revision
                     :documentation "The revision number that is now current."))
  
  (:documentation
   "Exception raised when attempting to update a stale object (MVCC conflict).
    
    VivaceGraph uses Multi-Version Concurrency Control (MVCC) to allow
    multiple transactions to read without blocking writes, and writes
    without blocking reads.
    
    However, when two transactions both try to write to the same object,
    a conflict occurs:
    - Transaction A reads object at revision N
    - Transaction B updates object to revision N+1
    - Transaction A tries to commit its changes based on revision N
    - Conflict! Transaction A's revision is stale.
    
    This exception signals that conflict.
    
    Slots:
      INSTANCE - The object that was updated by another transaction
      CURRENT-REVISION - The revision number that is now current
    
    When to raise:
      When a transaction attempts to commit writes but another transaction
      has already updated the object to a newer revision.
    
    Example:
      (error 'stale-revision-error 
             :instance person-vertex 
             :current-revision 5)
    
    User sees: \"Attempt to update stale revision #<VERTEX ...> of 5.\"
    
    Recovery:
      Retry the transaction. The transaction framework will:
      1. Read the object again (now at revision 5 or higher)
      2. Recompute the update based on the current state
      3. Attempt to commit again
      
      Retrying usually succeeds unless the same object is
      continuously modified by many transactions.")
  
  (:report (lambda (error stream)
             ;; Format: "Attempt to update stale revision <INSTANCE> of <REVISION>."
             ;; Emphasizes the conflict: attempting write on outdated version
             ;; The revision number helps debugging and logging
             (with-slots (instance current-revision) error
               (format stream "Attempt to update stale revision ~S of ~S."
                       instance current-revision)))))

;;;; ============================================================================
;;;; INDEX EXCEPTIONS
;;;; ============================================================================

(define-condition duplicate-key-error (error)
  ((instance :initarg :instance
             :reader duplicate-key-error-instance
             :documentation "The index or table where the key already exists.")
   (key :initarg :key
        :reader duplicate-key-error-key
        :documentation "The key value that already exists."))
  
  (:documentation
   "Exception raised when inserting a duplicate key into a unique index.
    
    Indexes can have a UNIQUE constraint, meaning each key appears at most once.
    Attempting to insert a key that already exists violates this constraint.
    
    Examples of unique indexes:
    - Primary key indexes (each vertex/edge has unique ID)
    - UNIQUE column indexes
    - Type indexes (each node type appears once in type registry)
    
    Slots:
      INSTANCE - The index, table, or collection being updated
      KEY - The duplicate key that was rejected
    
    When to raise:
      When Layer 2 (indexing) detects an attempt to insert a key
      that already exists in a unique index.
    
    Example:
      (error 'duplicate-key-error 
             :instance type-index 
             :key vertex-id)
    
    User sees: \"Duplicate key #(0xAB 0xCD...) in #<TYPE-INDEX>.\"
    
    Recovery:
      Check if the key already exists in the index.
      If yes, consider an update operation instead of insert.
      If no, investigate why constraint violation is being reported.
      May indicate duplicate data being loaded or imported.")
  
  (:report (lambda (error stream)
             ;; Format: "Duplicate key <KEY> in <INSTANCE>."
             ;; Simple and direct: identifies both key and index
             ;; Helps identify constraint violations in data operations
             (with-slots (instance key) error
               (format stream "Duplicate key ~S in ~S."
                       key instance)))))

(define-condition nonexistent-key-error (error)
  ((instance :initarg :instance
             :reader nonexistent-key-error-instance
             :documentation "The index or table being queried.")
   (key :initarg :key
        :reader nonexistent-key-error-key
        :documentation "The key that does not exist."))
  
  (:documentation
   "Exception raised when looking up or deleting a non-existent key.
    
    This occurs when:
    - Attempting to look up a key that doesn't exist in an index
    - Attempting to delete a key that doesn't exist
    - Accessing a key that should exist but doesn't (data corruption?)
    
    Slots:
      INSTANCE - The index, table, or collection being queried
      KEY - The key that was not found
    
    When to raise:
      When Layer 2 (indexing) or Layer 4 (serialization) detects
      an attempt to access a key that doesn't exist.
    
    Example:
      (error 'nonexistent-key-error 
             :instance ve-index 
             :key edge-id)
    
    User sees: \"Nonexistent key #(0xDE 0xAD...) in #<VE-INDEX>.\"
    
    Recovery:
      For lookups: This is expected in queries that find nothing.
      Use this to distinguish \"not found\" from \"index error\".
      
      For deletes: Check if the key was already deleted.
      May indicate race condition or data corruption.
      
      For access: May signal data corruption. Investigate.")
  
  (:report (lambda (error stream)
             ;; Format: "Nonexistent key <KEY> in <INSTANCE>."
             ;; Mirror of duplicate-key-error for symmetry
             ;; Clear identification of missing key
             (with-slots (instance key) error
               (format stream "Nonexistent key ~S in ~S."
                       key instance)))))

;;;; ============================================================================
;;;; NODE LIFECYCLE EXCEPTIONS
;;;; ============================================================================

(define-condition node-already-deleted-error (error)
  ((node :initarg :node
         :reader node-already-deleted-node
         :documentation "The node that is already deleted."))
  
  (:documentation
   "BASE EXCEPTION: Node has already been deleted.
    
    VivaceGraph uses soft deletes (marking nodes as deleted rather than
    immediately removing them). This exception signals an attempt to
    delete a node that's already marked as deleted.
    
    This is a base class with two specializations:
    - vertex-already-deleted-error (for vertices)
    - edge-already-deleted-error (for edges)
    
    Slots:
      NODE - The vertex or edge that is already deleted
    
    When to raise:
      When attempting to delete a node that has %deleted-p = T.
    
    Example:
      (error 'node-already-deleted-error :node my-vertex)
    
    User sees: \"Node #<VERTEX ...> already deleted\"
    
    Recovery:
      Idempotent operation: deleting an already-deleted node.
      Some applications treat this as success (already gone).
      Others treat it as an error (attempting to delete twice).
      
      Can be caught generically:
        (catch 'node-already-deleted-error ...)
      
      Can be caught specifically:
        (catch 'vertex-already-deleted-error ...)
        (catch 'edge-already-deleted-error ...)")
  
  (:report (lambda (error stream)
             ;; Format: "Node <NODE> already deleted"
             ;; Simple message identifying the deleted node
             ;; No period at end (base class style)
             (with-slots (node) error
               (format stream "Node ~A already deleted" node)))))

(define-condition vertex-already-deleted-error (node-already-deleted-error)
  ()
  
  (:documentation
   "Exception: Vertex has already been deleted (specialization).
    
    This is a specialization of node-already-deleted-error for vertices.
    
    Allows vertex-specific error handling:
      (catch 'vertex-already-deleted-error
        (delete-vertex v))  ; Catches only vertex deletion errors
    
    Generic node deletion errors:
      (catch 'node-already-deleted-error
        (delete-node n))  ; Catches both vertex and edge deletion errors
    
    Slots: Inherited from node-already-deleted-error
      NODE - The vertex that is already deleted
    
    Example:
      (error 'vertex-already-deleted-error :node my-vertex)
    
    User sees: \"Node #<VERTEX ...> already deleted\"
    
    Usage note:
      Preferred when you know you're deleting a vertex.
      Allows callers to handle vertex and edge deletion
      errors differently if needed."))

(define-condition edge-already-deleted-error (node-already-deleted-error)
  ()
  
  (:documentation
   "Exception: Edge has already been deleted (specialization).
    
    This is a specialization of node-already-deleted-error for edges.
    
    Allows edge-specific error handling:
      (catch 'edge-already-deleted-error
        (delete-edge e))  ; Catches only edge deletion errors
    
    Generic node deletion errors:
      (catch 'node-already-deleted-error
        (delete-node n))  ; Catches both vertex and edge deletion errors
    
    Slots: Inherited from node-already-deleted-error
      NODE - The edge that is already deleted
    
    Example:
      (error 'edge-already-deleted-error :node my-edge)
    
    User sees: \"Node #<EDGE ...> already deleted\"
    
    Usage note:
      Preferred when you know you're deleting an edge.
      Allows callers to handle vertex and edge deletion
      errors differently if needed."))

;;;; ============================================================================
;;;; VIEW LAYER EXCEPTIONS
;;;; ============================================================================

(define-condition invalid-view-error (error)
  ((class-name :initarg :class-name
               :reader invalid-view-error-class
               :documentation "Name of the class (vertex type) the view was requested on.")
   (view-name :initarg :view-name
              :reader invalid-view-error-view
              :documentation "Name of the view that does not exist."))
  
  (:documentation
   "Exception raised when attempting to invoke a non-existent view.
    
    Views are named queries or materializations defined on vertex/edge types.
    For example, a PERSON class might have views like:
    - AGE_DISTRIBUTION (histogram of ages)
    - FRIEND_COUNT (count of friends per person)
    - ACTIVE_USERS (filter of active users)
    
    This exception signals an attempt to use a view that hasn't been defined.
    
    Slots:
      CLASS-NAME - Name of the vertex or edge type
                   (e.g., \"PERSON\", \"EDGE\")
      VIEW-NAME - Name of the non-existent view
                  (e.g., \"MISSING_AGGREGATION\")
    
    When to raise:
      When Layer 5 (views.lisp) receives a request for a view
      that isn't registered on the given class.
    
    Example:
      (error 'invalid-view-error 
             :class-name \"PERSON\" 
             :view-name \"NONEXISTENT_VIEW\")
    
    User sees: \"No such graph view: PERSON/NONEXISTENT_VIEW\"
    
    Recovery:
      Define the view using (def-view class-name view-name ...).
      Check the correct spelling of view name.
      Verify the view is registered on the correct class.
      Use (list-views class-name) to see available views.")
  
  (:report (lambda (error stream)
             ;; Format: "No such graph view: <CLASS-NAME>/<VIEW-NAME>"
             ;; Two-level namespace: class/view for clarity
             ;; Standard filesystem-like path notation makes it clear
             (with-slots (class-name view-name) error
               (format stream
                       "No such graph view: ~A/~A"
                       class-name view-name)))))

(define-condition view-lock-error (error)
  ((message :initarg :message
            :reader view-lock-error-message
            :documentation "Description of the locking error."))
  
  (:documentation
   "Exception raised when view operations encounter locking problems.
    
    View reduction and aggregation operations use locks to ensure
    consistency. This exception signals locking failures such as:
    - Deadlock detected
    - Lock acquisition timeout
    - Lock request on invalid object
    - Inconsistent lock state
    
    Slots:
      MESSAGE - String describing the locking problem
                (e.g., \"Deadlock in view reduction\")
    
    When to raise:
      When Layer 5 (views.lisp) encounters a locking error during
      view computation or aggregation.
    
    Example:
      (error 'view-lock-error 
             :message \"Deadlock detected in view aggregation\")
    
    User sees: \"View locking error: 'Deadlock detected in view aggregation'\"
    
    Recovery:
      Retry the view operation. Deadlocks are usually transient.
      If persistent, check for circular lock dependencies.
      May need to increase lock timeout settings.
      Investigate transaction order if deadlocks are frequent.
      
      Consider redesigning view computation to avoid nested locks.")
  
  (:report (lambda (error stream)
             ;; Format: "View locking error: '<MESSAGE>'"
             ;; Single quotes around message for clarity
             ;; Helps distinguish message from format wrapper
             (with-slots (message) error
               (format stream
                       "View locking error: '~A'"
                       message)))))

;;;; ============================================================================
;;;; END OF CONDITIONS
;;;; ============================================================================

(in-package :cl-user)