;;;; src/uuid.lisp
;;;; 
;;;; RFC 4122 UUID Serialization and Memory-Mapped Integration
;;;;
;;;; Purpose:
;;;;   Provide bidirectional conversion between UUID objects and:
;;;;   - Byte arrays (for in-memory storage)
;;;;   - Memory-mapped file regions (for persistent storage)
;;;;
;;;;   Implements RFC 4122 standard format with big-endian byte order.
;;;;
;;;; Architecture:
;;;;   UUID object (16 fields: time-low, time-mid, etc)
;;;;     ↓
;;;;   Byte array (16 or 18 bytes)
;;;;     ↓
;;;;   Memory-mapped file (mmap)
;;;;
;;;; Key Functions:
;;;;   - uuid-to-byte-array: UUID → byte array (16 or 18 bytes)
;;;;   - mmap-array-to-uuid: bytes → UUID object
;;;;   - uuid-to-mfp: UUID → memory-mapped file
;;;;   - uuid?, uuid-eql: Type predicates and equality
;;;;
;;;; RFC 4122 Byte Layout (16 bytes):
;;;;   Offset | Size | Field | Example
;;;;   ────────────────────────────────────
;;;;   0-3    | 4    | time-low | 0x6ba7b810
;;;;   4-5    | 2    | time-mid | 0x9dad
;;;;   6-7    | 2    | time-high-and-version | 0x11d1
;;;;   8      | 1    | clock-seq-and-reserved | 0x80
;;;;   9      | 1    | clock-seq-low | 0xb4
;;;;   10-15  | 6    | node | 0x00c04fd430c8
;;;;
;;;;   Canonical text format: 8-4-4-2-2-12 hex digits separated by dashes
;;;;   Example: 6ba7b810-9dad-11d1-80b4-00c04fd430c8

