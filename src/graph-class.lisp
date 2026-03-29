;;;; src/graph-class.lisp
;;;; 
;;;; Graph Class Definition and Global Registry
;;;;
;;;; Purpose:
;;;;   Define the core GRAPH class and its two specialized subclasses:
;;;;   - MASTER-GRAPH: Coordinates master-slave replication
;;;;   - SLAVE-GRAPH: Replicates data from master
;;;;
;;;;   Also provides the global *graphs* registry for tracking all open graphs
;;;;   and simple type predicates for runtime type checking.
;;;;
;;;; Key Components:
;;;;   - *graphs*: Thread-safe hash table of all open graphs (by name)
;;;;   - GRAPH: 28-slot class defining persistence infrastructure
;;;;   - MASTER-GRAPH: Adds 5 replication-specific slots
;;;;   - SLAVE-GRAPH: Adds 5 replication-specific slots
;;;;   - Type predicates: graph-p, master-graph-p, slave-graph-p
;;;;   - Abstract generics: init-schema, update-schema, snapshot, etc.
;;;;
;;;; Architecture:
;;;;   *graphs* (global registry)
;;;;     ↓
;;;;   GRAPH (base class, 28 slots)
;;;;     ├─ MASTER-GRAPH (extends with 5 replication slots)
;;;;     └─ SLAVE-GRAPH (extends with 5 replication slots)
;;;;
;;;;   Each graph instance contains references to:
;;;;   - Vertex/edge tables (in-memory or memory-mapped)
;;;;   - Transaction log (ACID durability)
;;;;   - Indexes (ve-index, vev-index, type-index, vertex-index, edge-index)
;;;;   - Schema (type registry)
;;;;   - Views (materialized query results)
;;;;   - Statistics (write/read monitoring)

(in-package :graph-db)

;;;; ============================================================================
;;;; *GRAPHS* REGISTRY: Global Collection of All Open Graphs
;;;; ============================================================================

