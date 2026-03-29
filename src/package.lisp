;;;; src/package.lisp
;;;; 
;;;; VivaceGraph Module Definition
;;;;
;;;; Purpose:
;;;;   Define the :graph-db package and export all public API symbols.
;;;;
;;;; This is the single public interface for VivaceGraph.
;;;; Users import via: (use-package :graph-db)

(in-package #:cl-user)

(defpackage #:graph-db
  (:use #:cl                    ; Common Lisp base
        #:bordeaux-threads       ; Cross-platform threading primitives
        #:local-time             ; DateTime library (for timestamps)
        #+ccl #:closer-mop       ; CCL: portable MOP on top of CCL
        #+lispworks #:clos       ; LispWorks: native CLOS
        #+sbcl #:sb-mop          ; SBCL: internal MOP package
        #+sbcl #:sb-pcl)         ; SBCL: internal PCL package
  
  ;; Platform-specific shadowing imports (avoid symbol conflicts)
  #+sbcl (:shadowing-import-from "SB-EXT" "WORD")
  
  ;; CCL: Import closer-mop generics to shadow CCL's native versions
  ;; Enables portable MOP code across platforms
  #+ccl (:shadowing-import-from "CLOSER-MOP" "STANDARD-METHOD")
  #+ccl (:shadowing-import-from "CLOSER-MOP" "FINALIZE-INHERITANCE")
  #+ccl (:shadowing-import-from "CLOSER-MOP" "STANDARD-GENERIC-FUNCTION")
  #+ccl (:shadowing-import-from "CLOSER-MOP" "DEFMETHOD")
  #+ccl (:shadowing-import-from "CLOSER-MOP" "DEFGENERIC")
  #+ccl (:shadowing-import-from "CLOSER-MOP" "STANDARD-CLASS")
  #+ccl (:shadowing-import-from "CLOSER-MOP" "COMPUTE-DISCRIMINATING-FUNCTION")
  #+ccl (:shadowing-import-from "CLOSER-MOP" "COMPUTE-APPLICABLE-METHODS-USING-CLASSES")
  #+ccl (:shadowing-import-from "CLOSER-MOP" "COMPUTE-EFFECTIVE-METHOD")
  #+ccl (:shadowing-import-from "CLOSER-MOP" "METHOD-FUNCTION")
  #+ccl (:shadowing-import-from "CLOSER-MOP" "MAKE-METHOD-LAMBDA")

  ;; ~120 exported symbols organized by subsystem
  
  (:export 
    ;; Graph lifecycle (src/graph-class.lisp, src/transactions.lisp)
    #:make-graph              ; Create new graph
    #:open-graph              ; Open existing graph
    #:close-graph             ; Close graph
    #:lookup-graph            ; Retrieve graph by name
    #:graph-stats             ; Get statistics
    #:check-data-integrity    ; Validate heap consistency
    #:snapshot                ; Create snapshot
    #:replay                  ; Replay transaction log
    #:restore                 ; Restore from snapshot
    #:location                ; Filesystem path accessor
    #:schema                  ; Type registry accessor
    #:indexes                 ; Index table accessor
    #:*graph*                 ; Dynamic variable for current graph

    ;; Transactions (src/transactions.lisp)
    #:execute-tx              ; Execute transaction body
    #:transaction-p           ; Type predicate
    #:graph-name              ; Graph name accessor
    #:transaction-error       ; Exception class
    #:with-transaction        ; Macro: auto-commit/rollback
    #:lookup-object           ; Retrieve node by ID
    #:update-node             ; Update node slot
    #:delete-node             ; Delete node
    #:commit                  ; Commit transaction
    #:rollback                ; Abort transaction
    #:*transaction*           ; Current transaction variable
    #:no-transaction-in-progress  ; Exception

    ;; Replication (src/replication.lisp)
    #:master-host             ; Master hostname accessor
    #:replication-port        ; Port accessor
    #:slave-socket            ; Socket accessor
    #:replication-key         ; Auth key accessor
    #:master-txn-id           ; Transaction ID accessor
    #:stop-replication-p      ; Shutdown flag accessor
    #:execute-tx-action       ; Execute action from master
    #:write-last-txn-id       ; Write slave transaction ID
    #:read-last-txn-id        ; Read slave transaction ID
    #:start-replication       ; Start replication
    #:stop-replication        ; Stop replication
    #:stop-buffer-pool        ; Flush buffers

    ;; REST API (src/rest.lisp)
    #:start-rest              ; Start HTTP server
    #:stop-rest               ; Stop HTTP server
    #:def-rest-procedure      ; Define REST endpoint
    #:*rest-procedures*       ; Procedures registry

    ;; Node types (src/node-types.lisp)
    #:def-node-type           ; Define custom node type
    #:def-vertex              ; Define vertex type
    #:def-edge                ; Define edge type
    #:edge-exists-p           ; Check edge existence
    #:lookup-node-type-by-name ; Get type by name
    #:instantiate-node-type   ; Create instance
    #:*schema-node-metadata*  ; Schema metadata
    #:with-write-locked-class ; Lock class for write
    #:with-read-locked-class  ; Lock class for read
    #:schema-class-locks      ; Locks per class

    ;; SBCL-specific read-write locks
    #+sbcl #:make-rw-lock
    #+sbcl #:with-read-lock
    #+sbcl #:with-write-lock
    #+sbcl #:acquire-read-lock
    #+sbcl #:release-read-lock
    #+sbcl #:acquire-write-lock
    #+sbcl #:release-write-lock
    #+sbcl #:rw-lock-p

    ;; Node objects (src/clos.lisp, src/node-class.lisp)
    #:vertex                  ; Vertex class
    #:edge                    ; Edge class
    #:generic-edge            ; Generic edge base
    #:generic-vertex          ; Generic vertex base
    #:make-vertex             ; Create vertex
    #:make-edge               ; Create edge
    #:lookup-vertex           ; Retrieve vertex by ID
    #:lookup-edge             ; Retrieve edge by ID
    #:to                      ; Target vertex accessor
    #:from                    ; Source vertex accessor
    #:weight                  ; Edge weight accessor
    #:id                      ; Node ID (16-byte UUID)
    #:string-id               ; ID as string
    #:node-to-alist           ; Convert to assoc list
    #:type-id                 ; Type registry ID
    #:revision                ; MVCC version
    #:deleted-p               ; Soft-delete flag
    #:active-edge-p           ; Check if not deleted
    #:data                    ; User data accessor
    #:traverse                ; Graph traversal
    #:traversal-path          ; Path in traversal
    #:end-vertex              ; Final vertex
    #:map-vertices            ; Map function over vertices
    #:map-edges               ; Map function over edges
    #:outgoing-edges          ; Edges from vertex
    #:incoming-edges          ; Edges to vertex
    #:node-slot-value         ; Get slot value
    #:copy                    ; Clone node
    #:save                    ; Persist node
    #:mark-deleted            ; Soft delete
    #:stale-revision-error    ; Version conflict exception

    ;; Views (src/views.lisp)
    #:def-view                ; Define materialized view
    #:*view-rv*               ; View result variable
    #:yield                   ; Emit result
    #:map-view                ; Map function over view
    #:map-reduced-view        ; Map with reduction
    #:invoke-graph-view       ; Execute view
    #:make-view               ; Create view
    #:delete-view             ; Delete view
    #:save-views              ; Persist views
    #:restore-views           ; Load views
    #:get-view-table-for-class ; Get view table
    #:regenerate-view         ; Rebuild view
    #:lookup-view-group       ; Get view group
    #:lookup-view             ; Get view
    #:with-write-locked-view-group  ; Lock for write
    #:with-read-locked-view-group   ; Lock for read
    #:view-group-lock         ; Lock object

    ;; Prolog engine (src/prolog.lisp)
    #:def-global-prolog-functor      ; Define predicate
    #:def-prolog-compiler-macro      ; Compiler macro
    #:compile-body                   ; Compile clause body
    #:args                           ; Arguments
    #:*prolog-global-functors*       ; Functor registry
    #:deref-exp                      ; Dereference expression
    #:unify                          ; Unification
    #:select                         ; Query results
    #:?                              ; Query operator
    #:?-                             ; Query clause
    #:q-                             ; Quoted query
    #:!                              ; Cut operator
    #:cut                            ; Cut (explicit)
    #:var-deref                      ; Variable dereference
    #:undo-bindings                  ; Backtrack
    #:replace-?-vars                 ; Replace ? variables
    #:variables-in                   ; Extract variables
    #:make-functor-symbol            ; Create functor name
    #:*trail*                        ; Undo trail
    #:*var-counter*                  ; Variable counter
    #:*functor*                      ; Current functor
    #:make-functor                   ; Create functor
    #:maybe-add-undo-bindings        ; Conditional undo
    #:compile-clause                 ; Compile clause
    #:show-prolog-vars               ; Debug output
    #:prolog-error                   ; Exception
    #:prolog-ignore                  ; Suppress errors
    #:delete-functor                 ; Remove functor
    #:set-functor-fn                 ; Set functor function
    #:*seen-table*                   ; Visited set
    #:*select-flat*                  ; Flat results
    #:*select-list*                  ; List results
    #:select-count                   ; Count results
    #:*select-count*                 ; Count variable
    #:*select-skip*                  ; Skip count
    #:*select-current-count*         ; Current count
    #:*select-current-skip*          ; Current skip
    #:select-one                     ; Single result
    #:select-flat                    ; Flat selection
    #:select-first                   ; First result
    #:do-query                       ; Execute query
    #:map-query                      ; Map over query
    #:valid-prolog-query-p           ; Type check
    #:init-prolog                    ; Initialize
    #:*prolog-graph*                 ; Current graph
    #:*prolog-trace*                 ; Trace flag
    #:trace-prolog                   ; Enable trace
    #:untrace-prolog                 ; Disable trace
    #:make-node-table                ; Create table
    #:node-equal                     ; Node equality
    ))

;;;; ============================================================================
;;;; NOTES ON DESIGN
;;;; ============================================================================
;;;; 
;;;; This single package file centralizes all public API.
;;;; 
;;;; Subsystems covered:
;;;;   1. Graph lifecycle (make, open, close, stats)
;;;;   2. Transactions (ACID, snapshot isolation)
;;;;   3. Nodes (vertices, edges, generic types)
;;;;   4. Replication (master-slave sync)
;;;;   5. Views (materialized queries)
;;;;   6. Prolog engine (logical reasoning, queries)
;;;;   7. REST (HTTP API)
;;;;
;;;; Platform support:
;;;;   - SBCL (Linux, primary target)
;;;;   - CCL (macOS, Windows)
;;;;   - LispWorks (commercial, supported)
;;;;
;;;; All symbols are qualified with #: prefix in exports,
;;;; enabling safe dynamic import/export.