(in-package #:uuid)

(require :cffi)

;;;; ============================================================================
;;;; EXPORTS: Public API
;;;; ============================================================================

(export 'time-low)          ; Slot accessor (4-byte field)
(export 'time-mid)          ; Slot accessor (2-byte field)
(export 'time-high)         ; Slot accessor (2-byte field, often time-high-and-version)
(export 'clock-seq-var)     ; Slot accessor (variant bits)
(export 'clock-seq-low)     ; Slot accessor (1-byte field)
(export 'node)              ; Slot accessor (6-byte MAC address or random)
(export 'time-high-and-version)    ; Slot accessor (full 16-bit field)
(export 'clock-seq-and-reserved)   ; Slot accessor (full 16-bit field)
(export 'uuid-eql)          ; Generic: UUID equality
(export 'uuid?)             ; Generic: UUID type predicate
(export 'mmap-array-to-uuid) ; Function: bytes → UUID
(export 'uuid-to-mfp)       ; Function: UUID → mmap

;;;; ============================================================================
;;;; TYPE PREDICATES: UUID Type Checking
;;;; ============================================================================

(defgeneric uuid? (thing)
  (:method ((thing uuid)) t)
  (:method (thing) nil)
  (:documentation "Predicate: Is THING a UUID instance?

   ARGS:
   - thing: Any Lisp object

   RETURN:
   T if thing is a uuid instance, NIL otherwise

   USAGE:
   (if (uuid? obj) (process-uuid obj) (error \"Not a UUID\"))

   NOTES:
   - Simple type check (dispatch on uuid class)
   - Works for all UUID objects regardless of version"))

(defgeneric uuid-eql (uuid1 uuid2)
  (:method ((uuid1 uuid) (uuid2 uuid))
    (equalp (uuid-to-byte-array uuid1) (uuid-to-byte-array uuid2)))
  (:method ((uuid1 uuid) uuid2)
    nil)
  (:method (uuid1 (uuid2 uuid))
    nil)
  (:documentation "Check equality of two UUIDs.

   ARGS:
   - uuid1, uuid2: UUID objects (or other types)

   RETURN:
   T if both are UUIDs with identical bytes, NIL otherwise

   ALGORITHM:
   Converts both to byte arrays and uses equalp (element-wise equality)

   USAGE:
   (uuid-eql id1 id2)  => T or NIL

   NOTES:
   - Compares full 16-byte value (RFC 4122 format)
   - Returns NIL if either argument is not a UUID
   - More reliable than direct object comparison"))

;;;; ============================================================================
;;;; PRINT METHOD: RFC 4122 Canonical Text Format
;;;; ============================================================================

(defmethod print-object ((id uuid:uuid) stream)
  "Print UUID in RFC 4122 canonical text format.

   FORMAT:
   8-4-4-2-2-12 hex digits separated by dashes (lowercase)

   EXAMPLE:
   6ba7b810-9dad-11d1-80b4-00c04fd430c8

   ALGORITHM:
   Format fields: time-low (8 hex), time-mid (4 hex), time-high (4 hex),
                  clock-seq-var (2 hex), clock-seq-low (2 hex), node (12 hex)

   USAGE:
   (print id)  ; Via print-object
   (format t \"~A\" id)  ; Via format

   NOTES:
   - Canonical format from RFC 4122
   - Uses lowercase (specified by ~( in format directive)
   - Zero-padded (specified by '0 in format directive)"
  (format stream "~(~8,'0X~4,'0X~4,'0X~2,'0X~2,'0X~12,'0X~)"
          (time-low id)
          (time-mid id)
          (time-high id)
          (clock-seq-var id)
          (clock-seq-low id)
          (node id)))

;;;; ============================================================================
;;;; BYTE ACCESS PRIMITIVES: Memory-Mapped File Operations
;;;; ============================================================================

(defun set-byte (mfp offset byte)
  "Write a single byte to memory-mapped region.

   ARGS:
   - mfp: Memory-mapped pointer (from mmap library)
   - offset: Byte offset (0-based index)
   - byte: Unsigned 8-bit integer (0-255)

   RETURN:
   The byte written (side effect: modifies mmap region)

   ALGORITHM:
   Uses CFFI mem-aref to access memory as unsigned-char array

   NOTES:
   - Direct memory access; no bounds checking
   - Offset is relative to mfp pointer
   - FFI operation; potential performance cost"
  (setf (cffi:mem-aref mfp :unsigned-char offset) byte))
  ;;(setf (sb-alien:deref mfp offset) byte))  ; SBCL-specific (commented out)

(defun get-byte (mfp offset)
  "Read a single byte from memory-mapped region.

   ARGS:
   - mfp: Memory-mapped pointer
   - offset: Byte offset (0-based)

   RETURN:
   Unsigned 8-bit integer (0-255)

   ALGORITHM:
   Uses CFFI mem-aref to read memory as unsigned-char

   NOTES:
   - Direct memory access; no bounds checking
   - Offset is relative to mfp pointer"
  (cffi:mem-aref mfp :unsigned-char offset))
  ;;(sb-alien:deref mfp offset))  ; SBCL-specific (commented out)

;;;; ============================================================================
;;;; BYTE ASSEMBLY MACRO: Extract Multi-Byte Integers from Memory
;;;; ============================================================================

(defmacro mmap-array-to-bytes (from to mfp)
  "Extract a multi-byte integer from memory-mapped region.

   PURPOSE:
   Helper for deserializing UUID fields from mmap.
   Assembles individual bytes into a single multi-byte integer.

   ARGS:
   - from: Starting byte offset (inclusive)
   - to: Ending byte offset (inclusive)
   - mfp: Memory-mapped pointer

   RETURN:
   Unsigned integer combining bytes from 'from' to 'to'

   ALGORITHM:
   Loop from 'from' to 'to':
     For each byte i, deposit into result at bit position 8*(to-i)
   Returns assembled multi-byte integer

   BIT OPERATION:
   Uses ldb (load/deposit byte):
     (ldb (byte 8 (* 8 (- to i))) res)
       → Deposits 8 bits (byte) at position 8*(to-i) in res
     Positions bytes in big-endian order (RFC 4122 standard)

   EXAMPLE:
   (mmap-array-to-bytes 0 3 mfp)
     → Reads bytes 0,1,2,3 and assembles into 32-bit time-low
     → Byte 0 goes to bits 24-31 (most significant)
     → Byte 3 goes to bits 0-7 (least significant)

   NOTES:
   - Loop order (from to to) is ascending, but bit positions are descending
   - This achieves big-endian byte order (RFC 4122)
   - Macro expands to inline loop (efficient)"
  `(loop for i from ,from to ,to
         with res = 0
         do (setf (ldb (byte 8 (* 8 (- ,to i))) res) (get-byte ,mfp i))
         finally (return res)))

;;;; ============================================================================
;;;; DESERIALIZATION: Bytes → UUID Object
;;;; ============================================================================

(defun mmap-array-to-uuid (mfp offset)
  "Deserialize UUID from memory-mapped region.

   PURPOSE:
   Convert a 16-byte region in mmap to a UUID object.

   ARGS:
   - mfp: Memory-mapped pointer
   - offset: Byte offset (where UUID data starts)

   RETURN:
   New UUID instance with fields extracted from mmap

   ALGORITHM:
   1. Extract time-low (bytes 0-3): 32-bit multi-byte integer
   2. Extract time-mid (bytes 4-5): 16-bit integer
   3. Extract time-high (bytes 6-7): 16-bit integer
   4. Extract clock-seq-var (byte 8): Single byte
   5. Extract clock-seq-low (byte 9): Single byte
   6. Extract node (bytes 10-15): 48-bit integer
   7. Create and return new UUID instance

   BYTE LAYOUT (16 bytes):
   Offset 0-3:   time-low (4 bytes)
   Offset 4-5:   time-mid (2 bytes)
   Offset 6-7:   time-high (2 bytes)
   Offset 8:     clock-seq-var (1 byte)
   Offset 9:     clock-seq-low (1 byte)
   Offset 10-15: node (6 bytes)

   USAGE:
   (mmap-array-to-uuid heap-ptr 1024)
     ; Read UUID from heap pointer, starting at byte offset 1024

   NOTES:
   - Inverse of uuid-to-mfp
   - Assumes well-formed UUID data at offset
   - No validation (garbage in → garbage out)"
  (make-instance 'uuid
                 :time-low (mmap-array-to-bytes offset (+ 3 offset) mfp)
                 :time-mid (mmap-array-to-bytes (+ 4 offset) (+ 5 offset) mfp)
                 :time-high (mmap-array-to-bytes (+ 6 offset) (+ 7 offset) mfp)
                 :clock-seq-var (get-byte mfp (+ 8 offset))
                 :clock-seq-low (get-byte mfp (+ 9 offset))
                 :node (mmap-array-to-bytes (+ 10 offset) (+ 15 offset) mfp)))

;;;; ============================================================================
;;;; SERIALIZATION: UUID Object → Memory-Mapped Region
;;;; ============================================================================

(defun uuid-to-mfp (uuid mfp offset &optional type-specifier)
  "Serialize UUID to memory-mapped region.

   PURPOSE:
   Write UUID object to a region in mmap (memory-mapped file).

   ARGS:
   - uuid: UUID instance to serialize
   - mfp: Memory-mapped pointer (destination)
   - offset: Byte offset (where to write)
   - type-specifier: Optional type byte (default: NIL)
                     If provided, writes [type][16 UUID bytes] (18 total)
                     If NIL, writes [16 UUID bytes] only

   RETURN:
   Updated offset (for chaining multiple writes)

   ALGORITHM:
   1. If type-specifier: Write type byte at offset, then increment offset
      Else: Decrement offset (offset is pre-allocated for type byte)
   2. Extract each field from UUID using with-slots
   3. For each multi-byte field, deposit individual bytes using ldb
   4. Return incremented offset (after 16 bytes)

   CONDITIONAL FORMAT:
   - With type-specifier (18 bytes):
     [Byte 0: type-specifier] [Bytes 1-16: UUID data]
   - Without (16 bytes):
     [Bytes 0-15: UUID data]

   USAGE:
   (uuid-to-mfp my-uuid heap-ptr 1024)
     ; Write UUID to heap at offset 1024 (16 bytes)
   (uuid-to-mfp my-uuid heap-ptr 1024 42)
     ; Write UUID with type-specifier 42 at offset 1024 (18 bytes)

   NOTES:
   - Inverse of mmap-array-to-uuid
   - Returns updated offset for writing next object
   - Byte order: big-endian (RFC 4122)
   - Uses with-slots for field access (efficient)"
  (if type-specifier
      (set-byte mfp offset type-specifier)
      (decf offset))
  (with-slots
      (time-low time-mid time-high-and-version clock-seq-and-reserved clock-seq-low node)
      uuid
    ;; Write time-low (4 bytes, most significant byte first)
    (loop for i from 3 downto 0
       do (set-byte mfp (incf offset) (ldb (byte 8 (* 8 i)) time-low)))
    ;; Write time-mid (2 bytes)
    (loop for i from 1 downto 0
       do (set-byte mfp (incf offset) (ldb (byte 8 (* 8 i)) time-mid)))
    ;; Write time-high-and-version (2 bytes)
    (loop for i from 1 downto 0
       do (set-byte mfp (incf offset) (ldb (byte 8 (* 8 i)) time-high-and-version)))
    ;; Write clock-seq-and-reserved (1 byte)
    (set-byte mfp (incf offset) (ldb (byte 8 0) clock-seq-and-reserved))
    ;; Write clock-seq-low (1 byte)
    (set-byte mfp (incf offset) (ldb (byte 8 0) clock-seq-low))
    ;; Write node (6 bytes)
    (loop for i from 5 downto 0
       do (set-byte mfp (incf offset) (ldb (byte 8 (* 8 i)) node)))
    (incf offset)))

;;;; ============================================================================
;;;; SERIALIZATION: UUID Object → Byte Array
;;;; ============================================================================

(defun uuid-to-byte-array (uuid &optional (type-specifier nil))
  "Serialize UUID to byte array (in-memory).

   PURPOSE:
   Convert UUID object to vector of unsigned bytes.

   ARGS:
   - uuid: UUID instance
   - type-specifier: Optional type byte (default: NIL)

   RETURN:
   Byte array (simple-array of unsigned-byte 8):
   - If type-specifier: 18-byte array [type | 16 UUID bytes]
   - Else: 16-byte array [UUID bytes]

   TWO CODE PATHS:

   Path 1 (with type-specifier): 18-byte format
     Array layout:
       [0]: type-specifier byte
       [1]: length indicator (16)
       [2-17]: UUID bytes (16 bytes)

   Path 2 (without): 16-byte format
     Array layout:
       [0-15]: UUID bytes (16 bytes)

   ALGORITHM:
   For each UUID field (time-low, time-mid, etc):
     For each byte in field:
       Extract byte using ldb
       Store in array at calculated index

   BYTE ORDER: Big-endian (RFC 4122)

   USAGE:
   (uuid-to-byte-array my-uuid)
     => #(0xXX 0xXX ... 0xXX)  ; 16-byte vector
   (uuid-to-byte-array my-uuid 42)
     => #(42 16 0xXX ... 0xXX)  ; 18-byte vector with type

   NOTES:
   - Creates new array each time (non-destructive)
   - Inverse of mmap-array-to-uuid (for byte arrays)
   - Commonly used for in-memory operations
   - Different indexing between the two paths (error-prone!)"
  (if type-specifier
      ;; 18-byte format with type-specifier header
      (let ((array (make-array 18 :element-type '(unsigned-byte 8))))
        (setf (aref array 0) type-specifier)
        (setf (aref array 1) 16)  ; Length indicator
        (with-slots
              (time-low time-mid time-high-and-version clock-seq-and-reserved clock-seq-low node)
            uuid
          ;; time-low: 4 bytes, stored at indices 2-5
          (loop for i from 3 downto 0
             do (setf (aref array (+ 2 (- 3 i))) (ldb (byte 8 (* 8 i)) time-low)))
          ;; time-mid: 2 bytes, stored at indices 6-7
          (loop for i from 5 downto 4
             do (setf (aref array (+ 2 i)) (ldb (byte 8 (* 8 (- 5 i))) time-mid)))
          ;; time-high-and-version: 2 bytes, stored at indices 8-9
          (loop for i from 7 downto 6
             do (setf (aref array (+ 2 i)) (ldb (byte 8 (* 8 (- 7 i))) time-high-and-version)))
          ;; clock-seq-and-reserved: 1 byte, stored at index 10
          (setf (aref array (+ 2 8)) (ldb (byte 8 0) clock-seq-and-reserved))
          ;; clock-seq-low: 1 byte, stored at index 11
          (setf (aref array (+ 2 9)) (ldb (byte 8 0) clock-seq-low))
          ;; node: 6 bytes, stored at indices 12-17
          (loop for i from 15 downto 10
             do (setf (aref array (+ 2 i)) (ldb (byte 8 (* 8 (- 15 i))) node)))
          array))
      ;; 16-byte format without header
      (let ((array (make-array 16 :element-type '(unsigned-byte 8))))
        (with-slots
              (time-low time-mid time-high-and-version clock-seq-and-reserved clock-seq-low node)
            uuid
          ;; time-low: 4 bytes, stored at indices 0-3
          (loop for i from 3 downto 0
             do (setf (aref array (- 3 i)) (ldb (byte 8 (* 8 i)) time-low)))
          ;; time-mid: 2 bytes, stored at indices 4-5
          (loop for i from 5 downto 4
             do (setf (aref array i) (ldb (byte 8 (* 8 (- 5 i))) time-mid)))
          ;; time-high-and-version: 2 bytes, stored at indices 6-7
          (loop for i from 7 downto 6
             do (setf (aref array i) (ldb (byte 8 (* 8 (- 7 i))) time-high-and-version)))
          ;; clock-seq-and-reserved: 1 byte, stored at index 8
          (setf (aref array 8) (ldb (byte 8 0) clock-seq-and-reserved))
          ;; clock-seq-low: 1 byte, stored at index 9
          (setf (aref array 9) (ldb (byte 8 0) clock-seq-low))
          ;; node: 6 bytes, stored at indices 10-15
          (loop for i from 15 downto 10
             do (setf (aref array i) (ldb (byte 8 (* 8 (- 15 i))) node)))
          array))))
          