(defvar *graphs*
  #+sbcl
  (make-hash-table :test 'equal :synchronized t)
  #+lispworks
  (make-hash-table :test 'equal :single-thread nil)
  #+ccl
  (make-hash-table :test 'equal :shared t)
  (:documentation "Global registry of all open graph instances.

   PURPOSE:
   Tracks all currently open graphs by name, enabling:
   - Lookup by name (see lookup-graph function)
   - Prevention of duplicate graph names
   - Centralized graph lifecycle management

   TYPE:
   Hash table with string keys (graph names) and GRAPH values (instances)

   THREAD-SAFETY:
   Platform-specific thread-safe hash tables:
   - SBCL:      :synchronized t     (internal locking)
   - LispWorks: :single-thread nil  (concurrent access allowed)
   - CCL:       :shared t           (thread-shared hash table)

   USAGE:
   (gethash \"my-graph\" *graphs*)  ; => GRAPH instance or NIL
   (setf (gethash name *graphs*) graph-instance)

   NOTES:
   - Uses :test 'equal so string keys are compared by value
   - Not 'eq or 'eql (which compare by identity)
   - Example: (gethash \"db\" *graphs*) works even if you lost reference to the key
   - Should be cleared/reset when graphs are closed

   PERSISTENCE:
   NOT persisted to disk; rebuilt from filesystem on startup"))

;;;; ============================================================================
;;;; GRAPH CLASS: Core Persistence Infrastructure (28 slots)
;;;; ============================================================================

(defclass graph ()
  ((graph-name :accessor graph-name :initarg :graph-name
              :documentation "Name of this graph (string). Used as key in *graphs* registry. Example: \"production-db\"")

   (graph-open-p :accessor graph-open-p :initarg :graph-open-p :initform nil
                :documentation "Boolean: Is this graph currently open? false=closed, true=open")

   (location :accessor location :initarg :location
            :documentation "Filesystem path (string) where graph data is stored. Example: \"/var/lib/vivacegraph/mydb\"")

   (txn-log :accessor txn-log :initarg :txn-log
           :documentation "Transaction log object. Records all writes for ACID durability and crash recovery. Implements WAL (Write-Ahead Logging).")

   (txn-file :accessor txn-file :initarg :txn-file
            :documentation "File handle or filename for transaction log. Used for flushing writes to disk.")

   (txn-lock :accessor txn-lock :initarg :txn-lock :initform (make-recursive-lock)
            :documentation "Recursive lock for serializing concurrent transactions. Ensures ACID isolation (serial execution).")

   (transaction-manager :accessor transaction-manager :initarg :transaction-manager
                       :documentation "Transaction manager object (from Layer 3: transactions.lisp). Handles begin, commit, rollback, snapshot isolation.")

   (replication-key :accessor replication-key :initarg :replication-key
                   :documentation "Cryptographic key (or token) for authenticating replication connections between master and slaves.")

   (replication-port :accessor replication-port :initarg :replication-port
                    :documentation "Network port number (integer) for replication listener. Master listens on this port for slave connections.")

   (vertex-table :accessor vertex-table :initarg :vertex-table
                :documentation "Hash table or index of all vertices in this graph. Keys=vertex IDs, values=VERTEX instances or references.")

   (edge-table :accessor edge-table :initarg :edge-table
              :documentation "Hash table or index of all edges in this graph. Keys=edge IDs, values=EDGE instances or references.")

   (heap :accessor heap :initarg :heap
        :documentation "Memory-mapped heap object (mmap). Stores serialized node data (vertices, edges, custom types). Allocated via pmem library.")

   (indexes :accessor indexes :initarg :indexes
           :documentation "Hash table of all user-defined indexes on this graph. Keys=index names, values=INDEX objects (from Layer 5).")

   (schema :accessor schema :initarg :schema
          :documentation "Schema object tracking all types (from def-vertex, def-edge). Maps type-id to class, persistent slots, indexed slots.")

   (cache :accessor cache :initarg :cache
         :documentation "In-memory object cache (LRU or weak references). Caches recently accessed vertices/edges to avoid repeated heap lookups.")

   (ve-index-in :accessor ve-index-in :initarg :ve-index-in
               :documentation "Vertex-Edge IN-index. Maps vertex-id -> list of edges POINTING TO that vertex. For incoming traversal.")

   (ve-index-out :accessor ve-index-out :initarg :ve-index-out
                :documentation "Vertex-Edge OUT-index. Maps vertex-id -> list of edges LEAVING that vertex. For outgoing traversal.")

   (vev-index :accessor vev-index :initarg :vev-index
             :documentation "Vertex-Edge-Vertex index. Maps (source-id, edge-type) -> (target-id, edge-id). For fast edge lookup by source+type.")

   (vertex-index :accessor vertex-index :initarg :vertex-index
                :documentation "Type-index for vertices. Maps type-id -> list of all vertices of that type. Enables type-based queries.")

   (edge-index :accessor edge-index :initarg :edge-index
              :documentation "Type-index for edges. Maps type-id -> list of all edges of that type. Enables type-based edge queries.")

   (views-lock :accessor views-lock :initarg :views-lock :initform (make-recursive-lock)
              :documentation "Recursive lock for protecting concurrent access to materialized views (Layer 5: views.lisp).")

   (views :accessor views :initarg :views
         :documentation "Hash table of materialized views on this graph. Keys=view names, values=VIEW objects. Used for query optimization.")

   (write-stats :accessor write-stats :initarg :write-stats
               :initform
               #+ccl (make-hash-table :test 'eq :shared t)
               #+lispworks (make-hash-table :test 'eq :single-thread nil)
               #+sbcl (make-hash-table :test 'eq :synchronized t)
              :documentation "Hash table of write statistics. Keys=operation names (e.g., 'vertex-write', 'index-update'), values=counts/latencies.")

   (read-stats :accessor read-stats :initarg :read-stats
              :initform
              #+ccl (make-hash-table :test 'eq :shared t)
              #+lispworks (make-hash-table :test 'eq :single-thread nil)
              #+sbcl (make-hash-table :test 'eq :synchronized t)
             :documentation "Hash table of read statistics. Keys=operation names (e.g., 'vertex-read', 'index-scan'), values=counts/latencies."))

  (:documentation "Core graph database object representing a single graph instance.

   ROLE:
   Encapsulates all state for a single graph database. Contains:
   - Storage (heap, vertex-table, edge-table)
   - Transaction coordination (txn-log, txn-lock, transaction-manager)
   - Indexing infrastructure (ve-index, vev-index, vertex-index, edge-index)
   - Schema (type registry for vertices and edges)
   - Replication coordination (replication-key, replication-port)
   - Caching and views (cache, views, views-lock)
   - Statistics (write-stats, read-stats)

   28 SLOTS CATEGORIZED:
   1. Identity (3): graph-name, graph-open-p, location
   2. Transactions (4): txn-log, txn-file, txn-lock, transaction-manager
   3. Replication (2): replication-key, replication-port
   4. Storage (3): vertex-table, edge-table, heap
   5. Indexes (5): ve-index-in, ve-index-out, vev-index, vertex-index, edge-index
   6. Schema (1): schema
   7. Cache (1): cache
   8. Views (2): views, views-lock
   9. Statistics (2): write-stats, read-stats

   USAGE:
   Users do NOT instantiate GRAPH directly. Instead:
   (open-graph \"my-graph\")  ; Creates and registers GRAPH instance
   (lookup-graph \"my-graph\") ; Retrieves from *graphs* registry

   SUBCLASSES:
   - MASTER-GRAPH: For master in master-slave replication
   - SLAVE-GRAPH: For slave in master-slave replication

   PERSISTENCE:
   State is partially persisted:
   - Vertex/edge data: Persisted to heap
   - Metadata (schema, indexes): Persisted to separate files
   - Cache: NOT persisted (rebuilt on open)
   - Statistics: NOT persisted (reset on open)

   THREAD-SAFETY:
   - txn-lock: Serializes transactions
   - views-lock: Protects view access
   - Hash tables: Platform-specific thread-safe variants"))

(defmethod print-object ((graph graph) stream)
  "Print a GRAPH instance in readable format.

   FORMAT:
   #<GRAPH \"graph-name\" \"location\">

   EXAMPLE:
   #<GRAPH \"my-database\" \"/var/lib/vivacegraph/my-database\">

   USAGE:
   (format t \"~A\" graph)  ; Uses print-object

   NOTES:
   - Uses print-unreadable-object to prevent Lisp reader from trying to parse it
   - Shows graph name and filesystem location (most useful debug info)
   - Includes object identity (#x...) for debugging multiple graph instances"
  (print-unreadable-object (graph stream :type t :identity t)
    (format stream "~S ~S" (graph-name graph) (location graph))))

;;;; ============================================================================
;;;; MASTER-GRAPH: Replication Master Node
;;;; ============================================================================

(defclass master-graph (graph)
  ((replication-mbox :accessor replication-mbox :initarg :replication-mbox
                    :documentation "Mailbox (message queue) for receiving updates from slave nodes. Implements async replication protocol.")

   (replication-listener :accessor replication-listener :initarg :replication-listener
                        :documentation "Server thread listening on replication-port for incoming slave connections. Spawned when replication starts.")

   (stop-replication-p :accessor stop-replication-p :initarg :stop-replication-p :initform nil
                      :documentation "Boolean flag: Set to true to gracefully stop replication listener and disconnect all slaves.")

   (slaves :accessor slaves :initarg :slaves :initform ()
          :documentation "List of connected slave SLAVE-GRAPH instances. Updated as slaves connect/disconnect.")

   (slaves-lock :accessor slaves-lock :initarg :slaves-lock :initform (make-recursive-lock)
               :documentation "Recursive lock for thread-safe modification of slaves list."))

  (:documentation "Specialized GRAPH for master in master-slave replication.

   ROLE:
   Coordinates updates to all connected slave nodes. Acts as the single source of truth.

   INHERITANCE:
   Extends GRAPH with 5 additional slots for replication:
   - replication-mbox: Queue for slave updates
   - replication-listener: Server thread
   - stop-replication-p: Graceful shutdown flag
   - slaves: List of connected slaves
   - slaves-lock: Lock for thread-safe slave list

   REPLICATION PROTOCOL:
   1. Master waits for transaction commits
   2. For each committed transaction, sends updates to all slaves
   3. Slaves acknowledge receipt
   4. Master tracks master-txn-id on each slave

   USAGE:
   (make-instance 'master-graph :graph-name \"db\" :location \"/path\")

   NOTES:
   - Only one master per replication group
   - Can have multiple slaves
   - If master fails, slaves become orphaned (no automatic failover)"))

;;;; ============================================================================
;;;; SLAVE-GRAPH: Replication Slave Node
;;;; ============================================================================

(defclass slave-graph (graph)
  ((master-host :accessor master-host :initarg :master-host
               :documentation "Hostname or IP address of master node (string). Example: \"192.168.1.100\" or \"master.example.com\"")

   (slave-socket :accessor slave-socket :initarg :slave-socket
                :documentation "Network socket (TCP) connection to master. Used for receiving transaction updates and sending acknowledgments.")

   (stop-replication-p :accessor stop-replication-p :initarg :stop-replication-p :initform nil
                      :documentation "Boolean flag: Set to true to gracefully close connection to master and stop replication.")

   (slave-thread :accessor slave-thread :initarg :slave-thread :initform nil
                :documentation "Background thread running replication loop. Receives updates from master, applies to local heap.")

   (master-txn-id :accessor master-txn-id :initarg :master-txn-id
                 :documentation "Highest transaction ID successfully replicated from master (uint64). Used for resume on reconnect."))

  (:documentation "Specialized GRAPH for slave in master-slave replication.

   ROLE:
   Replicates data from a master node. Read-only by default (writes rejected).

   INHERITANCE:
   Extends GRAPH with 5 additional slots for replication:
   - master-host: Address of master node
   - slave-socket: TCP connection to master
   - stop-replication-p: Graceful shutdown flag
   - slave-thread: Background replication loop
   - master-txn-id: Highest replicated transaction ID

   REPLICATION PROTOCOL:
   1. Slave connects to master on startup
   2. Sends last known master-txn-id
   3. Master sends all newer transactions
   4. Slave applies to local heap (same format as master)
   5. Slave updates master-txn-id
   6. Loop: Wait for new updates from master

   USAGE:
   (make-instance 'slave-graph 
     :graph-name \"db-replica\"
     :location \"/path/to/replica\"
     :master-host \"master.example.com\")

   NOTES:
   - Inherits all 28 slots from GRAPH + 5 replication slots
   - Cannot initiate writes (master-only)
   - Can serve read-only requests to clients
   - Automatically reconnects on master failure
   - Lag behind master depends on network latency and transaction rate"))

;;;; ============================================================================
;;;; TYPE PREDICATES: Runtime Type Checking
;;;; ============================================================================

(defgeneric graph-p (thing)
  (:method ((graph graph)) graph)
  (:method (thing) nil)
  (:documentation "Check if THING is a GRAPH instance.

   ARGS:
   - thing: Any Lisp object

   RETURN:
   - The graph object itself if it is an instance of GRAPH (or subclass)
   - NIL otherwise

   USAGE:
   (if (graph-p obj)
     (process-graph obj)
     (error \"Not a graph\"))

   NOTES:
   - Returns the object itself (not just T), enabling pattern like:
     (when-let ((g (graph-p obj))) ...)
   - Works for GRAPH and all subclasses (MASTER-GRAPH, SLAVE-GRAPH)"))

(defgeneric master-graph-p (thing)
  (:method ((graph master-graph)) graph)
  (:method (thing) nil)
  (:documentation "Check if THING is a MASTER-GRAPH instance.

   ARGS:
   - thing: Any Lisp object

   RETURN:
   - The master-graph object itself if it matches
   - NIL otherwise

   USAGE:
   (when (master-graph-p graph)
     (start-replication graph))

   NOTES:
   - Does NOT return true for plain GRAPH or SLAVE-GRAPH instances
   - Useful for gating replication features to master only"))

(defgeneric slave-graph-p (thing)
  (:method ((graph slave-graph)) graph)
  (:method (thing) nil)
  (:documentation "Check if THING is a SLAVE-GRAPH instance.

   ARGS:
   - thing: Any Lisp object

   RETURN:
   - The slave-graph object itself if it matches
   - NIL otherwise

   USAGE:
   (when (slave-graph-p graph)
     (set-readonly-mode graph))

   NOTES:
   - Does NOT return true for plain GRAPH or MASTER-GRAPH instances
   - Useful for gating read-only behavior to slaves"))

;;;; ============================================================================
;;;; ABSTRACT GENERIC METHODS: Stubs for Higher Layers
;;;; ============================================================================

(defgeneric init-schema (graph)
  (:documentation "Initialize schema for a new graph.

   CONTEXT:
   Called when creating a new graph. Sets up the type registry.

   ARGS:
   - graph: GRAPH instance (or subclass)

   RETURN:
   Schema object (implementation-specific)

   IMPLEMENTATION:
   Defined in Layer 3 (transactions.lisp) or Layer 4 (serialize.lisp)

   NOTES:
   - Abstract (no default implementation here)
   - Subclasses must provide (:method ((graph graph)) ...)"))

(defgeneric update-schema (graph-or-name)
  (:documentation "Update schema from a graph instance or name.

   CONTEXT:
   Called when schema changes (e.g., new def-vertex, new index).

   ARGS:
   - graph-or-name: GRAPH instance or graph name (string)

   RETURN:
   Updated schema object

   IMPLEMENTATION:
   Defined in Layer 3+ (exact layer TBD)

   NOTES:
   - Abstract (no default implementation here)
   - Accepts both graph object and name for convenience"))

(defgeneric snapshot (graph &key &allow-other-keys)
  (:documentation "Create a snapshot of graph state at a point in time.

   CONTEXT:
   For MVCC and crash recovery. Captures consistent view.

   ARGS:
   - graph: GRAPH instance
   - &key ...: Implementation-specific options (e.g., :name, :timestamp)

   RETURN:
   Snapshot object or identifier

   IMPLEMENTATION:
   Defined in Layer 3 (transactions.lisp) or Layer 4

   NOTES:
   - Abstract (no default implementation here)
   - &allow-other-keys allows flexible implementation"))

(defgeneric scan-for-unindexed-nodes (graph)
  (:documentation "Scan heap for nodes that haven't been indexed yet.

   CONTEXT:
   Used during recovery or index reconstruction to find all nodes
   that need to be added to type-index and other indexes.

   ARGS:
   - graph: GRAPH instance

   RETURN:
   List of node objects (or node IDs) that need indexing

   IMPLEMENTATION:
   Defined in Layer 5+ (indexes.lisp or views.lisp)

   NOTES:
   - Abstract (no default implementation here)
   - Expensive operation (scans entire heap)"))

(defgeneric start-replication (graph &key package)
  (:documentation "Start replication on a graph.

   CONTEXT:
   Called on master to start accepting slave connections.
   Called on slave to start replicating from master.

   ARGS:
   - graph: GRAPH instance (MASTER-GRAPH or SLAVE-GRAPH)
   - &key package: Package for message serialization (optional)

   RETURN:
   T if successful, or replication object

   IMPLEMENTATION:
   Defined in Layer 6+ (replication.lisp, exact location TBD)

   NOTES:
   - Abstract (no default implementation here)
   - Different behavior for MASTER-GRAPH vs SLAVE-GRAPH"))

(defgeneric stop-replication (graph)
  (:documentation "Stop replication on a graph.

   CONTEXT:
   Gracefully shuts down replication listener (master) or connection (slave).

   ARGS:
   - graph: GRAPH instance (MASTER-GRAPH or SLAVE-GRAPH)

   RETURN:
   T if successful

   IMPLEMENTATION:
   Defined in Layer 6+ (replication.lisp)

   NOTES:
   - Abstract (no default implementation here)
   - Should be idempotent (safe to call multiple times)"))

;;;; ============================================================================
;;;; UTILITY FUNCTION: Graph Registry Lookup
;;;; ============================================================================

(defun lookup-graph (name)
  "Retrieve a graph from the global *graphs* registry by name.

   ARGS:
   - name: Graph name (string)

   RETURN:
   - GRAPH instance if found
   - NIL if not found

   ALGORITHM:
   Simple hash table lookup: (gethash name *graphs*)

   USAGE:
   (let ((g (lookup-graph \"production-db\")))
     (if g
       (process-graph g)
       (error \"Graph not found: ~A\" name)))

   NOTES:
   - Uses string comparison (:test 'equal in *graphs* hash table)
   - Returns NIL for non-existent graphs (not an error)
   - Thread-safe (hash table is thread-safe on all platforms)

   RELATED:
   - See *graphs* for registry details
   - See open-graph and close-graph for lifecycle"
  (gethash name *graphs*))