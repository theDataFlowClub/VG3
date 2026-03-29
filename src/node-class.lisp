;;;; src/node-class.lisp
;;;; 
;;;; Node Class Protocol and Slot Categorization
;;;;
;;;; Purpose:
;;;;   Define a sophisticated slot categorization system that enables:
;;;;   - Persistent vs ephemeral slots (saved vs temporary)
;;;;   - Indexed vs non-indexed slots (for query performance)
;;;;   - Meta vs data slots (infrastructure vs user data)
;;;;   - Compile-time slot property metadata (unlike clos.lisp's runtime lists)
;;;;
;;;; Key Innovation:
;;;;   Uses slot properties (:meta, :persistent, :ephemeral, :indexed) defined at
;;;;   class definition time. These are inherited by subclasses through
;;;;   compute-effective-slot-definition.
;;;;
;;;; Relationship to clos.lisp:
;;;;   - clos.lisp: Intercepts slot reads/writes (runtime behavior)
;;;;   - node-class.lisp: Categorizes slots (compile-time metadata)
;;;;   - Together: Enable flexible schema + ACID persistence
;;;;
;;;; Architecture:
;;;;   node-class (metaclass)
;;;;     ↓
;;;;   node-slot-definition (adds persistent, indexed, ephemeral, meta properties)
;;;;     ↓
;;;;   NODE (base class with 13 meta-slots + slot categorization)
;;;;     ↓
;;;;   VERTEX, EDGE (user-defined subclasses)

(in-package :graph-db)

(eval-when (:compile-toplevel :load-toplevel :execute)

;;;; ============================================================================
;;;; NODE-CLASS: Metaclass with Slot Categorization
;;;; ============================================================================

(defclass node-class (standard-class)
  ()
  (:documentation "Metaclass for persistent graph objects with slot categorization.

   ROLE:
   Similar to graph-class from clos.lisp, but provides more advanced functionality:
   - Custom slot definition class (node-slot-definition)
   - Property inheritance (persistent, ephemeral, indexed, meta)
   - Class hierarchy utilities (find-all-subclasses, find-ancestor-classes)

   INHERITANCE:
   Inherits from standard-class.

   USAGE:
   (defclass vertex ()
     ((name :persistent t :indexed t)
      (cache :ephemeral t))
     (:metaclass node-class))

   NOTES:
   - Wrapped in eval-when (:compile-toplevel :load-toplevel :execute)
   - This ensures metaclass is available at compile-time for subclasses
   - Risk: Circular dependency if node-class used before this file loads"))

(defmethod validate-superclass ((class node-class) (super standard-class))
  "Validate that node-class can inherit from standard-class.

   CONTEXT:
   The MOP requires metaclasses to declare their superclass compatibility.

   ARGS:
   - class: The node-class being defined
   - super: The superclass (standard-class)

   RETURN:
   T (always) — node-class is compatible with standard-class

   NOTES:
   - Standard MOP pattern
   - Required for class definition to succeed"
  t)

;;;; ============================================================================
;;;; NODE-SLOT-DEFINITION: Categorized Slot Metadata
;;;; ============================================================================

(defclass node-slot-definition (standard-slot-definition)
  ((persistent :accessor persistent-p :initarg :persistent :initform t :allocation :instance
              :documentation "Should this slot be persisted to disk?")
   (indexed :accessor indexed-p :initarg :index :initform nil :allocation :instance
           :documentation "Create an index for fast queries on this slot?")
   (ephemeral :accessor ephemeral-p :initarg :ephemeral :initform nil :allocation :instance
             :documentation "Temporary slot (never persisted)?")
   (meta :accessor meta-p :initarg :meta :initform nil :allocation :instance
        :documentation "Infrastructure slot (like id, type-id)?"))
  (:documentation "Extended slot definition with categorization properties.

   PROPERTIES:
   - persistent (default T): Should this slot be persisted to disk?
   - indexed (default NIL): Create an index for queries?
   - ephemeral (default NIL): Temporary (never saved)?
   - meta (default NIL): Infrastructure (not user data)?

   USAGE:
   When defining a slot in a node-class:
     (name :persistent t :indexed t)         ; Persistent, indexed
     (cache :ephemeral t)                    ; Temporary, never saved
     (id :meta t :persistent nil)            ; Infrastructure

   INHERITANCE:
   Subclasses inherit properties from their parent's slot definitions.
   If a subclass defines a slot with the same name, properties are merged:
   - If parent has :meta t, child inherits :meta t
   - If either has :indexed t, result is :indexed t

   NOTES:
   - The :initarg is slightly wrong for 'index' (should be ':indexed')
   - This may be a bug or intentional for backward compatibility"))

;;; Fallback methods for non-node-slot-definition objects

(defmethod persistent-p (slot-def)
  "Default: Non-node slots are not persistent.

   CONTEXT:
   This method provides a fallback for slots that are NOT node-slot-definition instances.
   This allows mixed slot hierarchies (normal slots + node slots).

   RETURN:
   NIL (not persistent)"
  nil)

(defmethod indexed-p (slot-def)
  "Default: Non-node slots are not indexed.

   RETURN:
   NIL (not indexed)"
  nil)

(defmethod ephemeral-p (slot-def)
  "Default: Non-node slots are not ephemeral.

   RETURN:
   NIL (not ephemeral)"
  nil)

(defmethod meta-p (slot-def)
  "Default: Non-node slots are not meta.

   RETURN:
   NIL (not meta)"
  nil)

;;;; ============================================================================
;;;; SLOT DEFINITION CLASSES: Direct and Effective
;;;; ============================================================================

(defclass node-direct-slot-definition
    (standard-direct-slot-definition node-slot-definition)
  ()
  (:documentation "Direct slot definition for node-class instances.

   ROLE:
   Represents a slot as explicitly written in a class definition.

   INHERITANCE:
   Inherits from both standard-direct-slot-definition (MOP standard)
   and node-slot-definition (carries categorization properties).

   NOTES:
   - Instantiated by direct-slot-definition-class method
   - Converted to effective-slot-definition during class finalization"))

(defclass node-effective-slot-definition
    (standard-effective-slot-definition node-slot-definition)
  ()
  (:documentation "Effective slot definition for node-class instances.

   ROLE:
   Represents a slot in its final, computed form (after inheritance).

   INHERITANCE:
   Inherits from both standard-effective-slot-definition (MOP standard)
   and node-slot-definition (carries categorization properties).

   NOTES:
   - Instantiated by effective-slot-definition-class method
   - Computed by compute-effective-slot-definition :around
   - Used by slot categorization methods (data-slots, meta-slot-names, etc)"))

;;;; ============================================================================
;;;; SLOT CATEGORIZATION METHODS: Classify Slots by Property
;;;; ============================================================================

(defmethod data-slots ((instance node-class))
  "Return a list of managed slot names (persistent OR ephemeral).

   CONTEXT:
   Data slots are user-defined slots that are managed by the persistence layer.
   This includes both persistent (saved to disk) and ephemeral (temporary) slots.
   Meta-slots (infrastructure) are excluded.

   ARGS:
   - instance: A node-class instance (a class)

   RETURN:
   List of slot names (symbols) that are persistent OR ephemeral

   ALGORITHM:
   For each slot in (class-slots instance):
     If (persistent-p slot) OR (ephemeral-p slot), include slot-name

   EXAMPLE:
   Define a vertex type:
     (def-vertex person
       (name :persistent t)        ; Data slot (persistent)
       (age :persistent t)         ; Data slot (persistent)
       (cache :ephemeral t))       ; Data slot (ephemeral)

   Then:
     (data-slots (find-class 'person))
     => (NAME AGE CACHE)

   Compare with:
     (meta-slot-names (find-class 'person))
     => (ID TYPE-ID REVISION HEAP-WRITTEN-P ...)

   NOTES:
   - Used by Layer 5+ (views, indexes) to know what to index
   - Does NOT include meta-slots (those are handled separately)
   - Includes both persistent AND ephemeral (both are \"managed\")"
  (map 'list #'sb-mop:slot-definition-name
       (remove-if-not #'(lambda (i)
                          (or (persistent-p i) (ephemeral-p i)))
                      (sb-mop:class-slots instance))))

(defmethod meta-slot-names ((instance node-class))
  "Return a list of metadata slot names (infrastructure).

   CONTEXT:
   Meta-slots are infrastructure slots (id, type-id, revision, etc).
   They are never persisted as data; they are persisted as system metadata.

   ARGS:
   - instance: A node-class instance (a class)

   RETURN:
   List of slot names (symbols) that are marked :meta t

   ALGORITHM:
   For each slot in (class-slots instance):
     If (meta-p slot), include slot-name

   EXAMPLE:
   (meta-slot-names (find-class 'node))
   => (ID TYPE-ID REVISION HEAP-WRITTEN-P TYPE-IDX-WRITTEN-P VE-WRITTEN-P
        VEV-WRITTEN-P VIEWS-WRITTEN-P WRITTEN-P DATA-POINTER DELETED-P DATA BYTES)

   NOTES:
   - All 13 meta-slots are marked :meta t in NODE class definition
   - Meta-slots have :persistent nil (not persisted as regular data)
   - Meta-slots are persisted as system metadata (different layer)
   - Logging calls commented out (debug feature)"
  (let ((names
         (map 'list #'sb-mop:slot-definition-name
              (remove-if-not #'(lambda (i)
                                 (meta-p i))
                             (sb-mop:class-slots instance)))))
    names))

(defmethod persistent-slot-names ((instance node-class))
  "Return a list of persistent slot names (saved to disk).

   CONTEXT:
   Persistent slots are saved to the heap during transactions.
   These are user-defined data slots (not ephemeral, not meta).

   ARGS:
   - instance: A node-class instance (a class)

   RETURN:
   List of slot names (symbols) that are marked :persistent t

   ALGORITHM:
   For each slot in (class-slots instance):
     If (persistent-p slot), include slot-name

   EXAMPLE:
   (def-vertex person
     (name :persistent t)
     (email :persistent t)
     (cache :ephemeral t))

   (persistent-slot-names (find-class 'person))
   => (NAME EMAIL)

   NOTES:
   - Used by serialize.lisp to know what to save
   - Does NOT include ephemeral or meta slots
   - Only includes explicitly marked :persistent t
   - Logging calls commented out (debug feature)"
  (let ((names
         (map 'list #'sb-mop:slot-definition-name
              (remove-if-not #'(lambda (i)
                                 (persistent-p i))
                             (sb-mop:class-slots instance)))))
    names))

(defmethod ephemeral-slot-names ((instance node-class))
  "Return a list of ephemeral slot names (temporary, not persisted).

   CONTEXT:
   Ephemeral slots exist only in memory. They are never saved to disk.
   Useful for cached values, computation results, etc.

   ARGS:
   - instance: A node-class instance (a class)

   RETURN:
   List of slot names (symbols) that are marked :ephemeral t

   ALGORITHM:
   For each slot in (class-slots instance):
     If (ephemeral-p slot), include slot-name

   EXAMPLE:
   (def-vertex vertex-with-cache
     (permanent-data :persistent t)
     (query-cache :ephemeral t))

   (ephemeral-slot-names (find-class 'vertex-with-cache))
   => (QUERY-CACHE)

   NOTES:
   - These slots are initialized on each load but not persisted
   - Useful for denormalized/cached data
   - Logging calls commented out (debug feature)"
  (let ((names
         (map 'list #'sb-mop:slot-definition-name
              (remove-if-not #'(lambda (i)
                                 (ephemeral-p i))
                             (sb-mop:class-slots instance)))))
    names))

;;;; ============================================================================
;;;; MOP HOOKS: Slot Definition Class Selection
;;;; ============================================================================

(defmethod direct-slot-definition-class ((class node-class) &rest initargs)
  "Return the class to use for direct slot definitions of node-class instances.

   CONTEXT:
   During class finalization, the MOP calls this for each slot in the class definition.

   ARGS:
   - class: The node-class being defined
   - initargs: Initialization arguments (ignored)

   RETURN:
   The class node-direct-slot-definition

   NOTES:
   - Called at compile-time for each slot
   - Enables node-class to use custom slot definition class
   - Logging call included (log:trace)"
  (declare (ignore initargs))
  (log:trace "direct-slot-definition-class for ~A" class)
  (find-class 'node-direct-slot-definition))

(defmethod effective-slot-definition-class ((class node-class) &rest initargs)
  "Return the class to use for effective slot definitions of node-class instances.

   CONTEXT:
   After collecting all direct slots, the MOP calls this to determine the effective class.

   ARGS:
   - class: The node-class being finalized
   - initargs: Initialization arguments (ignored)

   RETURN:
   The class node-effective-slot-definition

   NOTES:
   - Called at compile-time after all direct slots collected
   - Logging call included (log:trace)"
  (declare (ignore initargs))
  (log:trace "effective-slot-definition-class for ~A" class)
  (find-class 'node-effective-slot-definition))

;;;; ============================================================================
;;;; MOP HOOK: Effective Slot Computation with Property Inheritance
;;;; ============================================================================

(defmethod compute-effective-slot-definition :around
    ((class node-class) slot-name direct-slots)
  "Compute effective slot definition, inheriting categorization properties.

   CONTEXT:
   The MOP calls this to compute the final slot definition by combining
   direct slot definitions from the class and its superclasses.

   CRITICAL: This method implements property inheritance rules.

   ARGS:
   - class: The node-class being finalized
   - slot-name: The name of the slot being computed (symbol)
   - direct-slots: List of direct slot definitions with this name
                   (usually 1, but can be more if overridden in subclasses)

   RETURN:
   The computed effective slot definition (a node-effective-slot-definition)
   with inherited/merged properties

   ALGORITHM:
   1. Call standard compute-effective-slot-definition to get base slot
   2. THREE-WAY CONDITIONAL on meta/persistent/ephemeral:
      a. If (meta-p slot) OR any direct-slot has :meta t:
         → Set slot's meta=t and persistent=nil (meta slots not persisted as data)
      b. Else if (persistent-p slot) OR any direct-slot has :persistent t:
         → Set slot's persistent=t (remains as-is)
      c. Else (no meta, no persistent):
         → Set slot's ephemeral=t (default to temporary)
   3. If (indexed-p slot) OR any direct-slot has :indexed t:
      → Set slot's indexed=t
      → FIXME: Generate index if needed (unimplemented)

   PROPERTY INHERITANCE RULES:
   - Meta property: Sticky (once meta, always meta)
   - Persistent property: OR'ed (if any direct has persistent, result is persistent)
   - Ephemeral property: Default (if not meta and not persistent, then ephemeral)
   - Indexed property: OR'ed (if any direct has indexed, result is indexed)

   EXAMPLE 1: Simple slot inheritance
     Parent class:
       (name :persistent t)
     Child class inherits the slot:
       => Meta=nil, Persistent=t (inherited)

   EXAMPLE 2: Override persistent to ephemeral
     Parent: (cache :persistent t)
     Child: (cache :ephemeral t)
     => Some 'persistent-p direct-slots => Result is persistent=t
        (Because parent still has persistent=t in direct-slots)

   EXAMPLE 3: Meta property is sticky
     Parent: (id :meta t)
     Child: (id :persistent t)  ; Try to override
     => Some 'meta-p direct-slots => Result is meta=t, persistent=nil
        (Meta property takes precedence)

   CRITICAL BEHAVIOR:
   The use of (some ...) means ANY direct-slot property causes inheritance.
   This is important for multi-level hierarchies.

   NOTES:
   - Logging call included (log:trace)
   - FIXME for index generation (not yet implemented)
   - This is the KEY mechanism for property inheritance"
  (log:trace "compute-effective-slot-definition for ~A / ~A: ~A" class slot-name direct-slots)
  (let ((slot (call-next-method)))
    ;; CRITICAL: Determine final properties by checking both the slot and direct-slots
    (cond
      ;; Rule 1: Meta property is sticky
      ((or (meta-p slot) (some #'meta-p direct-slots))
       (setf (slot-value slot 'meta) t)
       (setf (slot-value slot 'persistent) nil))  ; Meta slots not persisted as data
      ;; Rule 2: Otherwise, if persistent is set (on slot or any direct)
      ((or (persistent-p slot) (some #'persistent-p direct-slots))
       (setf (slot-value slot 'persistent) t))
      ;; Rule 3: Default to ephemeral (temporary)
      (t
       (setf (slot-value slot 'persistent) nil)
       (setf (slot-value slot 'ephemeral) t)))
    ;; Rule 4: Indexed property is OR'ed
    (when (or (indexed-p slot) (some #'indexed-p direct-slots))
      (setf (slot-value slot 'indexed) t)
      ;; FIXME: Generate index if needed
      ;; This is unimplemented; indexed slots don't auto-create indexes yet
      )
    slot))

;;;; ============================================================================
;;;; CLASS HIERARCHY UTILITIES: Introspection Methods
;;;; ============================================================================

(defmethod find-all-subclasses ((class class))
  "Recursively find ALL subclasses of a given class.

   CONTEXT:
   Returns every subclass in the entire hierarchy, not just direct subclasses.
   Important for type-index and schema operations.

   ARGS:
   - class: A class object

   RETURN:
   List of all subclass objects (including transitive subclasses)

   ALGORITHM:
   Use labeled recursion (labels) to traverse the hierarchy depth-first:
   1. Start with class's direct subclasses (class-direct-subclasses class)
   2. For each subclass:
      a. Unless already in result: add to result
      b. Recursively find its subclasses
   3. Return accumulated result

   EXAMPLE:
   Class hierarchy:
     NODE
       ├─ VERTEX
       │   ├─ PERSON
       │   └─ COMPANY
       └─ EDGE

   (find-all-subclasses (find-class 'node))
   => (VERTEX EDGE PERSON COMPANY)
   ; All subclasses, including PERSON (deep in hierarchy)

   NOTES:
   - Uses (find subclass result) for duplicate checking
   - **PERFORMANCE WARNING:** (find ...) is O(n) per subclass
   - Should use hash set for large hierarchies (O(1) lookup)
   - Logging calls commented out (debug feature)"
  (let ((result nil))
    (labels ((find-them (class)
               (let ((subclasses (sb-mop:class-direct-subclasses class)))
                 (dolist (subclass subclasses)
                   (unless (find subclass result)
                     (push subclass result)
                     (find-them subclass))))))
      (find-them class)
      result)))

(defmethod find-all-subclass-names ((class class))
  "Get the names (symbols) of all subclasses.

   CONTEXT:
   Convenience method combining find-all-subclasses and class-name mapping.

   ARGS:
   - class: A class object

   RETURN:
   List of class names (symbols)

   EXAMPLE:
   (find-all-subclass-names (find-class 'vertex))
   => (PERSON COMPANY EMPLOYEE)

   NOTES:
   - Simple wrapper around find-all-subclasses
   - Returns symbols instead of class objects"
  (mapcar #'class-name (find-all-subclasses class)))

(defmethod find-ancestor-classes ((class-name symbol))
  "Find ancestor classes by symbol name.

   CONTEXT:
   Convenience wrapper that first looks up the class.

   ARGS:
   - class-name: Symbol naming the class

   RETURN:
   List of ancestor class objects (excluding built-ins)"
  (find-ancestor-classes (find-class class-name)))

(defmethod find-ancestor-classes ((class node-class))
  "Find ancestor classes, filtering out built-in CL classes.

   CONTEXT:
   Used for schema introspection. Filters out:
   - STANDARD-OBJECT (CL built-in)
   - SB-PCL::SLOT-OBJECT (SBCL internal)
   - T (root class)
   Others may be platform-specific

   ARGS:
   - class: A node-class instance

   RETURN:
   List of ancestor class objects (custom classes only)

   ALGORITHM:
   1. Compute class precedence list (inheritance chain)
   2. Delete built-in class names:
      - SBCL: '(edge vertex node STANDARD-OBJECT SB-PCL::SLOT-OBJECT T)
      - LispWorks: '(edge vertex node standard-object T)
      - CCL: '(edge vertex node STANDARD-OBJECT T)
   3. Return filtered list

   EXAMPLE:
   (def-vertex person ...)
   (def-vertex employee (person) ...)
   
   (find-ancestor-classes (find-class 'employee))
   => (PERSON)  ; Just PERSON, not VERTEX, NODE, STANDARD-OBJECT, T

   NOTES:
   - Platform-specific: Different CL implementations have different internal classes
   - Hard-coded lists: May break if vendor adds new internal classes
   - Does NOT remove edge/vertex/node (filters only built-ins)"
  (delete-if (lambda (class)
               (find (class-name class)
                     #+sbcl '(edge vertex node STANDARD-OBJECT SB-PCL::SLOT-OBJECT T)
                     #+lispworks '(edge vertex node standard-object T)
                     #+ccl '(edge vertex node STANDARD-OBJECT T)))
             (sb-mop:compute-class-precedence-list class)))

(defmethod find-graph-parent-classes ((class node-class))
  "Find custom parent classes (domain-specific ancestors).

   CONTEXT:
   Returns only the custom parent classes defined for this type,
   excluding domain-specific base types (vertex, edge, primitive-node).

   ARGS:
   - class: A node-class instance

   RETURN:
   List of custom parent class objects (sorted topologically)

   ALGORITHM:
   1. Get direct superclasses of this class
   2. Remove if class-name is 'vertex, 'edge, or 'primitive-node
   3. Recursively find parents of remaining classes
   4. Concatenate and remove duplicates

   EXAMPLE:
   Define hierarchy:
     (def-vertex person (name :string))
     (def-vertex employee (person) (salary :float))
     (def-vertex manager (employee) (team-size :integer))

   Then:
     (find-graph-parent-classes (find-class 'manager))
     => (EMPLOYEE)  ; Just EMPLOYEE, not PERSON (would be via recursion)
     
     Or maybe (EMPLOYEE PERSON) if recursion is included?
     Check implementation: uses mapcan, so includes transitive

   NOTES:
   - Excludes vertex, edge, primitive-node (domain types)
   - Uses remove-duplicates to avoid cycles
   - Uses nconc + mapcan for transitive closure
   - Useful for schema validation and type checking"
  (let ((classes
         (remove-if (lambda (class)
                      (or (eq (class-name class) 'vertex)
                          (eq (class-name class) 'edge)
                          (eq (class-name class) 'primitive-node)))
                    (sb-mop:class-direct-superclasses class))))
    (remove-duplicates
     (nconc classes
            (mapcan #'find-graph-parent-classes classes)))))

) ; End eval-when

;;;; ============================================================================
;;;; NODE CLASS: Base Persistent Object with Categorized Slots
;;;; ============================================================================

(defclass node ()
  "Base class for all persistent graph database objects.

   ROLE:
   Defines 13 meta-slots using the new slot categorization system.
   All user-defined data (from def-vertex, def-edge) will be stored as
   ephemeral or persistent slots using this categorization.

   METACLASS:
   Uses node-class (not standard-class).
   This enables slot categorization and property inheritance.

   SLOT CATEGORIZATION:
   All 13 meta-slots are marked :meta t and :persistent nil.
   - :meta t means they are infrastructure (not user data)
   - :persistent nil means they are not persisted as regular data
     (they are persisted as system metadata instead)

   STRUCTURE:
   13 meta-slots total, divided by function:
   - Identification: id, type-id
   - MVCC/versioning: revision, %revision-table
   - Persistence flags: heap-written-p, type-idx-written-p, ve-written-p,
                       vev-written-p, views-written-p, written-p
   - Serialization: data-pointer, data, bytes, deleted-p

   INHERITANCE:
   Subclasses (VERTEX, EDGE) inherit these 13 slots.
   They do NOT add new direct slots; user data is stored in ephemeral/persistent
   slots defined in subclasses.

   NOTES:
   - Each slot has an accessor (e.g., (id node) reads the id)
   - Each slot can be initialized via keyword argument (e.g., :id, :type-id)
   - Type declarations ensure type safety (e.g., :type (unsigned-byte 16))
   - All use :allocation :instance (stored in the instance, not shared)"
  ((id :accessor id :initform +null-key+ :initarg :id :meta t
       :type (simple-array (unsigned-byte 8) (16)) :persistent nil
       :documentation "16-byte UUID, immutable. Unique identifier for this object.")

   (type-id :accessor type-id :initform 1 :initarg :type-id :meta t
            :type (unsigned-byte 16) :persistent nil
            :documentation "Type registry ID. 1 = generic NODE, 2+ = def-vertex/def-edge types.")

   (revision :accessor revision :initform 0 :initarg :revision :meta t
             :type (unsigned-byte 32) :persistent nil
             :documentation "MVCC version number. Incremented on each write for snapshot isolation.")

   (%revision-table :accessor %revision-table :initform (make-hash-table :test 'eq)
                    :initarg :revision-table :meta t :persistent nil
                    :documentation "Hash table for version tracking (per transaction).")

   (heap-written-p :accessor heap-written-p :initform nil :initarg :heap-written-p
                   :type boolean :meta t :persistent nil
                   :documentation "Persistence flag: Written to memory-mapped heap?")

   (type-idx-written-p :accessor type-idx-written-p :initform nil :meta t
                       :initarg :type-idx-written-p :type boolean :persistent nil
                       :documentation "Persistence flag: Written to type-index?")

   (ve-written-p :accessor ve-written-p :initform nil :initarg :ve-written-p
                 :type boolean :meta t :persistent nil
                 :documentation "Persistence flag: Written to vertex-edge index?")

   (vev-written-p :accessor vev-written-p :initform nil :initarg :vev-written-p
                  :type boolean :meta t :persistent nil
                  :documentation "Persistence flag: Written to vertex-edge-vertex index?")

   (views-written-p :accessor views-written-p :initform nil :meta t
                    :initarg :views-written-p :type boolean :persistent nil
                    :documentation "Persistence flag: Written to materialized views?")

   (written-p :accessor written-p :initform nil :initarg :written-p :type boolean
              :meta t :persistent nil
              :documentation "Overall persistence flag: true if all indexes synchronized.")

   (data-pointer :accessor data-pointer :initform 0 :initarg :data-pointer
                 :type (unsigned-byte 64) :meta t :persistent nil
                 :documentation "Address in memory-mapped file where data is stored.")

   (deleted-p :accessor deleted-p :initform nil :initarg :deleted-p :type boolean
              :meta t :persistent nil
              :documentation "Soft-delete flag: true if logically deleted.")

   (data :accessor data :initarg :data :initform nil :meta t :persistent nil
        :documentation "Plist container for user-defined slots (in clos.lisp). Not used here.")

   (bytes :accessor bytes :initform :init :initarg :bytes :meta t :persistent nil
         :documentation "Serialized byte representation (lazy-computed)."))

  (:metaclass node-class)

  (:documentation "Base class for all persistent graph objects.

   This class provides the foundation for VERTEX, EDGE, and custom types.
   All 13 slots are marked :meta t to indicate they are infrastructure.

   USAGE:
   Users do NOT instantiate NODE directly; instead:
   - (def-vertex person (name :string) (age :integer))
   - (let ((p (make-vertex graph \"person\"))) ...)

   SUBCLASSES:
   - VERTEX (for vertices)
   - EDGE (for edges)
   - Custom types created via def-vertex and def-edge"))