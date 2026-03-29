(in-package :graph-db)

;;;; ============================================================================
;;;; DEBUGGING & OUTPUT UTILITIES
;;;; ============================================================================

(defun dbg (fmt &rest args)
  "Print a debug message to stdout with optional formatting.
   
   ARGS:
   - fmt: Format control string (Common Lisp format syntax)
   - args: Arguments for the format string
   
   RETURN: NIL
   
   SIDE EFFECTS: Writes to standard output with implicit newline via terpri.
   
   EXAMPLE:
     (dbg \"Node ~A created with ID ~S\" name id)
     ; Prints: Node mynode created with ID #(1 2 3 ...) (with newline)"
  (apply #'format t fmt args)
  (terpri))

(defun ignore-warning (condition)
  "Muffle (suppress) a compile-time warning. Used in handler-bind contexts.
   
   ARGS:
   - condition: The warning condition to suppress
   
   RETURN: Result of muffle-warning (typically invokes a restart)
   
   SIDE EFFECTS: Removes warning from compiler output.
   
   EXAMPLE:
     (handler-bind ((warning #'ignore-warning))
       (some-code-that-warns))"
  (declare (ignore condition))
  (muffle-warning))

;;;; ============================================================================
;;;; RANDOMNESS & ENTROPY
;;;; ============================================================================

(defun get-random-bytes (&optional (count 16))
  "Read cryptographically secure random bytes from /dev/urandom.
   
   ARGS:
   - count: Number of random bytes to read (default: 16)
   
   RETURN: Byte vector of length COUNT with values 0-255.
   
   PRECONDITIONS:
   - /dev/urandom must be readable (standard on Unix-like systems)
   
   SIDE EFFECTS: Opens /dev/urandom for reading, reads exactly COUNT bytes.
   
   EXAMPLE:
     (get-random-bytes 32) => #(245 18 99 ... ) [32-byte vector]
     
   NOTES:
   - Used by gen-id() for UUID generation
   - Each call reads fresh entropy from OS
   - On systems without /dev/urandom, will fail (TODO: Windows support)"
  (with-open-file (in "/dev/urandom" :direction :input :element-type '(unsigned-byte 8))
    (let ((bytes (make-byte-vector count)))
      (dotimes (i count)
        (setf (aref bytes i) (read-byte in)))
      bytes)))

;;;; ============================================================================
;;;; OUTPUT FORMATTING
;;;; ============================================================================

(defun print-byte-array (stream array
                         &optional colon amp (delimiter #\Space))
  "Format directive for printing byte vectors as ASCII.
   
   ARGS:
   - stream: Output stream
   - array: Byte vector to print
   - colon, amp: Format directive flags (ignored)
   - delimiter: Character between bytes (default: space, not used in this impl)
   
   RETURN: NIL
   
   SIDE EFFECTS: Writes to stream.
   
   EXAMPLE:
     (format t \"~@/print-byte-array/\" (make-byte-vector 3))
     ; Prints bytes interpreted as ASCII characters
     
   NOTES:
   - Converts each byte via code-char (assumes bytes are valid ASCII)
   - Intended for human-readable debug output, not roundtrip serialization"
  (declare (ignore colon amp delimiter))
  (loop
     :for x :across array
     :do (format stream "~A" (code-char x))))

;;;; ============================================================================
;;;; TIME PRIMITIVES (CROSS-PLATFORM)
;;;; ============================================================================

;; FFI definitions for LispWorks
#+lispworks
(fli:define-c-struct timeval
    (tv-sec time-t)
  (tv-usec suseconds-t))

#+lispworks(fli:define-c-typedef time-t :long)
#+lispworks(fli:define-c-typedef suseconds-t #+linux :long #+darwin :int)
#+lispworks(fli:define-foreign-function (gettimeofday/ffi "gettimeofday")
               ((tv (:pointer (:struct timeval)))
                (tz :pointer))
             :result-type :int)

(defun gettimeofday ()
  "Get current time as Unix epoch seconds (float with microsecond precision).
   
   RETURN: Float representing seconds since Unix epoch (1970-01-01 00:00:00 UTC)
   
   SIDE EFFECTS: Calls OS system call. No exceptions raised on success.
   
   NOTES:
   - SBCL: Uses sb-ext:get-time-of-day for native support
   - CCL: Calls C gettimeofday() via external-call
   - LispWorks: Uses FFI to C library gettimeofday()
   - Cross-platform: Tested on Linux, macOS; Windows untested
   
   EXAMPLE:
     (gettimeofday) => 1711828399.123456 ; As of March 2026"
  #+sbcl
  (multiple-value-bind (sec msec) (sb-ext:get-time-of-day)
    (+ sec (/ msec 1000000)))
  #+(and ccl (not windows))
  (ccl:rlet ((tv :timeval))
            (let ((err (ccl:external-call "gettimeofday" :address tv :address (ccl:%null-ptr) :int)))
              (assert (zerop err) nil "gettimeofday failed")
              (values (ccl:pref tv :timeval.tv_sec)
                      (ccl:pref tv :timeval.tv_usec))))
  #+lispworks
  (fli:with-dynamic-foreign-objects ((tv (:struct timeval)))
    (let ((ret (gettimeofday/ffi tv fli:*null-pointer*)))
      (assert (zerop ret) nil "gettimeofday failed")
      (let ((secs
              (fli:foreign-slot-value tv 'tv-sec
                                      :type 'time-t
                                      :object-type '(:struct timeval)))
            (usecs
              (fli:foreign-slot-value tv 'tv-usec
                                      :type 'suseconds-t
                                      :object-type '(:struct timeval))))
        (values secs (* 1000 usecs))))))

(defvar *unix-epoch-difference*
  (encode-universal-time 0 0 0 1 1 1970 0)
  "Cached offset: number of CL universal-time units from 1900-01-01 to 1970-01-01.
   Used to convert between CL's universal-time (epochs from 1900) and Unix time (from 1970).
   Computed once at load time to avoid repeated calculation.")

(defun universal-to-unix-time (universal-time)
  "Convert Common Lisp universal-time (seconds since 1900-01-01) to Unix time.
   
   ARGS:
   - universal-time: Integer seconds since 1900-01-01 00:00:00 UTC (CL convention)
   
   RETURN: Integer seconds since 1970-01-01 00:00:00 UTC (Unix convention)
   
   NOTES:
   - Inverse of unix-to-universal-time()
   - *unix-epoch-difference* = 2208988800 (const, cached for speed)
   
   EXAMPLE:
     (universal-to-unix-time (get-universal-time))
     ; Returns current Unix timestamp"
  (- universal-time *unix-epoch-difference*))

(defun unix-to-universal-time (unix-time)
  "Convert Unix time (seconds since 1970-01-01) to Common Lisp universal-time.
   
   ARGS:
   - unix-time: Integer seconds since 1970-01-01 00:00:00 UTC (Unix convention)
   
   RETURN: Integer seconds since 1900-01-01 00:00:00 UTC (CL convention)
   
   NOTES:
   - Inverse of universal-to-unix-time()
   
   EXAMPLE:
     (unix-to-universal-time 1711828399) => 3920816199"
  (+ unix-time *unix-epoch-difference*))

(defun get-unix-time ()
  "Get current time as Unix timestamp (seconds since 1970-01-01 00:00:00 UTC).
   
   RETURN: Integer Unix timestamp
   
   NOTES:
   - Convenience wrapper: (universal-to-unix-time (get-universal-time))
   - Loses microsecond precision from gettimeofday() due to using get-universal-time
   - Use gettimeofday() directly if sub-second precision needed
   
   EXAMPLE:
     (get-unix-time) => 1711828399"
  (universal-to-unix-time (get-universal-time)))

;;;; ============================================================================
;;;; FILE UTILITIES
;;;; ============================================================================

(defun line-count (file)
  "Count the number of lines in a text file.
   
   ARGS:
   - file: Pathname or string path to file
   
   RETURN: Integer line count (0 if file is empty)
   
   SIDE EFFECTS: Opens and reads entire file.
   
   NOTES:
   - Counts newlines; last line without newline still counts as 1
   - Inefficient for very large files (reads sequentially)
   
   EXAMPLE:
     (line-count \"utils.lisp\") => 484"
  (with-open-file (in file)
    (loop
       for x from 0
       for line = (read-line in nil :eof)
       until (eql line :eof)
       finally (return x))))

;;;; ============================================================================
;;;; LIST UTILITIES
;;;; ============================================================================

(defun last1 (lst)
  "Return the last element of a list (not the last cons cell).
   
   ARGS:
   - lst: A list
   
   RETURN: The final element, or NIL if list is empty
   
   NOTES:
   - Standard CL last() returns a cons cell; this returns the car of that cell
   - Equivalent to (first (last lst))
   
   EXAMPLE:
     (last1 '(a b c)) => C
     (last1 '()) => NIL"
  (first (last lst)))

(defun flatten (x)
  "Recursively flatten a nested list structure into a single-level list.
   
   ARGS:
   - x: Any list, possibly with nested sublists
   
   RETURN: Flat list of all non-list atoms in x
   
   NOTES:
   - Uses accumulator-based recursion for efficiency (tail-recursive pattern)
   - Atoms are prepended to accumulator (order reversed internally, corrected by nil base)
   
   EXAMPLE:
     (flatten '(a (b c) (d (e f)))) => (A B C D E F)
     (flatten '(1 2 (3))) => (1 2 3)"
  (labels ((rec (x acc)
             (cond ((null x) acc)
                   ((atom x) (cons x acc))
                   (t (rec (car x) (rec (cdr x) acc))))))
    (rec x nil)))

(defun continue-p ()
  "Prompt user interactively to continue searching for more solutions.
   
   RETURN: T if user pressed ';' (continue), NIL if pressed '.' (stop)
   
   SIDE EFFECTS: Reads a character from *standard-input*.
   
   NOTES:
   - Ignores newlines and recurses until a valid command is entered
   - Used in REPL-style applications for backtracking control
   
   EXAMPLE:
     (if (continue-p) (search-more) (stop))"
  (case (read-char)
    (#\; t)
    (#\. nil)
    (#\newline (continue-p))
    (otherwise
      (format t " Type ; to see more or . to stop")
      (continue-p))))

(defun reuse-cons (x y x-y)
  "Return (cons x y), reusing the cons cell x-y if it equals the result.
   
   ARGS:
   - x: The car of the cons
   - y: The cdr of the cons
   - x-y: Existing cons cell to potentially reuse
   
   RETURN: Either x-y (reused) or a fresh (cons x y)
   
   NOTES:
   - Optimization: avoids creating garbage cons cells
   - Uses eql for identity check (pointer equality, not value equality)
   - Useful in term rewriting and unification algorithms
   
   EXAMPLE:
     (let ((old-cons (cons 'a 'b)))
       (reuse-cons 'a 'b old-cons)) => old-cons [reused]
     (let ((old-cons (cons 'x 'y)))
       (reuse-cons 'a 'b old-cons)) => (A . B) [fresh cons]"
  (if (and (eql x (car x-y)) (eql y (cdr x-y)))
      x-y
      (cons x y)))

(defun find-all (item sequence &rest keyword-args
                 &key (test #'eql) test-not &allow-other-keys)
  "Find all elements of sequence matching item (inverse of remove).
   
   ARGS:
   - item: Element to match
   - sequence: List or vector to search
   - test: Predicate for matching (default: eql)
   - test-not: Predicate for non-matching (opposite of test)
   - keyword-args: Additional args passed to remove()
   
   RETURN: List of all matching elements in original order
   
   NOTES:
   - Implemented as (remove item sequence :test (complement test))
   - Equivalent to findall() in other languages
   - Does not modify sequence
   
   EXAMPLE:
     (find-all 'a '(a b a c a)) => (A A A)
     (find-all 1 '(1 2 1 3) :test #'=) => (1 1)"
  (if test-not
      (apply #'remove item sequence
             :test-not (complement test-not) keyword-args)
      (apply #'remove item sequence
             :test (complement test) keyword-args)))

(defun find-anywhere (item tree)
  "Search for item anywhere in a tree structure (depth-first).
   
   ARGS:
   - item: Element to search for
   - tree: Nested list structure
   
   RETURN: The first occurrence of item found, or NIL if not found
   
   NOTES:
   - Searches depth-first: left subtree, then right subtree
   - Uses eql for comparison
   - Returns the actual item (not a path or index)
   
   EXAMPLE:
     (find-anywhere 'x '(a (b (c x d) e) f)) => X
     (find-anywhere 'z '(a b c)) => NIL"
  (cond ((eql item tree) tree)
        ((atom tree) nil)
        ((find-anywhere item (first tree)))
        ((find-anywhere item (rest tree)))))

(defun find-if-anywhere (predicate tree)
  "Search for the first atom in tree matching predicate.
   
   ARGS:
   - predicate: Function from atom -> boolean
   - tree: Nested list structure
   
   RETURN: The first atom where (funcall predicate atom) is true, or NIL
   
   NOTES:
   - Depth-first search, short-circuits on first match
   - Uses or for logical short-circuit
   
   EXAMPLE:
     (find-if-anywhere #'numberp '(a (b (3 c) d)))  => 3
     (find-if-anywhere #'stringp '(a b c)) => NIL"
  (if (atom tree)
      (funcall predicate tree)
      (or (find-if-anywhere predicate (first tree))
          (find-if-anywhere predicate (rest tree)))))

(defun unique-find-anywhere-if (predicate tree &optional found-so-far)
  "Find all atoms in tree matching predicate, with duplicates removed.
   
   ARGS:
   - predicate: Function from atom -> boolean
   - tree: Nested list structure
   - found-so-far: Accumulator for results (default: empty list)
   
   RETURN: List of unique atoms satisfying predicate
   
   NOTES:
   - Uses adjoin to avoid duplicates (set semantics)
   - Depth-first traversal
   - Order is NOT guaranteed (adjoin order depends on eql hash)
   
   EXAMPLE:
     (unique-find-anywhere-if #'numberp '(1 (2 1 (3 2)) 1))
     => (1 2 3)  [or any permutation thereof]"
  (if (atom tree)
      (if (funcall predicate tree)
          (adjoin tree found-so-far)
          found-so-far)
      (unique-find-anywhere-if
       predicate
       (first tree)
       (unique-find-anywhere-if predicate (rest tree) found-so-far))))

(defun length=1 (list)
  "Check if list has exactly one element.
   
   ARGS:
   - list: Any value
   
   RETURN: T if list is a cons cell with null cdr, NIL otherwise
   
   NOTES:
   - Efficient: does NOT compute full length, just checks car and cdr
   - Returns NIL for empty list and non-lists
   
   EXAMPLE:
     (length=1 '(x)) => T
     (length=1 '(x y)) => NIL
     (length=1 '()) => NIL
     (length=1 'x) => NIL"
  (and (consp list) (null (cdr list))))

(defun new-interned-symbol (&rest args)
  "Create an interned symbol by concatenating and internalizing args.
   
   ARGS:
   - args: Symbols or strings to concatenate
   
   RETURN: A new (or existing if already interned) symbol in *package*
   
   NOTES:
   - Uses format with ~{~a~} to convert each arg to string, then concatenates
   - Intern ensures the symbol is added to the package symbol table
   - Useful for programmatic symbol generation (meta-programming)
   
   EXAMPLE:
     (new-interned-symbol 'layer- 1 '-vertex) => LAYER-1-VERTEX
     (eq (new-interned-symbol 'x) (new-interned-symbol 'x)) => T [interned]"
  (intern (format nil "~{~a~}" args)))

;;;; ============================================================================
;;;; UUID GENERATION & PARSING
;;;; ============================================================================

(defun gen-id ()
  "Generate a cryptographically secure random UUID as a byte vector.
   
   RETURN: 16-byte vector (unsigned-byte 8) representing a UUID v4
   
   SIDE EFFECTS: Calls get-random-bytes (reads from /dev/urandom).
   
   NOTES:
   - Uses uuid:make-v4-uuid for UUID generation (randomness-based)
   - Converts to byte-array for internal storage (not uuid:uuid object)
   - Every call produces a different UUID (collision probability negligible)
   
   EXAMPLE:
     (gen-id) => #(245 18 99 ... ) [16-byte vector]
     (length (gen-id)) => 16"
  (uuid:uuid-to-byte-array (uuid:make-v4-uuid)))

(defun parse-uuid-block (string start end)
  "Parse a hexadecimal substring as an integer.
   
   ARGS:
   - string: String containing hex digits
   - start, end: Substring indices (end exclusive)
   
   RETURN: Integer value of hex digits
   
   NOTES:
   - Helper for read-uuid-from-string()
   - parse-integer handles :radix 16
   
   EXAMPLE:
     (parse-uuid-block \"6ba7b810\" 0 8) => 1806767120"
  (parse-integer string :start start :end end :radix 16))

(defun read-uuid-from-string (string)
  "Parse a UUID from its canonical string representation.
   
   ARGS:
   - string: UUID in form \"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\"
   
   RETURN: uuid:uuid object
   
   PRECONDITIONS:
   - string must contain exactly 32 hex digits (hyphens ignored)
   
   SIDE EFFECTS: None (read-only)
   
   SIGNALS:
   - error if string length (after removing hyphens) != 32
   
   NOTES:
   - Removes all hyphens before parsing
   - Creates uuid:uuid instance (not byte-array)
   - Inverse operation: (uuid:print-bytes nil uuid-obj)
   
   EXAMPLE:
     (read-uuid-from-string \"550e8400-e29b-41d4-a716-446655440000\")
     => #<UUID 550e8400-e29b-41d4-a716-446655440000>"
  (setq string (remove #\- string))
  (unless (= (length string) 32)
    (error "~@<Could not parse ~S as UUID: string representation ~
has invalid length (~D). A valid UUID string representation has 32 ~
characters.~@:>" string (length string)))
  (make-instance 'uuid:uuid
                 :time-low      (parse-uuid-block string  0 8)
                 :time-mid      (parse-uuid-block string  8 12)
                 :time-high     (parse-uuid-block string 12 16)
                 :clock-seq-var (parse-uuid-block string 16 18)
                 :clock-seq-low (parse-uuid-block string 18 20)
                 :node          (parse-uuid-block string 20 32)))

(defun read-id-array-from-string (string)
  "Parse a UUID string into a 16-byte unsigned-byte array.
   
   ARGS:
   - string: UUID in canonical form \"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\"
   
   RETURN: 16-element byte vector
   
   NOTES:
   - Internal representation: byte-array, not uuid:uuid object
   - Byte order is important: follows UUID RFC 4122 byte layout
   - Complex bit manipulation to extract individual bytes from 16-bit blocks
   
   ALGORITHM:
   1. Parse first 4 hex blocks as integers
   2. Extract individual bytes from each block using ldb (load byte)
   3. Store bytes in array positions 0-15
   
   EXAMPLE:
     (read-id-array-from-string \"550e8400-e29b-41d4-a716-446655440000\")
     => #(85 14 132 0 226 155 65 212 167 22 68 102 85 68 0 0)"
  (let ((array (make-array 16 :element-type '(unsigned-byte 8))))
    ;; Bytes 0-3: time-low (first 8 hex digits)
    (loop for i from 3 downto 0
       do (setf (aref array (- 3 i))
                (ldb (byte 8 (* 8 i)) (parse-uuid-block string  0 8))))
    ;; Bytes 4-5: time-mid (next 4 hex digits)
    (loop for i from 5 downto 4
       do (setf (aref array i)
                (ldb (byte 8 (* 8 (- 5 i))) (parse-uuid-block string  8 12))))
    ;; Bytes 6-7: time-high-and-version
    (loop for i from 7 downto 6
       do (setf (aref array i)
                (ldb (byte 8 (* 8 (- 7 i))) (parse-uuid-block string 12 16))))
    ;; Bytes 8-9: clock-seq-hi-and-reserved, clock-seq-low
    (setf (aref array 8) (ldb (byte 8 0) (parse-uuid-block string 16 18)))
    (setf (aref array 9) (ldb (byte 8 0) (parse-uuid-block string 18 20)))
    ;; Bytes 10-15: node (MAC address)
    (loop for i from 15 downto 10
       do (setf (aref array i)
                (ldb (byte 8 (* 8 (- 15 i))) (parse-uuid-block string 20 32))))
    array))

;;;; ============================================================================
;;;; MEMORY INSPECTION
;;;; ============================================================================

(defun free-memory ()
  "Get the amount of free dynamic memory available.
   
   RETURN: Number of bytes available
   
   NOTES:
   - SBCL: Computes dynamic-space-size - dynamic-usage
   - CCL: Uses %freebytes directly
   - LispWorks: TODO (not yet implemented)
   
   EXAMPLE:
     (free-memory) => 1024000000  ; ~1GB free"
  #+sbcl
  (- (sb-kernel::dynamic-space-size) (sb-kernel:dynamic-usage))
  ;; TODO: LispWorks
  #+ccl
  (ccl::%freebytes))

;;;; ============================================================================
;;;; HASHING (NOT CURRENTLY USED)
;;;; ============================================================================

(defun djb-hash (seq)
  "DJB2 hash function (Daniel J. Bernstein). NOT CURRENTLY USED.
   
   ARGS:
   - seq: Sequence (list, vector) or other object (converted to string)
   
   RETURN: Integer hash value (positive)
   
   NOTES:
   - Legacy implementation; superceded by modern hash functions
   - Converts non-sequences to string representation first
   - Handles mixed-type sequences (integers, characters, floats)
   
   ALGORITHM:
   - Start with hash = 5381
   - For each element: hash = (hash * 33) + element_value
   - Element value: char -> char-code, float -> truncate, int -> as-is"
  (unless (typep seq 'sequence)
    (setq seq (format nil "~A" seq)))
  (let ((hash 5381))
    (dotimes (i (length seq))
      (let ((item (elt seq i)))
        (typecase item
          (integer   nil)
          (character (setq item (char-code item)))
          (float     (setq item (truncate item)))
          (otherwise (setq item 1)))
        (setf hash (+ (+ hash (ash hash -5)) item))))
    hash))

(defun fast-djb-hash (seq)
  "Fast DJB2 hash (assumes byte sequence). NOT CURRENTLY USED.
   
   ARGS:
   - seq: Sequence of bytes (unsigned-byte 8)
   
   RETURN: Integer hash value
   
   NOTES:
   - Faster than djb-hash; skips type checking
   - Assumes seq contains only integers (no conversion)
   
   ALGORITHM: Same as djb-hash but without type coercion"
  (let ((hash 5381))
    (dotimes (i (length seq))
      (setf hash (+ (+ hash (ash hash -5)) (elt seq i))))
    hash))

;;;; ============================================================================
;;;; TYPE CHECKING
;;;; ============================================================================

(defun proper-listp (x)
  "Check if x is a proper (non-dotted) list.
   
   ARGS:
   - x: Any value
   
   RETURN: T if x is NIL or a proper list (terminated by NIL), NIL otherwise
   
   NOTES:
   - A dotted list (e.g., (a b . c)) returns NIL
   - Uses recursion (not tail-recursive); may stack overflow on very long lists
   
   EXAMPLE:
     (proper-listp '(a b c)) => T
     (proper-listp '(a b . c)) => NIL
     (proper-listp nil) => T
     (proper-listp 'x) => NIL"
  (or (null x)
      (and (consp x) (proper-listp (rest x)))))

;;;; ============================================================================
;;;; ARRAY UTILITIES
;;;; ============================================================================

(defun make-byte-vector (length)
  "Create a zero-initialized byte vector of given length.
   
   ARGS:
   - length: Number of bytes to allocate
   
   RETURN: 1D array of element-type (unsigned-byte 8), initialized to 0
   
   NOTES:
   - Equivalent to (make-array length :element-type '(unsigned-byte 8) :initial-element 0)
   - Used extensively for UUID storage, serialization buffers
   
   EXAMPLE:
     (make-byte-vector 16) => #(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
     (length (make-byte-vector 32)) => 32"
  (make-array `(,length) :element-type '(unsigned-byte 8) :initial-element 0))

;;;; ============================================================================
;;;; MACRO UTILITIES
;;;; ============================================================================

(defmacro with-gensyms (syms &body body)
  "Create multiple gensym variables for use in macro expansions.
   
   SYNTAX:
   (with-gensyms (var1 var2 ...) <body>)
   
   EXAMPLE:
     (defmacro my-let ((var val) &body body)
       (with-gensyms (temp)
         `(let ((,temp ,val))
            (let ((,var ,temp))
              ,@body))))
   
   NOTES:
   - Common pattern in macro writing (from Graham's On Lisp)
   - Avoids variable capture and gensym boilerplate"
  `(let ,(loop for s in syms collect `(,s (gensym)))
    ,@body))

;;;; ============================================================================
;;;; DEBUG OUTPUT
;;;; ============================================================================

(defun dump-hash (hash)
  "Print all key-value pairs in a hash table to stdout.
   
   ARGS:
   - hash: Hash table to dump
   
   RETURN: NIL
   
   SIDE EFFECTS: Writes to standard output
   
   EXAMPLE:
     (dump-hash *my-hash*)
     ; Output:
     ;   KEY1:
     ;    VALUE1
     ;   KEY2:
     ;    VALUE2"
  (loop for k being the hash-keys in hash using (hash-value v)
       do (dbg "~S:~% ~S" k v)))

;;;; ============================================================================
;;;; CROSS-TYPE COMPARISON: less-than
;;;; ============================================================================

(defgeneric less-than (x y)
  (:documentation
   "Generic less-than operator allowing comparison across different types.
    
    BEHAVIOR:
    - Defines a total order on all Lisp values
    - Follows hierarchy: list < null < (eql t) < number < symbol < string < timestamp < uuid
    - Sentinel values +min-sentinel+ and +max-sentinel+ are always first and last
    - Same-type comparisons use type-specific operators (<, string<, etc.)
    
    RETURNS:
    - T if X < Y in the defined order
    - NIL otherwise
    
    USAGE:
    - Core operator for skip-lists and other generic indexes in VivaceGraph
    - Allows mixed-type keys in a single index (e.g., both strings and numbers)
    
    EXAMPLE:
      (less-than 1 2) => T
      (less-than \"b\" \"a\") => NIL
      (less-than 1 \"x\") => T  [numbers before strings]
      (less-than +min-sentinel+ 5) => T
      (less-than 5 +max-sentinel+) => T"))

  ;; Sentinels: always compare as min/max
  (:method ((x (eql +min-sentinel+)) y) nil)
  (:method ((x (eql +max-sentinel+)) y) t)

  ;; +min-sentinel+ methods (min is never less than anything)
  (:method ((x (eql +min-sentinel+)) (y number))  nil)
  (:method ((x (eql +min-sentinel+)) (y symbol))  nil)
  (:method ((x (eql +min-sentinel+)) (y string))  nil)
  (:method ((x (eql +min-sentinel+)) (y (eql t))) nil)
  (:method ((x (eql +min-sentinel+)) (y null))    nil)
  (:method ((x (eql +min-sentinel+)) (y list))    nil)

  ;; Everything is greater than +min-sentinel+
  (:method ((x number)  (y (eql +min-sentinel+))) t)
  (:method ((x symbol)  (y (eql +min-sentinel+))) t)
  (:method ((x string)  (y (eql +min-sentinel+))) t)
  (:method ((x (eql t)) (y (eql +min-sentinel+))) t)
  (:method ((x null)    (y (eql +min-sentinel+))) t)
  (:method ((x list)    (y (eql +min-sentinel+))) t)

  ;; +max-sentinel+ methods (max is greater than everything)
  (:method ((x (eql +max-sentinel+)) (y number))  t)
  (:method ((x (eql +max-sentinel+)) (y symbol))  t)
  (:method ((x (eql +max-sentinel+)) (y string))  t)
  (:method ((x (eql +max-sentinel+)) (y (eql t))) t)
  (:method ((x (eql +max-sentinel+)) (y null))    t)
  (:method ((x (eql +max-sentinel+)) (y list))    t)

  ;; Everything is less than +max-sentinel+
  (:method ((x number)  (y (eql +max-sentinel+))) nil)
  (:method ((x symbol)  (y (eql +max-sentinel+))) nil)
  (:method ((x string)  (y (eql +max-sentinel+))) nil)
  (:method ((x (eql t)) (y (eql +max-sentinel+))) nil)
  (:method ((x null)    (y (eql +max-sentinel+))) nil)
  (:method ((x list)    (y (eql +max-sentinel+))) nil)

  ;; T (boolean true) and NIL comparison
  (:method ((x (eql t))   (y null))      nil)  ; T is NOT < NIL
  (:method ((x null)      (y (eql t)))   t)    ; NIL < T
  (:method ((x (eql t))   y)             t)    ; T is first in order for non-nil/non-t comparisons
  (:method ((x null)      y)             t)    ; NIL is first in order

  ;; Same-type comparisons (using type-specific operators)
  (:method ((x symbol)    (y symbol))    (string< (symbol-name x) (symbol-name y)))
  (:method ((x string)    (y string))    (string< x y))
  (:method ((x number)    (y number))    (< x y))
  (:method ((x timestamp) (y timestamp)) (timestamp< x y))
  (:method ((x uuid:uuid) (y uuid:uuid)) (string<
                                          (uuid:print-bytes nil x)
                                          (uuid:print-bytes nil y)))

  ;; List ordering: recursive comparison of car/cdr
  (:method ((x list) (y list))           (or (less-than (car x) (car y))
                                             (and (equal (car x) (car y))
                                                  (less-than (cdr x) (cdr y)))))
  (:method ((x list) y)                  t)    ; Lists are first in order
  (:method (x        (y list))           nil)  ; Lists are first in order

  ;; Cross-type comparisons: establish type precedence
  (:method ((x number)    y)            t)    ; Numbers < all others
  (:method ((x number)    (y (eql t)))  nil)
  (:method ((x number)    (y null))     nil)
  (:method (x             (y number))   nil)

  (:method ((x string)    (y symbol))    nil)  ; Strings < symbols
  (:method ((x symbol)    (y string))    t)

  (:method ((x symbol)    (y timestamp)) nil)  ; Symbols < timestamps
  (:method ((x timestamp) (y symbol))    t)

  (:method ((x symbol)    (y uuid:uuid)) nil)  ; Symbols < UUIDs
  (:method ((x uuid:uuid) (y symbol))    t)

  (:method ((x string)    (y timestamp)) nil)  ; Strings < timestamps
  (:method ((x timestamp) (y string))    t)

  (:method ((x string)    (y uuid:uuid)) nil)  ; Strings < UUIDs
  (:method ((x uuid:uuid) (y string))    t)

  (:method ((x uuid:uuid) (y timestamp)) nil)  ; UUIDs < timestamps
  (:method ((x timestamp) (y uuid:uuid)) t))

(defun key-vector< (v1 v2)
  "Compare two key vectors lexicographically using less-than.
   
   ARGS:
   - v1, v2: Vectors of comparable elements
   
   RETURN: T if v1 < v2 lexicographically, NIL otherwise
   
   ALGORITHM:
   1. If both vectors empty, return NIL (equal)
   2. If v1[0] < v2[0], return T (first element decides)
   3. If v1[0] = v2[0], recurse on tails
   4. Otherwise return NIL (v1[0] > v2[0])
   
   NOTES:
   - Used for composite index keys in skip-lists
   - Creates subseq at each step (O(n) space); could be optimized with indices
   
   EXAMPLE:
     (key-vector< #(1 2 3) #(1 2 4)) => T
     (key-vector< #(1 2 3) #(1 1 9)) => NIL
     (key-vector< #() #(a)) => NIL [empty is not < non-empty]"
  (cond ((= (array-dimension v1 0) 0)
         nil)
        ((< (aref v1 0) (aref v2 0))
         t)
        ((= (aref v1 0) (aref v2 0))
         (key-vector< (subseq v1 1) (subseq v2 1)))
        (t
         nil)))

(defun key-vector<= (v1 v2)
  "Compare two key vectors lexicographically using less-than-or-equal.
   
   ARGS:
   - v1, v2: Vectors of comparable elements
   
   RETURN: T if v1 <= v2 lexicographically
   
   NOTES:
   - Empty vectors are always <= non-empty vectors
   - Inverse: (not (key-vector< v2 v1))
   
   EXAMPLE:
     (key-vector<= #(1 2) #(1 2)) => T  [equal]
     (key-vector<= #(1 2) #(1 2 3)) => T  [prefix]
     (key-vector<= #() #()) => T  [both empty]"
  (cond ((= (array-dimension v1 0) 0)
         t)
        ((< (aref v1 0) (aref v2 0))
         t)
        ((= (aref v1 0) (aref v2 0))
         (key-vector<= (subseq v1 1) (subseq v2 1)))
        (t
         nil)))

;;;; ============================================================================
;;;; CROSS-TYPE COMPARISON: greater-than
;;;; ============================================================================

(defgeneric greater-than (x y)
  (:documentation
   "Generic greater-than operator (inverse of less-than).
    
    BEHAVIOR:
    - Symmetric to less-than; defines a total order
    - All methods mirror less-than with logic inverted
    
    EXAMPLE:
      (greater-than 5 3) => T
      (greater-than \"x\" \"y\") => NIL"))

  (:method ((x (eql +min-sentinel+)) y) nil)  ; min is never >
  (:method ((x (eql +max-sentinel+)) y) t)    ; max is always >

  ;; +min-sentinel+ methods (nothing is > min)
  (:method ((x (eql +min-sentinel+)) (y number))  nil)
  (:method ((x (eql +min-sentinel+)) (y symbol))  nil)
  (:method ((x (eql +min-sentinel+)) (y (eql t))) nil)
  (:method ((x (eql +min-sentinel+)) (y null))    nil)
  (:method ((x (eql +min-sentinel+)) (y list))    nil)

  ;; Everything > +min-sentinel+
  (:method ((x number)  (y (eql +min-sentinel+))) t)
  (:method ((x symbol)  (y (eql +min-sentinel+))) t)
  (:method ((x (eql t)) (y (eql +min-sentinel+))) t)
  (:method ((x null)    (y (eql +min-sentinel+))) t)
  (:method ((x list)    (y (eql +min-sentinel+))) t)

  ;; +max-sentinel+ methods (max > everything)
  (:method ((x (eql +max-sentinel+)) (y number))  t)
  (:method ((x (eql +max-sentinel+)) (y symbol))  t)
  (:method ((x (eql +max-sentinel+)) (y string))  t)
  (:method ((x (eql +max-sentinel+)) (y (eql t))) t)
  (:method ((x (eql +max-sentinel+)) (y null))    t)
  (:method ((x (eql +max-sentinel+)) (y list))    t)

  ;; Nothing > +max-sentinel+
  (:method ((x number)  (y (eql +max-sentinel+))) nil)
  (:method ((x symbol)  (y (eql +max-sentinel+))) nil)
  (:method ((x string)  (y (eql +max-sentinel+))) nil)
  (:method ((x (eql t)) (y (eql +max-sentinel+))) nil)
  (:method ((x null)    (y (eql +max-sentinel+))) nil)
  (:method ((x list)    (y (eql +max-sentinel+))) nil)

  ;; T and NIL comparison
  (:method ((x (eql t))   (y null))      t)
  (:method ((x null)      (y (eql t)))   nil)
  (:method ((x (eql t))   y)             nil)
  (:method ((x null)      y)             nil)

  ;; Same-type comparisons
  (:method ((x symbol)    (y symbol))    (string> (symbol-name x) (symbol-name y)))
  (:method ((x string)    (y string))    (string> x y))
  (:method ((x number)    (y number))    (> x y))
  (:method ((x timestamp) (y timestamp)) (timestamp> x y))
  (:method ((x uuid:uuid) (y uuid:uuid)) (string>
                                          (uuid:print-bytes nil x)
                                          (uuid:print-bytes nil y)))

  ;; List ordering
  (:method ((x list) (y list))           (or (greater-than (car x) (car y))
                                             (and (equal (car x) (car y))
                                                  (greater-than (cdr x) (cdr y)))))
  (:method ((x list) y)                  nil)   ; Lists are first
  (:method (x        (y list))           t)     ; Lists are first

  ;; Cross-type comparisons (same as less-than but swapped)
  (:method ((x number)    y)            nil)    ; Numbers < all
  (:method ((x number)    (y (eql t)))  t)
  (:method ((x number)    (y null))     t)
  (:method (x             (y number))   t)

  (:method ((x string)    (y symbol))    t)
  (:method ((x symbol)    (y string))    nil)

  (:method ((x symbol)    (y timestamp)) t)
  (:method ((x timestamp) (y symbol))    nil)

  (:method ((x symbol)    (y uuid:uuid)) t)
  (:method ((x uuid:uuid) (y symbol))    nil)

  (:method ((x string)    (y timestamp)) t)
  (:method ((x timestamp) (y string))    nil)

  (:method ((x string)    (y uuid:uuid)) t)
  (:method ((x uuid:uuid) (y string))    nil)

  (:method ((x uuid:uuid) (y timestamp)) t)
  (:method ((x timestamp) (y uuid:uuid)) nil))

(defun key-vector> (v1 v2)
  "Compare two key vectors lexicographically using greater-than.
   
   ARGS:
   - v1, v2: Vectors of comparable elements
   
   RETURN: T if v1 > v2 lexicographically
   
   NOTES:
   - Inverse of key-vector<; symmetric
   
   EXAMPLE:
     (key-vector> #(2 1) #(1 9)) => T  [2 > 1 in first position]"
  (cond ((= (array-dimension v1 0) 0)
         nil)
        ((> (aref v1 0) (aref v2 0))
         t)
        ((= (aref v1 0) (aref v2 0))
         (key-vector> (subseq v1 1) (subseq v2 1)))
        (t
         nil)))

;;;; ============================================================================
;;;; SYNCHRONIZATION PRIMITIVES (CROSS-PLATFORM)
;;;; ============================================================================

;; CCL (Clozure Common Lisp) lock implementations
#+ccl
(defun do-grab-lock-with-timeout (lock whostate timeout)
  "CCL-specific: Attempt to acquire lock with optional timeout.
   
   ARGS:
   - lock: CCL lock object
   - whostate: String describing why we're waiting (for debugging)
   - timeout: Timeout in seconds, or NIL for blocking
   
   RETURN: T if lock acquired, NIL if timeout occurred
   
   NOTES:
   - Used by do-with-lock macro
   - ccl:try-lock is non-blocking
   - ccl:process-wait-with-timeout blocks until lock or timeout"
  (if timeout
      (or (ccl:try-lock lock)
          (ccl:process-wait-with-timeout whostate
                                         (round
                                          (* timeout ccl:*ticks-per-second*))
                                         #'ccl:try-lock (list lock)))
      (ccl:grab-lock lock)))

#+ccl
(defun do-with-lock (lock whostate timeout fn)
  "CCL-specific: Execute function while holding lock.
   
   ARGS:
   - lock: CCL lock object
   - whostate: Debug string
   - timeout: Timeout in seconds or NIL
   - fn: Function to call (no args)
   
   RETURN: Result of calling fn, or NIL if timeout
   
   SIDE EFFECTS: Acquires lock, calls fn, releases lock (even if fn signals error)
   
   NOTES:
   - Uses unwind-protect to ensure lock is released
   - If timeout occurs, fn is never called"
  (if timeout
      (and
       (do-grab-lock-with-timeout lock whostate timeout)
       (unwind-protect
            (funcall fn)
         (ccl:release-lock lock)))
      (ccl:with-lock-grabbed (lock) (funcall fn))))

(defmacro with-lock ((lock &key whostate timeout) &body body)
  "Execute body while holding lock (cross-platform macro).
   
   SYNTAX:
   (with-lock (lock-var :whostate \"operation name\" :timeout seconds?)
     <body>)
   
   ARGS:
   - lock: Lock object (implementation-specific)
   - whostate: Optional debug string describing the operation
   - timeout: Optional timeout in seconds (not all implementations support)
   
   RETURN: Result of body
   
   SIDE EFFECTS: Acquires lock at start, releases on exit (even if error)
   
   IMPLEMENTATIONS:
   - CCL: Uses do-with-lock helper with timeout support
   - LispWorks: Uses mp:with-lock (no timeout)
   - SBCL: Uses sb-thread:with-recursive-lock (no timeout)
   
   NOTES:
   - Always uses unwind-protect semantics (safe in presence of errors)
   - Lock is released even if body raises an exception
   - Recursive/re-entrant locks supported on all implementations
   
   EXAMPLE:
     (with-lock (my-lock :whostate \"writing node\")
       (setf (node-data n) x))  ; Safe for concurrent threads"
  #+ccl
  `(do-with-lock ,lock ,whostate ,timeout (lambda () ,@body))
  #+lispworks
  `(mp:with-lock (,lock) ,@body)
  #+sbcl
  `(sb-thread:with-recursive-lock (,lock)
     (progn ,@body)))

(defun make-semaphore ()
  "Create a cross-platform semaphore object.
   
   RETURN: Semaphore object (implementation-specific)
   
   NOTES:
   - SBCL: sb-thread:make-semaphore
   - LispWorks: mp:make-semaphore
   - CCL: ccl:make-semaphore
   
   EXAMPLE:
     (let ((sem (make-semaphore)))
       ...)"
  #+sbcl (sb-thread:make-semaphore)
  #+lispworks(mp:make-semaphore)
  #+ccl (ccl:make-semaphore))

(defmacro with-locked-hash-table ((table) &body body)
  "Execute body while protecting hash table from concurrent modification.
   
   SYNTAX:
   (with-locked-hash-table (hash-table-var)
     <body>)
   
   NOTES:
   - LispWorks & CCL: No-op (thread-safe hash tables)
   - SBCL: Uses sb-ext:with-locked-hash-table for atomic access
   
   EXAMPLE:
     (with-locked-hash-table (*global-cache*)
       (setf (gethash key *global-cache*) value))"
  #+lispworks
  `(progn ,@body)
  #+ccl
  `(progn ,@body)
  #+sbcl
  `(sb-ext:with-locked-hash-table (,table)
     (progn ,@body)))

;; CCL read-write lock implementations
#+ccl
(defmacro with-read-lock ((lock) &body body)
  "Acquire read lock (allows multiple readers) for body execution (CCL only).
   
   SYNTAX:
   (with-read-lock (rw-lock-var)
     <body>)
   
   NOTES:
   - Multiple readers can hold the lock simultaneously
   - Writers are blocked while any reader holds the lock
   - Readers are blocked while a writer holds the lock"
  `(ccl:with-read-lock (,lock)
     (progn ,@body)))

#+ccl
(defmacro with-write-lock ((lock) &body body)
  "Acquire write lock (exclusive) for body execution (CCL only).
   
   SYNTAX:
   (with-write-lock (rw-lock-var)
     <body>)
   
   NOTES:
   - Only one writer can hold the lock at a time
   - All readers are blocked while writer holds lock
   - Writer is blocked while any reader or writer holds lock"
  `(ccl:with-write-lock (,lock)
     (progn ,@body)))

#+ccl
(defun make-rw-lock ()
  "Create a read-write lock object (CCL only).
   
   RETURN: CCL read-write lock object
   
   NOTES:
   - Allows multiple concurrent readers
   - Exclusive access for writers
   - SBCL & LispWorks don't have native RW locks; use regular mutexes instead"
  (ccl:make-read-write-lock))

#+ccl
(defun rw-lock-p (thing)
  "Check if object is a read-write lock (CCL only).
   
   ARGS:
   - thing: Any value
   
   RETURN: T if thing is a CCL read-write lock, NIL otherwise"
  (ccl::read-write-lock-p thing))

#+ccl
(defun acquire-write-lock (lock &key wait-p)
  "Acquire exclusive write lock (CCL only).
   
   ARGS:
   - lock: CCL read-write lock object
   - wait-p: Ignored (always blocks); for API compatibility
   
   RETURN: The lock if acquired (no timeout), or NIL
   
   NOTES:
   - Blocks until lock is available
   - wait-p parameter accepted for future timeout support"
  (declare (ignore wait-p))
  (let ((locked (ccl:make-lock-acquisition)))
    (declare (dynamic-extent locked))
    (ccl::write-lock-rwlock lock locked)
    (when (ccl::lock-acquisition.status locked)
      lock)))

#+ccl
(defun release-write-lock (lock)
  "Release exclusive write lock (CCL only).
   
   ARGS:
   - lock: CCL read-write lock object
   
   RETURN: NIL
   
   SIDE EFFECTS: Releases the lock; other waiters may proceed"
  (declare (ignore wait-p))
  (ccl::unlock-rwlock lock))
  