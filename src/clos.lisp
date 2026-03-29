;;;; src/clos.lisp
;;;; 
;;;; Meta-Object Protocol (MOP) Implementation for VivaceGraph
;;;;
;;;; Purpose:
;;;;   Intercept all slot read/write operations on NODE and its subclasses
;;;;   Route user-defined slots through a persistent plist store (%data)
;;;;   Keep infrastructure slots (meta-slots) direct and fast
;;;;   Trigger transaction enlistment on write
;;;;
;;;; Key Insight:
;;;;   Two-tier storage: meta-slots go to the instance, user slots go to a plist
;;;;   This allows flexible schema (no need to redefine class for new slots)
;;;;   while keeping infrastructure metadata fast and separate
;;;;
;;;; Architecture:
;;;;   graph-class (metaclass, inherits from standard-class)
;;;;     ↓
;;;;   NODE (base class with 13 meta-slots)
;;;;     ↓
;;;;   VERTEX, EDGE (user-defined subclasses)
;;;;
;;;; Interception Points:
;;;;   1. slot-value-using-class :around     — Read interception
;;;;   2. (setf slot-value-using-class) :around — Write interception (CRITICAL)
;;;;   3. slot-makunbound-using-class :around  — Unbind interception

(in-package :graph-db)

;;;; ============================================================================
;;;; META-SLOTS: Infrastructure Metadata
;;;; ============================================================================

(defvar *meta-slots*
  '(id %type-id %revision %deleted-p %heap-written-p %type-idx-written-p %ve-written-p
    %vev-written-p %views-written-p %written-p %data-pointer %data %bytes from to weight)
  "List of slot names that are 'meta' (infrastructure) rather than user-defined.

   Meta-slots are stored directly in the NODE instance using standard slot-value.
   Non-meta slots are stored in a plist (alist) in the %data slot.

   STRUCTURE:
   - id: 16-byte UUID (immutable)
   - %type-id: Type registry ID (unsigned-byte 16) — which def-vertex generated this instance
   - %revision: MVCC version number for ACID isolation
   - %deleted-p: Soft-delete flag (t if marked for deletion)
   - %heap-written-p: Persistence flag — has this node been written to the heap?
   - %type-idx-written-p: Persistence flag — in type-index?
   - %ve-written-p: Persistence flag — in vertex-edge index?
   - %vev-written-p: Persistence flag — in vertex-edge-vertex index?
   - %views-written-p: Persistence flag — in materialized views?
   - %written-p: Overall persistence flag (true if ALL above are persisted)
   - %data-pointer: Address in memory-mapped file (unsigned-byte 64)
   - %data: Plist container for user-defined slots (:key1 val1 :key2 val2 ...)
   - %bytes: Serialized byte representation (lazily computed)
   - from, to, weight: Edge-specific metadata (for EDGE instances)

   NAMING CONVENTION:
   - Slots prefixed with % are meta (infrastructure)
   - Slots without % prefix are user-defined (stored in %data plist)

   USAGE:
   (find slot-name *meta-slots*)  ; Check if slot is meta or user-defined

   NOTES:
   - This list is queried by slot-value-using-class :around method
   - Changes here affect routing of ALL slot access patterns
   - Must include all infrastructure slots defined in NODE class
   - User-defined slots (e.g., :name, :age for def-vertex person) are NOT in this list")

;;;; ============================================================================
;;;; METACLASS DEFINITION: graph-class
;;;; ============================================================================

