;;;; src/globals.lisp
;;;; 
;;;; Global Constants and State Variables
;;;;
;;;; Purpose:
;;;;   Define all global constants and mutable state used throughout VivaceGraph.
;;;;   This file is FOUNDATIONAL — imported by every layer.
;;;;
;;;;   Contains:
;;;;   - Configuration parameters (version, file names, sizes)
;;;;   - Sentinel values (min/max keys, null values)
;;;;   - Type codes (serialization format identifiers)
;;;;   - Index structure parameters (VE-index, VEV-index)
;;;;   - Prolog engine state (trail, functors, trace)
;;;;   - Platform-specific hash tables (thread-safe variants)
;;;;
;;;; Critical Design:
;;;;   - Constants use +CONSTANT+ naming (compile-time, immutable)
;;;;   - Variables use *VARIABLE* naming (runtime, mutable)
;;;;   - All sizes are in BYTES (16, 18, 34, etc. refer to byte counts)
;;;;   - All UUIDs are RFC 4122 16-byte format
;;;;   - Magic bytes distinguish serialization types
;;;;
;;;; Key Principle:
;;;;   This file defines the "contract" between layers.
;;;;   Changing a constant here breaks persistence (old data won't deserialize).
;;;;   Changing a variable here affects runtime behavior (temporary).

(in-package :graph-db)

;;;; ============================================================================
;;;; CACHE CONTROL
;;;; ============================================================================

(defvar *cache-enabled* t
  "Global flag controlling in-memory object caching.

   TYPE: Boolean (T or NIL)

   DEFAULT: T (caching enabled)

   PURPOSE:
   Controls whether recently accessed vertices and edges are cached in memory.
   When T, improves performance but uses more RAM.
   When NIL, disables cache (useful for memory-constrained systems).

   USAGE:
   (let ((*cache-enabled* nil))
     (lookup-vertex graph id))  ; This lookup won't cache result

   NOTES:
   - Dynamic variable, can be toggled at runtime
   - Affects ALL graphs globally
   - Cache is transparent to user code
   - Settings affect only new loads, not already-cached objects
   - Typically T in production (small overhead for big performance gain)")

;;;; ============================================================================
;;;; DATABASE VERSION AND PERSISTENCE
;;;; ============================================================================

(alexandria:define-constant +db-version+ 1
  "Database schema version number.

   TYPE: Integer

   CURRENT VALUE: 1

   PURPOSE:
   Identifies the database schema format for compatibility checking.
   Incremented when schema changes are incompatible with previous versions.

   USAGE:
   On open-graph, verify on-disk +db-version+ matches this constant.
   If versions differ, prompt user for migration or reject open.

   COMPATIBILITY:
   - Same version: Data is readable
   - Different version: Data may not be readable (or needs migration)

   FUTURE:
   If schema changes (e.g., new index format), increment to 2, 3, etc.
   Keep old code to read version 1 files during migration.

   NOTES:
   - Immutable (define-constant, not defvar)
   - Persisted in meta.dat when graph is created
   - Used as security/compatibility check")

(defvar *graph* nil
  "Dynamic variable for current active graph.

   TYPE: GRAPH instance (or NIL if none active)

   DEFAULT: NIL

   PURPOSE:
   Provides implicit context for transaction and query functions.
   Eliminates need to pass graph as argument to every function.

   USAGE:
   (with-transaction graph
     (lookup-vertex 42))  ; Uses *graph* binding, no explicit arg
   
   Under the hood: with-transaction sets (let ((*graph* graph)) ...)

   NOTES:
   - Dynamic binding (changes with function scope)
   - Only ONE graph can be active at a time (serial access)
   - NIL outside (with-transaction ...) or (open-graph ...)
   - Users should NOT set this directly (use with-transaction instead)")

(alexandria:define-constant +main-table-file+ "main.dat" :test 'equal
  "Filename for main vertex/edge table.

   TYPE: String

   VALUE: \"main.dat\"

   PURPOSE:
   Stores primary index of all vertices and edges.
   Persisted in graph's location directory.

   LOCATION: {location}/main.dat

   FORMAT:
   Main index mapping type-id to instances.

   NOTES:
   - Fixed name (not configurable)
   - One file per graph
   - Immutable after graph creation")

(alexandria:define-constant +meta-file+ "meta.dat" :test 'equal
  "Filename for metadata and schema.

   TYPE: String

   VALUE: \"meta.dat\"

   PURPOSE:
   Stores type registry (def-vertex, def-edge definitions).
   Also stores database version and configuration.

   LOCATION: {location}/meta.dat

   CONTENTS:
   - +db-version+
   - Type definitions (schemas)
   - Index information
   - Replication state

   NOTES:
   - Updated whenever schema changes (def-vertex, def-edge)
   - Must be loaded before any data operations
   - Immutable filename (not configurable)")

(alexandria:define-constant +data-file+ "data.dat" :test 'equal
  "Filename for serialized node data.

   TYPE: String

   VALUE: \"data.dat\"

   PURPOSE:
   Memory-mapped heap storing serialized vertices and edges.
   Allocates as variable number of 100 MB segments.

   LOCATION: {location}/data.dat (or data.dat.0, data.dat.1, etc.)

   STRUCTURE:
   Each node serialized as: [type-code][serialized-fields]
   Segments allocated on-demand (first 100 MB, then 200 MB total, etc.)

   NOTES:
   - Actual heap file (largest file in graph)
   - Allocated via pmem (persistent memory library)
   - Memory-mapped for efficient access
   - Immutable filename")

;;;; ============================================================================
;;;; SCHEMA METADATA
;;;; ============================================================================

(defvar *schema-node-metadata* (make-hash-table :test 'equal)
  "Hash table storing type definitions for all node types.

   TYPE: Hash table (key: string name, value: metadata)

   PURPOSE:
   Registry of all custom node types created via def-vertex and def-edge.
   Enables runtime type introspection and validation.

   STRUCTURE:
   Keys: Type names (strings, e.g., \"person\", \"knows-edge\")
   Values: Type metadata (class, persistent slots, indexed slots, etc.)

   USAGE:
   (gethash \"person\" *schema-node-metadata*) => type metadata

   POPULATION:
   Populated by (def-vertex ...) and (def-edge ...) at compile time.
   Also restored from +meta-file+ when graph is opened.

   NOTES:
   - Mutable (changes as new types defined)
   - Per-graph instance (each graph has own set of types)
   - Thread-safe hash table (test 'equal for string comparison)")

(alexandria:define-constant +max-node-types+ 65536
  "Maximum number of distinct node types in a graph.

   TYPE: Integer

   VALUE: 65536 (2^16)

   PURPOSE:
   Upper limit on type-id field in NODE class.
   type-id is stored as uint16 (16-bit unsigned integer).

   DERIVATION:
   65536 = 2^16 (range of uint16)

   ENFORCEMENT:
   If user tries to define (def-vertex ...) when 65536 types exist,
   should reject with error message.

   NOTES:
   - Soft limit (enforced at def-vertex time, not compile time)
   - Generous (65K types is plenty for real systems)
   - Could be increased if type-id enlarged to uint32 (4 billion types)")

;;;; ============================================================================
;;;; STORAGE FORMAT: VERSION, MAGIC BYTES, SIZES
;;;; ============================================================================

(alexandria:define-constant +storage-version+ #x01
  "Storage format version identifier.

   TYPE: Hexadecimal byte (#x01)

   VALUE: 1 (0x01)

   PURPOSE:
   Version number for binary storage format.
   If storage format changes, increment this value.

   USAGE:
   Written as first byte of each persistent structure.
   Reader checks version to know how to deserialize.

   NOTES:
   - Different from +db-version+ (schema level)
   - +storage-version+ is format level
   - Immutable (changes break all existing data)")

(alexandria:define-constant +fixed-integer-64+ #x01
  "Type code for fixed 64-bit integers.

   TYPE: Hexadecimal byte (#x01)

   VALUE: 1 (0x01)

   PURPOSE:
   In data structures that store multiple value types,
   this code indicates the following bytes are a 64-bit signed integer.

   USAGE:
   In Layer 4 (serialize.lisp), when deserializing:
   if read-byte = +fixed-integer-64+, read next 8 bytes as int64

   NOTES:
   - Different from type codes in +positive-integer+, +negative-integer+
   - This is for fixed-width representation
   - Rarely used (most use +positive-integer+ or +negative-integer+)")

(alexandria:define-constant +data-magic-byte+ #x17
  "Magic byte identifying generic data object.

   TYPE: Hexadecimal byte (#x17)

   VALUE: 23 (0x17)

   PURPOSE:
   First byte of serialized generic data objects in heap.
   Allows deserializer to identify structure type.

   FORMAT:
   [#x17][serialized-slots...]

   USAGE:
   Layer 4 (serialize.lisp) checks magic byte to determine type.

   NOTES:
   - Hex value 0x17 chosen arbitrarily (no collision with others)
   - Part of magic byte space (0x17-0x20 and others)
   - Immutable (stored in all data, can't change)")

(alexandria:define-constant +lhash-magic-byte+ #x18
  "Magic byte identifying linear hash table structure.

   TYPE: Hexadecimal byte (#x18)

   VALUE: 24 (0x18)

   PURPOSE:
   Marks serialized linear hash (lhash) table in heap.
   Linear hash is used for ve-index, type-index, etc.

   NOTES:
   - Different from +data-magic-byte+ (0x17)
   - Distinguishes hash table from generic data object")

(alexandria:define-constant +overflow-magic-byte+ #x19
  "Magic byte identifying hash table overflow block.

   TYPE: Hexadecimal byte (#x19)

   VALUE: 25 (0x19)

   PURPOSE:
   When hash bucket overflows, allocates overflow block.
   This magic byte marks overflow region.

   NOTES:
   - Used in linear hash collision handling
   - Part of lhash (linear hash) implementation")

(alexandria:define-constant +config-magic-byte+ #x20
  "Magic byte identifying configuration block.

   TYPE: Hexadecimal byte (#x20)

   VALUE: 32 (0x20)

   PURPOSE:
   Marks configuration data in meta.dat file.

   NOTES:
   - Distinguishes config from schema or index data
   - 0x20 is clean round number (32 decimal)")

(alexandria:define-constant +null-key+
  (make-array '(16) :element-type '(unsigned-byte 8) :initial-element 0)
  :test 'equalp
  "Sentinel key value representing \"no key\" or \"uninitialized\".

   TYPE: 16-byte array of zeros [0, 0, 0, ..., 0]

   PURPOSE:
   Lower bound for key ranges.
   Indicates uninitialized slot (e.g., new NODE before ID assignment).

   USAGE:
   In skip lists, range queries, etc.
   Compare using EQUALP (byte-array element-wise equality).

   PROPERTIES:
   - Smallest possible 16-byte key (all zeros < any real UUID)
   - Used as +gmin+ boundary in skip lists
   - Comparable to RFC 4122 UUIDs

   NOTES:
   - Immutable (define-constant with :test 'equalp)
   - :test 'equalp means two identical arrays = this constant
   - Size: 16 bytes (matches UUID size)")

(alexandria:define-constant +max-key+
  (make-array '(16) :element-type '(unsigned-byte 8) :initial-element 255)
  :test 'equalp
  "Sentinel key value representing \"infinity\" or \"max key\".

   TYPE: 16-byte array of 0xFF [255, 255, ..., 255]

   PURPOSE:
   Upper bound for key ranges.
   Indicates maximum possible key in comparisons.

   USAGE:
   In skip lists, range queries, etc.
   Compare using EQUALP (byte-array element-wise equality).

   PROPERTIES:
   - Largest possible 16-byte key (all 0xFF > any real UUID)
   - Used as +gmax+ boundary in skip lists
   - Comparable to RFC 4122 UUIDs

   NOTES:
   - Immutable (define-constant with :test 'equalp)
   - Complementary to +null-key+
   - All real UUID keys fall between +null-key+ and +max-key+")

(alexandria:define-constant +key-bytes+ 16
  "Size of all node ID keys in bytes.

   TYPE: Integer

   VALUE: 16

   PURPOSE:
   UUID keys are 16 bytes (RFC 4122 format).
   This constant documents the size for consistency.

   DERIVATION:
   RFC 4122 UUID = 16 bytes (128 bits)

   USAGE:
   Buffer allocation, range calculations, etc.
   Arrays sized: (make-array +key-bytes+ ...)

   NOTES:
   - Immutable (changing breaks all data)
   - Used throughout Layer 2-4 for sizing
   - Fundamental to VivaceGraph design")

(alexandria:define-constant +value-bytes+ 8
  "Size of data value pointers in bytes.

   TYPE: Integer

   VALUE: 8

   PURPOSE:
   Values in indexes point to 64-bit memory addresses in heap.
   This constant documents the pointer size.

   DERIVATION:
   64-bit unsigned integers = 8 bytes (uint64)

   USAGE:
   Index entry size calculation: +key-bytes+ + +value-bytes+ = 24 bytes

   NOTES:
   - Immutable (changing breaks index format)
   - Standard for 64-bit systems")

(alexandria:define-constant +bucket-size+ 24
  "Size of hash bucket in bytes.

   TYPE: Integer

   VALUE: 24 (= +key-bytes+ + +value-bytes+)

   PURPOSE:
   Hash table bucket = [16-byte key][8-byte value].
   Total: 24 bytes per bucket.

   DERIVATION:
   16 bytes (UUID key) + 8 bytes (pointer value) = 24 bytes

   USAGE:
   In linear hash implementation (Layer 2).
   Bucket allocation: (allocate-bucket +bucket-size+)

   NOTES:
   - Immutable
   - Fundamental to hash table layout
   - Fixed-size buckets enable efficient mmap access")

(alexandria:define-constant +data-extent-size+ (* 1024 1024 100)
  "Size of each memory-mapped data extent in bytes.

   TYPE: Integer

   VALUE: 104,857,600 bytes (100 MB)

   DERIVATION:
   (* 1024 1024 100) = 1024 * 1024 * 100 = 104,857,600

   PURPOSE:
   Heap is divided into 100 MB segments (extents).
   When a segment fills, allocate next segment.

   RATIONALE:
   - 100 MB balances allocation frequency vs. fragmentation
   - Small enough (not 1 GB) to avoid over-allocation
   - Large enough (not 1 MB) to avoid frequent allocation overhead
   - 100 = round number, easy to reason about

   ALLOCATION STRATEGY:
   - New graph: allocate first 100 MB segment
   - When full: allocate second 100 MB segment
   - Total heap = N * 100 MB (N depends on data size)

   USAGE:
   In Layer 4 (serialize.lisp) for heap management.

   CONFIGURATION:
   Could be made configurable in future (e.g., 10 MB for embedded, 500 MB for servers).
   Currently hardcoded for simplicity.

   NOTES:
   - Immutable (changing breaks heap layout)
   - Applies to all graphs uniformly
   - Arbitrary choice (could be 50 MB or 200 MB)"
)
;;;; ============================================================================
;;;; KEY NAMESPACES FOR UUID GENERATION
;;;; ============================================================================

(defvar *vertex-namespace*
  (uuid:uuid-to-byte-array
   (uuid:make-uuid-from-string "2140DCE1-3208-4354-8696-5DF3076D1CEB"))
  "UUID v3/v5 namespace for generating vertex keys.

   TYPE: 16-byte array (UUID)

   VALUE: 2140DCE1-3208-4354-8696-5DF3076D1CEB (fixed UUID)

   PURPOSE:
   When creating deterministic UUIDs for vertices named by string,
   use this namespace as base.

   EXAMPLE:
   (uuid:make-uuid-v5 *vertex-namespace* \"person:123\")
   => UUID of vertex named \"person:123\"

   IMMUTABILITY:
   This UUID MUST NOT CHANGE (it's part of data format).
   If changed, all existing vertex UUIDs become invalid/unrecognizable.

   RELATIONSHIP TO EDGE-NAMESPACE:
   Distinct namespaces prevent collisions:
   - Vertex \"X\" != Edge \"X\" (different UUIDs)
   - Enables safe mixing of vertices and edges

   NOTES:
   - Mutable variable (defvar, not constant)
   - But MUST be treated as immutable (never modify at runtime)
   - Set once at load time, never changed
   - UUID value chosen arbitrarily (any valid UUID works)"
)
(defvar *edge-namespace*
  (uuid:uuid-to-byte-array
   (uuid:make-uuid-from-string "0392C7B5-A38B-466F-92E5-5A7493C2775A"))
  "UUID v3/v5 namespace for generating edge keys.

   TYPE: 16-byte array (UUID)

   VALUE: 0392C7B5-A38B-466F-92E5-5A7493C2775A (fixed UUID)

   PURPOSE:
   When creating deterministic UUIDs for edges named by string,
   use this namespace as base.

   EXAMPLE:
   (uuid:make-uuid-v5 *edge-namespace* \"knows\")
   => UUID of edge type \"knows\"

   IMMUTABILITY:
   Must not change (like *vertex-namespace*).
   Changing breaks UUID compatibility with existing data.

   COLLISION PREVENTION:
   *edge-namespace* != *vertex-namespace*
   Ensures \"person\" vertex != \"person\" edge (different UUIDs).

   NOTES:
   - Mutable variable but must NOT be modified at runtime
   - Set once, never changed
   - Different from *vertex-namespace* (prevents collisions)"
)
;;;; ============================================================================
;;;; SKIP LIST SENTINELS
;;;; ============================================================================

(alexandria:define-constant +min-sentinel+ :gmin
  "Sentinel value representing negative infinity in skip lists.

   TYPE: Symbol (:gmin)

   PURPOSE:
   Lower bound in skip list comparisons.
   All real keys are > :gmin.

   USAGE:
   Skip list algorithms traverse from :gmin to :gmax.
   Simplifies range queries (no special case for NIL boundaries).

   COMPARISONS:
   (less-than :gmin any-real-key) => T
   (less-than any-real-key :gmin) => NIL

   NOTES:
   - Immutable (define-constant)
   - Part of skip list design
   - Distinct from +null-key+ (which is 16-byte array, a real UUID)"
)
(alexandria:define-constant +max-sentinel+ :gmax
  "Sentinel value representing positive infinity in skip lists.

   TYPE: Symbol (:gmax)

   PURPOSE:
   Upper bound in skip list comparisons.
   All real keys are < :gmax.

   USAGE:
   Skip list algorithms traverse from :gmin to :gmax.
   Simplifies range queries (no special case for NIL boundaries).

   COMPARISONS:
   (less-than any-real-key :gmax) => T
   (less-than :gmax any-real-key) => NIL

   NOTES:
   - Immutable (define-constant)
   - Complementary to +min-sentinel+
   - Enables clean skip list iteration"
)
(alexandria:define-constant +reduce-master-key+ :gagg
  "Sentinel key for view aggregation results.

   TYPE: Symbol (:gagg)

   PURPOSE:
   When reducing view results (e.g., SUM, COUNT, AVG),
   the aggregate result is stored under this key.

   EXAMPLE:
   (def-view user-count
     (yield (count users))
     => results indexed by :gagg (aggregate key))

   USAGE:
   User retrieves result via (lookup-view view :gagg)

   NOTES:
   - Immutable (define-constant)
   - Used in Layer 5 (views.lisp)
   - :gagg chosen for clarity (\"aggregate\")"
)
;;;; ============================================================================
;;;; INDEX STRUCTURE SIZES
;;;; ============================================================================

(alexandria:define-constant +index-list-bytes+ 17
  "Size of index list entry in bytes.

   TYPE: Integer

   VALUE: 17

   COMPOSITION:
   16 bytes (node ID) + 1 byte (type flag)

   PURPOSE:
   Index lists store references to indexed nodes.
   Each entry: [16-byte ID][1-byte type-indicator]

   NOTES:
   - Immutable
   - Used in type-index (e.g., all vertices of type \"person\")")

;;;; ============================================================================
;;;; VE-INDEX SIZES: VERTEX-EDGE INDEX
;;;; ============================================================================

(alexandria:define-constant +ve-key-bytes+ 18
  "Size of VE-index key in bytes.

   TYPE: Integer

   VALUE: 18

   COMPOSITION:
   16 bytes (vertex ID) + 2 bytes (edge type-id)

   PURPOSE:
   VE-index maps (vertex, edge-type) => list of edges.
   Each key: [16-byte source vertex ID][2-byte edge type]

   USAGE:
   Query: \"All outgoing edges of type FRIEND from vertex V\"
   Key: V + FRIEND => returns edge IDs

   NOTES:
   - Immutable (changing breaks index format)
   - Edge type-id is uint16 (0-65535)
   - Total: 16 + 2 = 18 bytes"
)
(alexandria:define-constant +null-ve-key+
  (make-array +ve-key-bytes+ :initial-element 0 :element-type '(unsigned-byte 8))
  :test 'equalp
  "Sentinel VE-index key (all zeros).

   TYPE: 18-byte array of zeros

   PURPOSE:
   Lower bound for VE-index range queries.
   Represents (null-vertex, null-edge-type).

   NOTES:
   - Immutable
   - Analogous to +null-key+ but for VE-index
   - Used in range traversal"
)
(alexandria:define-constant +max-ve-key+
  (make-array +ve-key-bytes+ :initial-element 255 :element-type '(unsigned-byte 8))
  :test 'equalp
  "Sentinel VE-index key (all 0xFF).

   TYPE: 18-byte array of 0xFF

   PURPOSE:
   Upper bound for VE-index range queries.
   Represents (max-vertex, max-edge-type).

   NOTES:
   - Immutable
   - Complementary to +null-ve-key+
   - Used in range traversal"
)
;;;; ============================================================================
;;;; VEV-INDEX SIZES: VERTEX-EDGE-VERTEX INDEX
;;;; ============================================================================

(alexandria:define-constant +vev-key-bytes+ 34
  "Size of VEV-index key in bytes.

   TYPE: Integer

   VALUE: 34

   COMPOSITION:
   16 bytes (source vertex ID)
   + 16 bytes (target vertex ID)
   + 2 bytes (edge type-id)

   PURPOSE:
   VEV-index maps (source-vertex, target-vertex, edge-type) => edge ID.
   Each key: [16-byte source][16-byte target][2-byte type]

   USAGE:
   Query: \"Direct edge from V1 to V2 of type KNOWS\"
   Key: V1 + V2 + KNOWS => returns edge ID (O(1) lookup)

   NOTES:
   - Immutable (changing breaks index format)
   - Total: 16 + 16 + 2 = 34 bytes
   - Enables constant-time edge lookups (vs. linear search)"
)
(alexandria:define-constant +null-vev-key+
  (make-array +vev-key-bytes+ :initial-element 0 :element-type '(unsigned-byte 8))
  :test 'equalp
  "Sentinel VEV-index key (all zeros).

   TYPE: 34-byte array of zeros

   PURPOSE:
   Lower bound for VEV-index range queries.

   NOTES:
   - Immutable
   - Analogous to +null-key+ but for VEV-index"
)
(alexandria:define-constant +max-vev-key+
  (make-array +vev-key-bytes+ :initial-element 255 :element-type '(unsigned-byte 8))
  :test 'equalp
  "Sentinel VEV-index key (all 0xFF).

   TYPE: 34-byte array of 0xFF

   PURPOSE:
   Upper bound for VEV-index range queries.

   NOTES:
   - Immutable
   - Complementary to +null-vev-key+"
)
;;;; ============================================================================
;;;; TYPE CODES: SERIALIZATION FORMAT IDENTIFIERS
;;;; ============================================================================

(alexandria:define-constant +needs-lookup+ :needs-lookup
  "Special code indicating value requires lookup at deserialization time.")

(alexandria:define-constant +unknown+ 0
  "Type code for unknown/uninitialized type.")

(alexandria:define-constant +negative-integer+ 1
  "Type code for negative integers.

   FORMAT: [1][signed-int-data]
   
   Used when serializing negative numbers (-1, -100, etc.)")

(alexandria:define-constant +positive-integer+ 2
  "Type code for non-negative integers.

   FORMAT: [2][unsigned-int-data]
   
   Used when serializing 0, positive numbers (0, 1, 100, etc.)")

(alexandria:define-constant +character+ 3
  "Type code for single characters.

   FORMAT: [3][char-code]
   
   Example: #\A becomes [3][65]")

(alexandria:define-constant +symbol+ 4
  "Type code for Lisp symbols.

   FORMAT: [4][symbol-name-string]
   
   Example: 'person becomes [4][\"PERSON\"]")

(alexandria:define-constant +string+ 5
  "Type code for strings.

   FORMAT: [5][string-length][string-data]
   
   Example: \"hello\" becomes [5][5][hello]")

(alexandria:define-constant +list+ 6
  "Type code for proper lists.

   FORMAT: [6][length][element1-serialized][element2-serialized]...
   
   Example: (1 2 3) becomes [6][3][2][1][2][2][3]")

(alexandria:define-constant +vector+ 7
  "Type code for vectors.

   FORMAT: [7][length][element1]...[elementN]")

(alexandria:define-constant +single-float+ 8
  "Type code for 32-bit floats.

   FORMAT: [8][4-byte-float-data]")

(alexandria:define-constant +double-float+ 9
  "Type code for 64-bit floats.

   FORMAT: [9][8-byte-float-data]")

(alexandria:define-constant +ratio+ 10
  "Type code for rational numbers.

   FORMAT: [10][numerator][denominator]
   
   Example: 1/3 becomes [10][1][3]")

(alexandria:define-constant +t+ 11
  "Type code for T (true).

   FORMAT: [11] (no data)
   
   Single bit of info: T (not NIL)")

(alexandria:define-constant +null+ 12
  "Type code for NIL (empty list / false).

   FORMAT: [12] (no data)
   
   Single bit of info: NIL (not T)")

(alexandria:define-constant +blob+ 13
  "Type code for uninterpreted binary data.

   FORMAT: [13][length][raw-bytes...]
   
   Used for opaque data blobs (arbitrary binary content)")

(alexandria:define-constant +dotted-list+ 14
  "Type code for improper lists.

   FORMAT: [14][elements...][tail]
   
   Example: (1 2 . 3) becomes [14][1][2][3]")

(alexandria:define-constant +keyword+ 15
  "Type code for keywords.

   FORMAT: [15][keyword-name]
   
   Example: :person becomes [15][\"PERSON\"]")

(alexandria:define-constant +slot-key+ 16
  "Type code for slot references.")

(alexandria:define-constant +id+ 17
  "Type code for node IDs (16-byte UUIDs).

   FORMAT: [17][16-byte-uuid]")

(alexandria:define-constant +vertex+ 18
  "Type code for vertex objects.

   FORMAT: [18][serialized-vertex-fields]")

(alexandria:define-constant +edge+ 19
  "Type code for edge objects.

   FORMAT: [19][serialized-edge-fields]")

(alexandria:define-constant +skip-list+ 20
  "Type code for skip list structures.")

(alexandria:define-constant +ve-index+ 21
  "Type code for vertex-edge index.")

(alexandria:define-constant +type-index+ 22
  "Type code for type index (vertex/edge type registry).")

(alexandria:define-constant +pcons+ 23
  "Type code for persistent cons cells.")

(alexandria:define-constant +pqueue+ 24
  "Type code for persistent queues.")

(alexandria:define-constant +mpointer+ 25
  "Type code for memory pointers (addresses in mmap).")

(alexandria:define-constant +pcell+ 26
  "Type code for persistent cells.")

(alexandria:define-constant +index-list+ 27
  "Type code for index list (list of node IDs).")

(alexandria:define-constant +vev-index+ 28
  "Type code for vertex-edge-vertex index.")

(alexandria:define-constant +bit-vector+ 29
  "Type code for bit vectors.")

(alexandria:define-constant +bignum+ 30
  "Type code for arbitrary-precision big integers.")

;; Codes 31-99 reserved for future use
;; Codes 100+ for user-defined types

(alexandria:define-constant +uuid+ 100
  "Type code for UUID objects (user-defined).

   FORMAT: [100][16-byte-uuid]
   
   User-defined type identifier space starts at 100.")

(alexandria:define-constant +timestamp+ 101
  "Type code for timestamp objects (user-defined).

   FORMAT: [101][timestamp-data]
   
   Another user-defined type.")

;;;; ============================================================================
;;;; RUNTIME PARAMETERS
;;;; ============================================================================

(defparameter *initial-extents* 10
  "Initial number of 100 MB memory-mapped extents.

   TYPE: Integer

   VALUE: 10 (default)

   DERIVATION:
   10 extents * 100 MB per extent = 1 GB initial allocation

   PURPOSE:
   New graphs allocate this many extents upfront.
   Avoids frequent reallocation when starting small.
   Avoids massive over-allocation for small databases.

   RATIONALE:
   - 10 extents (1 GB) is reasonable for most new databases
   - Small enough not to waste space
   - Large enough to avoid reallocation during normal operation

   CONFIGURATION:
   Could be made configurable per graph in future.
   Currently global parameter for simplicity.

   NOTES:
   - Mutable parameter (can be changed before graph creation)
   - Affects only graphs created after change
   - Existing graphs unchanged")

(defparameter *max-locks* 10000
  "Maximum number of concurrent locks in Prolog engine.

   TYPE: Integer

   VALUE: 10000

   PURPOSE:
   Prolog engine limit to prevent runaway lock allocation.
   Prevents memory exhaustion from infinite loops.

   NOTES:
   - Soft limit (enforced by engine)
   - Very generous (10K locks is plenty for normal use)
   - Can be increased if needed"
)
(defvar *graph-hash* nil
  "Internal hash table for graph name -> graph instance mapping.

   TYPE: Hash table (or NIL)

   PURPOSE:
   Similar to *graphs* in graph-class.lisp.
   Used internally for graph lifecycle management.

   NOTES:
   - Mutable (changes as graphs opened/closed)
   - Implementation detail (users should use lookup-graph)"
)
;;;; ============================================================================
;;;; PROLOG ENGINE STATE
;;;; ============================================================================

(defparameter *occurs-check* t
  "Enable occurs check in unification.

   TYPE: Boolean

   VALUE: T (enabled)

   PURPOSE:
   Prevents infinite structures during unification.
   
   EXAMPLE WITH OCCURS CHECK (T):
   (unify X '(cons X nil)) => FAILS (X occurs in structure)
   
   EXAMPLE WITHOUT OCCURS CHECK (NIL):
   (unify X '(cons X nil)) => SUCCEEDS (creates infinite structure)

   STANDARD BEHAVIOR:
   T = ISO Prolog (safer)
   NIL = Some Prologs (faster but less safe)

   NOTES:
   - Should be T for safety
   - Can be set to NIL for performance if trusted input
   - Affects all unification operations"
)
(defvar *trail* (make-array 200 :fill-pointer 0 :adjustable t)
  "Undo trail for backtracking in Prolog engine.

   TYPE: Adjustable array of variable bindings

   INITIAL SIZE: 200

   PURPOSE:
   Records variable bindings made during unification.
   On backtrack, undoes bindings in reverse order.

   MECHANISM:
   1. When variable X is unified with value V: push (X . V) on trail
   2. If unification fails, pop all bindings in reverse
   3. Variable X reverts to unbound state

   ADJUSTABLE:
   Grows as needed (fills 200 slots, then 400, 800, etc.)

   NOTES:
   - Critical for correct Prolog operation
   - Performance: pushing/popping is O(1)
   - Memory: grows with backtracking depth
   - Should be cleared between queries"
)
(defvar *var-counter* 0
  "Counter for generating unique variable names in Prolog.

   TYPE: Integer

   PURPOSE:
   Each time a new ? variable is created, increments this counter.
   Ensures no accidental name collisions.

   EXAMPLE:
   First ? variable created: ?_1
   Second ? variable: ?_2
   etc.

   USAGE:
   (let ((var-name (gensym \"?_\" *var-counter*)))
     (incf *var-counter*))

   NOTES:
   - Should be reset between top-level queries
   - Per-graph (each graph has own counter)
   - Prevents accidental variable name collisions"
)
(defvar *functor* nil
  "Current Prolog functor being compiled.

   TYPE: Symbol or NIL

   PURPOSE:
   During clause compilation, tracks current functor context.
   Used for error reporting and meta-programming.

   EXAMPLE:
   While compiling clause (person(X) :- ...), *functor* = PERSON

   NOTES:
   - Set by compile-clause
   - Useful for debugging and error messages
   - Mutable (changes with each clause)"
)
(defvar *select-list* nil
  "Accumulator for query results in Prolog select operations.

   TYPE: List or NIL

   PURPOSE:
   (select ...) operations accumulate results here.
   User retrieves results after query completes.

   USAGE:
   (let ((*select-list* nil))
     (query ...))  ; Select operations build *select-list*
   ;; Now *select-list* contains results

   NOTES:
   - Should be reset between queries
   - Mutable (built incrementally during query)"
)
(defvar *cont* nil
  "Continuation state for step-wise Prolog query execution.

   TYPE: Closure or NIL

   PURPOSE:
   For lazy evaluation of queries.
   Allows stopping query and resuming later.

   EXAMPLE:
   (let ((*cont* nil))
     (step-query ...)  ; Returns continuation
     (setf *cont* result)
     ... do something else ...
     (resume-query *cont*))  ; Continue from where stopped

   NOTES:
   - Advanced feature (not commonly used)
   - Mutable (changes with each step)
   - Enables coroutine-style queries"
)
;;;; ============================================================================
;;;; PLATFORM-SPECIFIC PROLOG FUNCTOR REGISTRIES
;;;; ============================================================================

#+sbcl
(defvar *prolog-global-functors*
  (make-hash-table :synchronized t)
  "Hash table of built-in Prolog predicates (SBCL version).

   TYPE: Thread-safe hash table

   PURPOSE:
   Stores compiled built-in predicates.
   
   THREADING: :synchronized t (SBCL's internal locking)

   NOTES:
   - SBCL-specific (uses SBCL's synchronized hash table)
   - Other platforms have equivalent versions below")

#+sbcl
(defvar *user-functors*
  (make-hash-table :synchronized t :test 'eql)
  "Hash table of user-defined Prolog predicates (SBCL version).

   TYPE: Thread-safe hash table with EQL test

   PURPOSE:
   Stores user-defined rules and clauses.

   TEST: eql (symbol identity, faster than equal)

   THREADING: :synchronized t (SBCL's internal locking)")

#+lispworks
(defvar *prolog-global-functors*
  (make-hash-table :single-thread nil)
  "Hash table of built-in Prolog predicates (LispWorks version).

   TYPE: Concurrent-access hash table

   PURPOSE:
   Stores compiled built-in predicates.

   THREADING: :single-thread nil (allows concurrent access)

   NOTES:
   - LispWorks-specific (uses LispWorks's concurrent hash table)
   - Equivalent to SBCL's :synchronized t")

#+lispworks
(defvar *user-functors*
  (make-hash-table :single-thread nil :test 'eql)
  "Hash table of user-defined Prolog predicates (LispWorks version).")

#+ccl
(defvar *prolog-global-functors*
  (make-hash-table :shared t)
  "Hash table of built-in Prolog predicates (CCL version).

   TYPE: Thread-shared hash table

   PURPOSE:
   Stores compiled built-in predicates.

   THREADING: :shared t (CCL's thread-shared mode)

   NOTES:
   - CCL-specific (uses CCL's shared hash table)
   - Equivalent to SBCL's :synchronized t")

#+ccl
(defvar *user-functors*
  (make-hash-table :shared t :test 'eql)
  "Hash table of user-defined Prolog predicates (CCL version).")

;;;; ============================================================================
;;;; PROLOG DEBUG/TRACE AND SPECIAL VALUES
;;;; ============================================================================

(defparameter *prolog-trace* nil
  "Enable Prolog execution trace output.

   TYPE: Boolean

   VALUE: NIL (trace disabled by default)

   PURPOSE:
   When T, prints all unification, backtracking, cut operations.
   Useful for debugging Prolog queries.

   USAGE:
   (let ((*prolog-trace* t))
     (select ... ...))  ; Trace output printed to *standard-output*

   OUTPUT:
   Each step prints:
   - Variable bindings
   - Unification attempts
   - Backtrack events
   - Cut operations

   NOTES:
   - Verbose output (can flood console)
   - Mutable (can be toggled at runtime)
   - Performance: trace off is faster (no string building)"
)
(alexandria:define-constant +unbound+ :unbound
  "Sentinel value for unbound variables in Prolog.

   TYPE: Symbol (:unbound)

   PURPOSE:
   Indicates variable has no value yet (not unified).
   Distinct from NIL (which is a value: the empty list).

   USAGE:
   (if (eq (var-value var) +unbound+)
     (error \"Variable ~A is unbound\" var)
     (process (var-value var)))

   NOTES:
   - Immutable (define-constant)
   - Necessary for Prolog's three-valued logic
   - Different from NIL"
)
(alexandria:define-constant +no-bindings+ '((t . t))
  :test 'equalp
  "Sentinel list representing no variable bindings.

   TYPE: List '((T . T))

   PURPOSE:
   Initial binding environment (no variables yet bound).
   Special marker distinct from NIL or empty list.

   USAGE:
   (let ((bindings +no-bindings+))
     (unify x y bindings))  ; Start with no bindings

   COMPARISON:
   +no-bindings+ is not '() (empty list)
   +no-bindings+ is not NIL
   +no-bindings+ is specific list '((T . T))

   NOTES:
   - Immutable (define-constant with :test 'equalp)
   - Prevents accidental == between +no-bindings+ and empty list"
)
(alexandria:define-constant +fail+ nil
  "Sentinel value indicating Prolog query failure.

   TYPE: NIL (not a special constant, just NIL)

   PURPOSE:
   Prolog queries return NIL when they fail.
   Non-NIL return indicates success with bindings.

   CONVENTION:
   Query returns:
   - NIL → query failed
   - non-NIL → query succeeded (bindings in car, continuation in cdr)

   NOTES:
   - Not a separate constant (just using NIL for failure)
   - Standard Prolog convention
   - Makes failure explicit in code"
)
;;;; ============================================================================
;;;; END OF GLOBALS
;;;; ============================================================================