(defclass graph-class (standard-class)
  ()
  (:documentation "Metaclass for graph database objects.

   ROLE:
   This is a metaclass (class whose instances are classes).
   NODE and its subclasses use graph-class as their metaclass.

   INHERITANCE:
   Inherits from standard-class (the standard CLOS metaclass).

   PURPOSE:
   Provides customization points (MOP hooks) to intercept slot access:
   - direct-slot-definition-class: Returns graph-direct-slot-definition
   - effective-slot-definition-class: Returns graph-effective-slot-definition
   - slot-value-using-class: Intercepts reads
   - (setf slot-value-using-class): Intercepts writes (CRITICAL)
   - slot-makunbound-using-class: Intercepts unbind operations

   EXAMPLE:
   (defclass node ()
     ((id :accessor id :type (array ...)))
     (:metaclass graph-class))  ; <- Uses graph-class as metaclass"))

(defmethod validate-superclass ((class graph-class) (super standard-class))
  "Validate that graph-class can inherit from standard-class.

   CONTEXT:
   The MOP requires metaclasses to declare which superclasses they support.
   This method tells the system: 'Yes, graph-class can inherit from standard-class.'

   ARGS:
   - class: The graph-class instance (the metaclass being defined)
   - super: The superclass being validated (standard-class in this case)

   RETURN:
   T (always) — graph-class is compatible with standard-class

   NOTES:
   - Required by CLOS MOP to allow graph-class to inherit from standard-class
   - If this method returned NIL, the system would signal an error
   - Standard pattern when creating metaclasses

   USAGE:
   (defclass node () ... (:metaclass graph-class))
   ; During class creation, validate-superclass is called to ensure compatibility"
  t)

;;;; ============================================================================
;;;; SLOT DEFINITION CLASSES: MOP Customization Points
;;;; ============================================================================

(defclass graph-slot-definition (standard-slot-definition)
  ()
  (:documentation "Marker class for graph database slots.

   ROLE:
   Base class for graph-specific slot definitions.
   Used as a tagging interface (no additional slots).

   PURPOSE:
   Allows the MOP to distinguish between regular slots and graph slots.
   Subclassed into graph-direct-slot-definition and graph-effective-slot-definition.

   INHERITANCE:
   Inherits from standard-slot-definition (the standard MOP slot definition class).

   NOTES:
   - Currently empty (no additional behavior)
   - Exists for extensibility (future graph-specific slot metadata)
   - All actual behavior is in the direct/effective subclasses"))

(defclass graph-direct-slot-definition
    (standard-direct-slot-definition graph-slot-definition)
  ()
  (:documentation "Graph-specific direct slot definition.

   ROLE:
   Represents a graph slot as specified in class definition (direct form).
   Direct slots are those explicitly written in the class definition.

   EXAMPLE:
   (defclass node ()
     ((id :accessor id :type array)  ; <- This becomes a graph-direct-slot-definition
      (name :accessor name))         ; <- This too
     (:metaclass graph-class))

   INHERITANCE:
   Inherits from standard-direct-slot-definition (MOP standard)
   and graph-slot-definition (graph marker).

   NOTES:
   - Instantiated by direct-slot-definition-class method
   - Converted to effective-slot-definition during class finalization"))

(defclass graph-effective-slot-definition
    (standard-effective-slot-definition graph-slot-definition)
  ()
  (:documentation "Graph-specific effective slot definition.

   ROLE:
   Represents a graph slot in its final, computed form.
   Effective slots are the result of combining direct slots with inheritance.

   PROCESS:
   direct-slot-definition → compute-effective-slot-definition → effective-slot-definition

   EXAMPLE:
   When NODE is finalized:
   - Direct slots from NODE definition become graph-direct-slot-definition
   - Computed together (considering inheritance)
   - Result is graph-effective-slot-definition

   INHERITANCE:
   Inherits from standard-effective-slot-definition (MOP standard)
   and graph-slot-definition (graph marker).

   NOTES:
   - Instantiated by effective-slot-definition-class method
   - Used by slot-value-using-class for actual slot access
   - Carries metadata about how to access each slot"))

;;;; ============================================================================
;;;; MOP HOOK METHODS: Slot Definition Class Selection
;;;; ============================================================================

(defmethod direct-slot-definition-class ((class graph-class) &rest initargs)
  "Return the class to use for direct slot definitions of graph-class instances.

   CONTEXT:
   During class definition, the MOP calls this method to determine what class
   to instantiate for each slot in the class definition.

   ARGS:
   - class: The graph-class being defined
   - initargs: Initialization arguments (ignored)

   RETURN:
   The class graph-direct-slot-definition

   SIDE EFFECTS:
   None (read-only query)

   NOTES:
   - Called during class finalization
   - Allows graph-class to use custom direct slot definition class
   - Standard MOP pattern

   EXAMPLE:
   When this is called:
   (defclass node ()
     ((id :accessor id :type array))  ; <- Needs a slot definition class
     (:metaclass graph-class))

   The MOP calls direct-slot-definition-class, which returns graph-direct-slot-definition,
   so the slot 'id' is represented as a graph-direct-slot-definition instance"
  (declare (ignore initargs))
  (find-class 'graph-direct-slot-definition))

(defmethod effective-slot-definition-class ((class graph-class) &rest initargs)
  "Return the class to use for effective slot definitions of graph-class instances.

   CONTEXT:
   After collecting all direct slot definitions (from the class and its superclasses),
   the MOP calls this method to determine what class to instantiate for the final
   computed slot definitions.

   ARGS:
   - class: The graph-class being finalized
   - initargs: Initialization arguments (ignored)

   RETURN:
   The class graph-effective-slot-definition

   SIDE EFFECTS:
   None (read-only query)

   NOTES:
   - Called during class finalization, after all direct slots are collected
   - Allows graph-class to use custom effective slot definition class
   - Standard MOP pattern

   EXAMPLE:
   When NODE class is finalized:
   1. collect direct slots (from NODE and NODE's superclasses)
   2. Call effective-slot-definition-class for each slot
   3. Compute effective version (resolving overrides, inheritance)
   4. Store result as graph-effective-slot-definition instance"
  (declare (ignore initargs))
  (find-class 'graph-effective-slot-definition))

;;;; ============================================================================
;;;; MOP HOOK: Effective Slot Computation (Currently a No-Op)
;;;; ============================================================================

(defmethod compute-effective-slot-definition :around ((class graph-class) slot-name direct-slots)
  "Compute the effective slot definition for a graph slot.

   CONTEXT:
   The MOP calls this method to compute the final, effective slot definition
   by combining all direct slot definitions (from the class and its superclasses).

   CURRENT IMPLEMENTATION:
   This method is a no-op — it just calls the standard implementation via call-next-method.
   The actual computation happens in standard-class's compute-effective-slot-definition.

   ARGS:
   - class: The graph-class being finalized
   - slot-name: The name of the slot being computed (symbol)
   - direct-slots: List of direct slot definitions with this name
                   (usually 1, but can be more if overridden in subclasses)

   RETURN:
   The computed effective slot definition (a graph-effective-slot-definition)

   SIDE EFFECTS:
   Modifies the class during finalization (adds effective slots)

   NOTES:
   - The :around method allows us to wrap the standard computation
   - Currently does nothing special (just calls call-next-method)
   - TODO: Is this method necessary? Why is it defined if it's a no-op?
   - Possible future use: custom validation, metadata computation

   EXAMPLE:
   When NODE is finalized:
   1. For slot 'id': direct-slots = [graph-direct-slot-definition for 'id']
   2. Call compute-effective-slot-definition :around
   3. Returns: graph-effective-slot-definition for 'id'
   4. Stored in the finalized NODE class

   WARNING:
   If this method needs custom behavior, it's currently missing.
   Investigate before shipping to production."
  (let ((slot (call-next-method)))
    ;;
    ;; TODO: What goes here? This is a placeholder.
    ;; Options:
    ;; - Add custom metadata to the slot
    ;; - Validate slot type declarations
    ;; - Transform slot initialization
    ;;
    slot))

;;;; ============================================================================
;;;; MOP INTERCEPTION: SLOT-VALUE READ
;;;; ============================================================================

(defmethod slot-value-using-class :around ((class graph-class) instance slot)
  "Intercept slot value reads. Route meta-slots directly; user slots from plist.

   CONTEXT:
   Every time a user reads a slot value (e.g., (slot-value obj 'name)),
   the MOP calls this method. We use :around to customize the behavior:
   - If the slot is meta (infrastructure), use standard slot-value
   - If the slot is user-defined, read from the plist in %data

   ARGS:
   - class: The graph-class of the instance (graph-class)
   - instance: The NODE instance being read
   - slot: The effective slot definition (graph-effective-slot-definition)

   RETURN:
   The slot value (from either direct slot or plist)

   SIDE EFFECTS:
   None (read-only operation)

   ALGORITHM:
   1. Get the slot name from the effective slot definition
   2. Check if slot-name is in *meta-slots*
   3. If YES: Return standard slot-value (direct access)
   4. If NO:  Construct a keyword symbol from the slot name
              Search the plist in (data instance) for that keyword
              Return the value (or NIL if not found)

   NOTES:
   - This method is called for EVERY slot read on NODE instances
   - Performance-critical (executed frequently)
   - Meta-slots (step 3) are fast: direct CPU access
   - User slots (step 4) are slower: plist search (O(n) where n = user slots)
   
   RISK:
   - If (data instance) is NIL and slot is user-defined, returns NIL (no error)
   - Silent failure if plist is corrupted or missing

   EXAMPLE:
   User code:
     (let ((node (make-vertex \"person\")))
       (id node))  ; <- Read meta-slot

   Call stack:
     (slot-value node 'id)
     → slot-value-using-class :around
     → slot-name = 'id
     → (find 'id *meta-slots*) => T (meta-slot)
     → call-next-method
     → standard slot-value retrieves from instance slot
     → Returns 16-byte UUID

   User code:
     (let ((node (make-vertex \"person\")))
       (name node))  ; <- Read user-defined slot

   Call stack:
     (slot-value node 'name)
     → slot-value-using-class :around
     → slot-name = 'name
     → (find 'name *meta-slots*) => NIL (user-defined)
     → key = (intern \"NAME\" :keyword) => :NAME
     → (assoc :name (data instance)) => (:name . \"Alice\")
     → (cdr ...) => \"Alice\"
     → Returns \"Alice\""
  (let ((slot-name (sb-mop:slot-definition-name slot)))
    (if (find slot-name *meta-slots*)
        ;; Meta-slot: use standard slot-value directly
        (call-next-method)
        ;; User-defined slot: read from plist in %data
        (let ((key (intern (symbol-name slot-name) :keyword)))
          (cdr (assoc key (data instance)))))))

;;;; ============================================================================
;;;; MOP INTERCEPTION: SLOT-VALUE WRITE (CRITICAL)
;;;; ============================================================================

(defmethod (setf slot-value-using-class) :around (new-value (class graph-class) instance slot)
  "Intercept slot value writes. Update plist and trigger transaction enlistment.

   CONTEXT:
   Every time a user writes a slot value (e.g., (setf (slot-value obj 'name) val)),
   the MOP calls this method. We use :around to:
   - Route to direct slot or plist (like the read method)
   - ADDITIONALLY: Trigger transaction enlistment or immediate persistence

   ARGS:
   - new-value: The value being assigned
   - class: The graph-class of the instance (graph-class)
   - instance: The NODE instance being written
   - slot: The effective slot definition (graph-effective-slot-definition)

   RETURN:
   new-value (unchanged, following Common Lisp convention)

   SIDE EFFECTS:
   - Updates slot (direct or plist)
   - If inside transaction: Enlists instance in txn-update-queue
   - If outside transaction: Calls save-node to persist immediately

   ALGORITHM:
   1. Get the slot name from the effective slot definition
   2. Check if slot-name is in *meta-slots*
   3. If YES: Call standard setf slot-value (direct update, no transaction)
   4. If NO:  Update plist in (data instance):
              - key = (intern slot-name :keyword)
              - (setf (cdr (assoc key (data instance))) new-value)
   5. TRANSACTION HANDLING:
      - If *current-transaction* is bound (inside with-transaction):
        → Enlist instance: (pushnew instance (txn-update-queue txn) ...)
        → Deferred persistence (happens at transaction commit)
      - If *current-transaction* is NIL (outside transaction):
        → Immediate persistence: (save-node instance)

   CRITICAL BEHAVIOR:
   This method is the KEY TRANSACTION ENLISTMENT POINT.
   Every user slot write INSIDE a transaction is recorded.
   Every user slot write OUTSIDE a transaction is persisted immediately.

   NOTES:
   - Meta-slots BYPASS transaction enlistment
   - User-slot writes ALWAYS trigger persistence (either now or at commit)
   - Depends on *current-transaction* being bound by transactions.lisp
   - Depends on save-node being defined (Layer 6)
   - Performance: User-slot writes are slower (plist update + transaction logic)

   RISK:
   - If save-node fails outside transaction, partial update (corrupted state)
   - If *current-transaction* is corrupted, txn-update-queue may fail
   - Immediate persistence (outside txn) may conflict with concurrent readers

   EXAMPLE:
   User code inside transaction:
     (with-transaction (g)
       (let ((v (make-vertex g \"person\")))
         (setf (name v) \"Alice\")))  ; <- Enlist in transaction

   Call stack:
     (setf (slot-value v 'name) \"Alice\")
     → (setf slot-value-using-class) :around
     → slot-name = 'name
     → (find 'name *meta-slots*) => NIL (user-defined)
     → key = :name
     → (setf (cdr (assoc :name (data v))) \"Alice\")
     → *current-transaction* is bound => TRUE
     → (pushnew v (txn-update-queue *current-transaction*) ...)
     → Returns \"Alice\"

   User code outside transaction:
     (let ((v (make-vertex g \"person\")))
       (setf (name v) \"Alice\"))  ; <- Save immediately

   Call stack:
     (setf (slot-value v 'name) \"Alice\")
     → (setf slot-value-using-class) :around
     → slot-name = 'name
     → (find 'name *meta-slots*) => NIL (user-defined)
     → key = :name
     → (setf (cdr (assoc :name (data v))) \"Alice\")
     → *current-transaction* is NIL => FALSE
     → (save-node v)  ; Immediate persistence
     → Returns \"Alice\""
  (let ((slot-name (sb-mop:slot-definition-name slot)))
    (if (find slot-name *meta-slots*)
        ;; Meta-slot: use standard setf directly (no transaction)
        (call-next-method)
        ;; User-defined slot: update plist and enlist in transaction or save
        (let ((key (intern (symbol-name slot-name) :keyword)))
          (setf (cdr (assoc key (data instance))) new-value)
          (if *current-transaction*
              ;; Inside transaction: deferred persistence
              (pushnew instance (txn-update-queue *current-transaction*) :test 'equalp :key 'id)
              ;; Outside transaction: immediate persistence
              (save-node instance))))))

;;;; ============================================================================
;;;; MOP INTERCEPTION: SLOT-MAKUNBOUND (UNBIND/DELETE)
;;;; ============================================================================

(defmethod slot-makunbound-using-class :around ((class graph-class) instance slot)
  "Intercept slot unbind operations. Remove from plist if user-defined.

   CONTEXT:
   When a user unbinds a slot (e.g., (slot-makunbound obj 'name)),
   the MOP calls this method. We customize the behavior:
   - If meta-slot: use standard unbind (rare)
   - If user-slot: remove from plist

   ARGS:
   - class: The graph-class of the instance (graph-class)
   - instance: The NODE instance being modified
   - slot: The effective slot definition (graph-effective-slot-definition)

   RETURN:
   instance (following MOP convention)

   SIDE EFFECTS:
   - Removes slot from %data plist (or standard unbind for meta-slot)

   ALGORITHM:
   1. Get the slot name from the effective slot definition
   2. Check if slot-name is in *meta-slots*
   3. If YES: Call standard slot-makunbound (removes direct slot binding)
   4. If NO:  Remove from plist in (data instance):
              - key = (intern slot-name :keyword)
              - (setf (data instance) (delete key (data instance) :key 'car))

   NOTES:
   - Opposite operation: removes a slot value entirely (not just sets to NIL)
   - For user-slots: subsequent reads will return NIL (key not in plist)
   - Meta-slots are usually not unbound (infrastructure needs them)

   RISK:
   - Unbound user-slots become indistinguishable from never-set slots
   - No error on unbinding non-existent slot

   EXAMPLE:
   User code:
     (let ((v (make-vertex \"person\")))
       (setf (name v) \"Alice\")
       (slot-makunbound v 'name)
       (name v))  ; => NIL (now unbound)

   Call stack for slot-makunbound:
     (slot-makunbound v 'name)
     → slot-makunbound-using-class :around
     → slot-name = 'name
     → (find 'name *meta-slots*) => NIL (user-defined)
     → key = :name
     → (setf (data v) (delete :name (data v) :key 'car))
     → (data v) before: (:name . \"Alice\")
     → (data v) after: NIL
     → Returns v

   Subsequent read:
     (name v)
     → slot-value-using-class :around
     → (assoc :name nil) => NIL
     → Returns NIL"
  (let ((slot-name (sb-mop:slot-definition-name slot)))
    (if (find slot-name *meta-slots*)
        ;; Meta-slot: use standard unbind
        (call-next-method)
        ;; User-defined slot: remove from plist
        (let ((key (intern (symbol-name slot-name) :keyword)))
          (setf (data instance) (delete key (data instance) :key 'car))
          instance))))

;;;; ============================================================================
;;;; NODE: Base Class with Meta-Slots
;;;; ============================================================================

(defclass node ()
  "Base class for all graph database objects (vertices, edges, etc).

   ROLE:
   NODE is the fundamental persistent object type in VivaceGraph.
   All user-defined data types (created via def-vertex, def-edge) inherit from NODE.

   METACLASS:
   Uses graph-class as its metaclass, enabling MOP interception for flexible schema.

   STRUCTURE:
   NODE has 13 meta-slots (infrastructure) and can store unlimited user-defined slots
   in the %data plist.

   STORAGE MODEL:
   Meta-slots:
     - Stored directly in the NODE instance (fast, direct CPU access)
     - Examples: id, %type-id, %revision, %data

   User-defined slots:
     - Stored in the %data plist (slower, but flexible)
     - Examples: name, age, email (for def-vertex person ...)
     - Not declared in NODE class; added dynamically via def-vertex

   INSTANCE EXAMPLE:
   (let ((v (make-vertex \"person\")))
     (setf (name v) \"Alice\")    ; User-defined slot (stored in %data)
     (setf (age v) 30)             ; User-defined slot (stored in %data)
     (id v)                         ; Meta-slot (direct access)
     (data v))                      ; Plist: (:name . \"Alice\") (:age . 30)

   LIFECYCLE:
   1. Create instance: (make-vertex graph type)
   2. Set user slots: (setf (name v) ...)
   3. Persist: (save-node v) OR via transaction
   4. Update: (setf (name v) ...) triggers persistence
   5. Delete: (slot-makunbound v 'deleted-p) or (mark-deleted v)

   ATTRIBUTES:
   (13 meta-slots, all infrastructure)"
  ;; META-SLOT: id (Node identifier)
  ((id :accessor id :initform +null-key+ :initarg :id
       :type (simple-array (unsigned-byte 8) (16))
       :documentation "Immutable 16-byte UUID identifying this node. Generated via gen-id().
                       Unique across all nodes in the graph database.")

   ;; META-SLOT: %type-id (Type registry reference)
   (%type-id :accessor %type-id :initform 1 :initarg :%type-id
            :type (unsigned-byte 16)
            :documentation "Type identifier (integer). References the type registry.
                           1 = generic NODE, 2+ = def-vertex/def-edge types.")

   ;; META-SLOT: %revision (MVCC version)
   (%revision :accessor %revision :initform 0 :initarg :%revision
             :type (unsigned-byte 32)
             :documentation "MVCC version number (0, 1, 2, ...). Incremented on each write.
                            Used for transaction isolation (snapshot consistency).")

   ;; META-SLOT: %deleted-p (Soft-delete flag)
   (%deleted-p :accessor %deleted-p :initform nil :initarg :%deleted-p :type boolean
              :documentation "Soft-delete flag (t/nil). If true, node is logically deleted.
                             Physical removal via garbage collection (Layer 3).")

   ;; META-SLOT: %heap-written-p (Heap persistence flag)
   (%heap-written-p :accessor %heap-written-p :initform nil :initarg :%heap-written-p
                   :type boolean
                   :documentation "Persistence flag: Has this node been written to the memory-mapped heap?")

   ;; META-SLOT: %type-idx-written-p (Type index persistence flag)
   (%type-idx-written-p :accessor %type-idx-written-p :initform nil
                       :initarg :%type-idx-written-p :type boolean
                       :documentation "Persistence flag: Has this node been indexed by type?")

   ;; META-SLOT: %ve-written-p (Vertex-edge index persistence flag)
   (%ve-written-p :accessor %ve-written-p :initform nil :initarg :%ve-written-p
                 :type boolean
                 :documentation "Persistence flag: Has this node been indexed in VE-index (vertex edges)?")

   ;; META-SLOT: %vev-written-p (Vertex-edge-vertex index persistence flag)
   (%vev-written-p :accessor %vev-written-p :initform nil :initarg :%vev-written-p
                  :type boolean
                  :documentation "Persistence flag: Has this node been indexed in VEV-index?")

   ;; META-SLOT: %views-written-p (Materialized views flag)
   (%views-written-p :accessor %views-written-p :initform nil
                    :initarg :%views-written-p :type boolean
                    :documentation "Persistence flag: Has this node been indexed in materialized views?")

   ;; META-SLOT: %written-p (Overall persistence flag)
   (%written-p :accessor %written-p :initform nil :initarg :%written-p :type boolean
              :documentation "Overall persistence flag: true if ALL of the above flags are true.
                             Indicates node is fully persisted across all indexes.")

   ;; META-SLOT: %data-pointer (Memory address)
   (%data-pointer :accessor %data-pointer :initform 0 :initarg :%data-pointer
                 :type (unsigned-byte 64)
                 :documentation "Address in the memory-mapped file where this node's data is stored.
                                Used by Layer 4 (serialize.lisp) and Layer 2 (mmap.lisp).")

   ;; META-SLOT: %data (Plist container for user slots)
   (%data :accessor %data :initarg :%data :initform nil
         :documentation "Plist (alist) container for user-defined slots.
                        Format: ((:key1 . value1) (:key2 . value2) ...)
                        User-defined slots are read/written through this plist via MOP interception.
                        Example: (:name . \"Alice\") (:age . 30) for a person vertex.")

   ;; META-SLOT: %bytes (Serialized representation)
   (%bytes :accessor %bytes :initform :init :initarg :%bytes
          :documentation "Serialized byte representation of this node (lazily computed).
                         Used for persistence layer (serialize.lisp).
                         Initform :init means 'not yet serialized'; computed on-demand via serialize-node."))

  (:metaclass graph-class)
  (:documentation "Base class for all persistent graph database objects.

   This class defines the 13 meta-slots that every node must have.
   User-defined slots (from def-vertex, def-edge) are stored in the %data plist,
   not as direct slots on the NODE class.

   DIRECT SUBCLASSES:
   - VERTEX (created by def-vertex)
   - EDGE (created by def-edge)
   - Potentially other domain-specific types

   INHERITANCE NOTES:
   - Subclasses inherit these 13 slots
   - Subclasses do NOT add direct slots (those go to %data)
   - Slots starting with % are meta-infrastructure
   - User-defined slots (without %) are accessed through %data plist"))
   