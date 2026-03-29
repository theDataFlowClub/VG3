;;;; -*- Mode: Lisp; Package: :graph-db -*-
;;;;
;;;; $Header: /home/gene/library/website/docsrc/jmt/RCS/jmt.lisp,v 395.1 2008/04/20 17:25:47 gene Exp $
;;;;
;;;; Copyright (c) 2002, 2004 Jason Stover.  All rights reserved.
;;;;
;;;; This program is free software; you can redistribute it and/or modify
;;;; it under the terms of the GNU Lesser General Public License as
;;;; published by the Free Software Foundation; either version 2.1 of the
;;;; License, or (at your option) any later version.
;;;; 
;;;; This program is distributed in the hope that it will be useful, but
;;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;;;; General Public License for more details.
;;;; 
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this program; if not, write to the Free Software
;;;; Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
;;;; USA

;;;;
;;;; MERSENNE TWISTER PSEUDO-RANDOM NUMBER GENERATOR
;;;;
;;;; Purpose:
;;;;   Implement the MT19937 Mersenne Twister PRNG algorithm for
;;;;   high-quality random number generation suitable for simulations,
;;;;   Monte Carlo methods, and non-cryptographic applications.
;;;;
;;;; Algorithm Reference:
;;;;   "Mersenne Twister: A 623-dimensionally equidistributed uniform
;;;;    pseudorandom number generator", ACM Transactions on Modeling and
;;;;    Computer Simulation vol. 8, no. 1, January 1998, pp 3-30.
;;;;   See: www.math.keio.ac.jp/~matumoto/emt.html
;;;;
;;;; Authors:
;;;;   Jason Stover (2002-2004) — Original Lisp implementation
;;;;   Gene Michael Stover — Rewrite & testing (Feb 2004)
;;;;   VivaceGraph adaptation — Package fix & documentation (Apr 2026)
;;;;
;;;; Key Properties:
;;;;   - Period: 2^19937 - 1 (extremely long)
;;;;   - Equidistribution: 623-dimensional
;;;;   - Fast: No trigonometric functions, bit operations only
;;;;   - Quality: Passes Diehard tests, suitable for scientific computing
;;;;   - Non-cryptographic: Do NOT use for security-sensitive applications
;;;;
;;;; IMPORTANT LIMITATION:
;;;;   This implementation is NOT thread-safe. Global *mt-random-state*
;;;;   is modified without synchronization. For multi-threaded code:
;;;;   - Use thread-local random states, OR
;;;;   - Protect with locks, OR
;;;;   - Use different library for thread-safe PRNG

(in-package #:graph-db)

;;;; ============================================================================
;;;; CONSTANTS: Mersenne Twister Parameters
;;;; ============================================================================

(defconstant *mt-k2^32* (expt 2 32)
  "2^32 — Used for modulo arithmetic in 32-bit operations.
   
   PURPOSE: Keeps all intermediate values in 32-bit range.
   
   Mathematical: 2^32 = 4,294,967,296
   
   Used in: mod operations, inverse calculation")

(defconstant *mt-k-inverse-2^32f* (expt 2.0 -32.0)
  "1/(2^32) as floating-point number ≈ 2.328e-10.
   
   PURPOSE: Convert 32-bit unsigned integer to [0.0, 1.0) float.
   
   Formula: (mt-genrand) * *mt-k-inverse-2^32f* ∈ [0.0, 1.0)
   
   Used in: mt-random for float output")

(defconstant *mt-n* 624
  "State array size (Mersenne exponent related).
   
   PURPOSE: Define size of internal state vector.
   
   Properties:
   - Related to Mersenne prime 2^19937 - 1
   - 624 consecutive generated numbers form one period cycle
   - After 624 calls to mt-genrand, state must be regenerated
   
   Invariant: Cannot be changed without breaking the algorithm")

(defconstant *mt-m* 397
  "Offset for feedback in state regeneration algorithm.
   
   PURPOSE: Define shift distance in twist transformation.
   
   Relationship: 624 - 397 = 227
   - Loop 1 uses offset +397
   - Loop 2 uses offset -227 (wrap-around)
   
   Invariant: Cannot be changed without breaking the algorithm")

(defconstant *mt-upper-mask* #x80000000
  "Most significant bit mask (10000000... in binary).
   
   PURPOSE: Extract upper bit of 32-bit word.
   
   Hex: #x80000000 = binary 10000000000000000000000000000000
   
   Used in: mt-refill to separate high bit from rest")

(defconstant *mt-lower-mask* #x7FFFFFFF
  "Lower 31 bits mask (01111111... in binary).
   
   PURPOSE: Extract lower 31 bits of 32-bit word.
   
   Hex: #x7FFFFFFF = binary 01111111111111111111111111111111
   
   Used in: mt-refill to separate lower bits from rest")

;;;; ============================================================================
;;;; DATA STRUCTURE: MT Random State
;;;; ============================================================================

(defstruct (mt-random-state
            (:constructor mt-internal-make-random-state
                          (&key mti arr)))
  
  "Mersenne Twister internal state structure.
   
   FIELDS:
   
   MTI — Index into state array (0 to 624)
         Tracks position within current batch of 624 numbers.
         When MTI >= 624, state must be regenerated via mt-refill.
         Initially set to 624 (forces refill on first call).
   
   ARR — 624-element array of 32-bit unsigned integers
         Contains the internal state vector.
         Updated during initialization and every 624 calls.
         Each element: [0, 2^32)
   
   SIZE: Approximately 2,500 bytes per state
         (8 bytes index + 624 * 4 bytes array)
   
   USAGE:
   Users should NOT modify MTI or ARR directly.
   Always use public API (make-mt-random-state, mt-random).
   
   WHY THIS DESIGN:
   - Matches C reference implementation (mt19937int.c)
   - Alternative: Could use fill-pointer on ARR instead of MTI
   - Current design chosen for clarity and reference compatibility"
  
  (mti 624 :type integer)
  (arr nil :type (or null (array integer (*)))))

;;;; ============================================================================
;;;; STATE INITIALIZATION
;;;; ============================================================================

(labels
    ;; HELPER FUNCTIONS (for mt-make-random-state-integer only)
    
    ((next-seed (n)
       "Expand seed using linear congruential generator.
        
        FORMULA: (n * 69069 + 1) mod 2^32
        
        Purpose: Spread single seed to multiple values
        
        Multiplier 69069: Chosen for good equidistribution
        Addend 1: Ensures coprimality
        
        Returns: Next value in LCG sequence"
       (mod (1+ (* 69069 n)) *mt-k2^32*))
    
    (get-hi16 (n)
       "Extract high 16 bits of 32-bit word.
        
        Mask: #xFFFF0000 (binary 11111111111111110000000000000000)
        
        Purpose: Keep only upper half of 32-bit value
        
        Returns: 16 high bits, rest zeroed"
       (logand n #xFFFF0000))
    
    (next-elt (n)
       "Combine high 16 bits of n with high 16 bits of next LCG value.
        
        ALGORITHM:
        1. Take high 16 bits of current value: (get-hi16 n)
        2. Generate next LCG value: (next-seed n)
        3. Take high 16 bits of next value
        4. Shift right 16 positions (move to low position)
        5. Combine with OR
        
        Returns: 32-bit integer combining both halves"
       (logior (get-hi16 n)
               (ash (get-hi16 (next-seed n)) -16))))
  
  (defun mt-make-random-state-integer (n)
    "INTERNAL: Create MT state from single integer seed.
     
     PARAMETERS:
     n — Integer seed (any size, including bignum)
    
    PURPOSE:
    Expand a single seed value into the full 624-element state vector.
    This ensures that different seeds produce completely different sequences.
    
    ALGORITHM:
    1. Initialize LCG from seed n
    2. Generate 624 values using LCG: next = (69069 * current + 1) mod 2^32
    3. For each value, combine high 16 bits with high 16 bits of next value
    4. Place into state array
    
    WHY THIS APPROACH:
    - Single integer seed can be arbitrarily large (bignum)
    - LCG is fast and spreads seed across all state values
    - Combining high-bits ensures full 32-bit randomness
    - Based on 'sgenrand' function from mt19937int.c
    
    RETURNS: Initialized mt-random-state structure
    
    NOTE: Mostly internal function. Users should call make-mt-random-state."
    (mt-internal-make-random-state
     :mti *mt-n*                      ; Force refill on first call
     :arr (make-array                 ; Create state array
           *mt-n*
           :element-type 'integer
           :initial-contents
           (do ((i 0 (1+ i))           ; Loop counter
                (sd n                  ; Current LCG state
                    (next-seed (next-seed sd)))
                (lst () (cons (next-elt sd) lst)))
               ((>= i *mt-n*)          ; Stop after 624 values
                (nreverse lst)))))))   ; Reverse list to correct order

(defvar *mt-random-state* nil
  "Global default random state for mt-random calls.
   
   TYPE: mt-random-state or NIL
   
   PURPOSE: Provides default state when mt-random called without explicit state.
   
   INITIALIZATION: Set to new random state at load time (line 147).
   
   IMPORTANT LIMITATION: NOT THREAD-SAFE
   - Multiple threads calling mt-random will corrupt this state
   - All threads share same global state
   - No locking or synchronization
   
   FOR MULTI-THREADED CODE:
   - Create separate state per thread, OR
   - Protect with locks, OR
   - Use thread-local storage binding
   
   USAGE:
   (setq *mt-random-state* (make-mt-random-state t))  ; Reseed globally
   (mt-random 100)                                     ; Uses global state")

(let ((some-number 0))
  (defun mt-make-random-state-random ()
    "INTERNAL: Create random state from current time and counter.
     
     PURPOSE: Seed state based on time (for randomness) + counter (for uniqueness).
     
     ALGORITHM:
     1. Get current universal time (seconds since 1900)
     2. Increment counter to ensure uniqueness in rapid calls
     3. Sum time + counter
     4. Expand to full state using mt-make-random-state-integer
     
     RETURNS: New initialized mt-random-state
     
     QUALITY: Good for non-cryptographic purposes
     - Time provides randomness across runs
     - Counter ensures different states in tight loops
     - NOT suitable for cryptography
     
     EXAMPLE:
     (mt-make-random-state-random)
     => #<MT-RANDOM-STATE :MTI 0 :ARR #(...)>
     
     NOTE: Mostly internal. Users should call make-mt-random-state with T."
    (mt-make-random-state-integer
     (+ (get-universal-time)          ; Current time (seconds since 1900)
        (incf some-number)))))        ; Increment counter for uniqueness

(defun make-mt-random-state (&optional state)
  "PUBLIC API: Create or copy a Mersenne Twister random state.
   
   PARAMETERS:
   state — (optional) Seed specification
   
   BEHAVIOR (depends on state argument):
   
   STATE = T (symbol)
     Create new random state from current time.
     Each call returns a different state (counter ensures uniqueness).
     
   STATE = NIL (or not provided)
     Return a copy of the current global *mt-random-state*.
     Useful for capturing current state without advancing it.
   
   STATE = integer
     Expand the integer into a full state vector.
     Same integer always produces same state (reproducible).
     Supports arbitrarily large integers (bignum).
   
   STATE = sequence (list or array)
     Use sequence as initial state vector.
     Must be exactly 624 integers.
     Each integer must be in [0, 2^32).
     Advanced usage: for importing states or checksums.
   
   STATE = mt-random-state
     Return a copy of the given state.
     Original state unaffected.
   
   RETURNS: New mt-random-state structure
   
   EXAMPLES:
   (make-mt-random-state t)              ; New state from time
   (make-mt-random-state)                ; Copy of global state
   (make-mt-random-state 12345)          ; Seed with 12345 (reproducible)
   (make-mt-random-state some-state)    ; Copy some-state
   
   COMMON LISP COMPATIBILITY:
   Designed to mimic MAKE-RANDOM-STATE behavior.
   
   NOTE: Not thread-safe. See *mt-random-state* documentation."
  (cond
    ((eq state t)
     ;; Create new state from current time (non-reproducible)
     (mt-make-random-state-random))
    
    ((null state)
     ;; Copy current global state
     ;; Returns snapshot of *mt-random-state* at this moment
     (make-mt-random-state *mt-random-state*))
    
    ((integerp state)
     ;; Expand integer seed to full state (reproducible)
     ;; Same integer always produces same state
     ;; Supports arbitrary-precision integers
     (mt-make-random-state-integer state))
    
    ((typep state 'sequence)
     ;; Use sequence as initial state
     ;; Advanced usage: restore state from checkpoint
     ;; Must be 624-element array/list of integers
     (assert state)                   ; Check not NIL
     (assert (eql (length state) *mt-n*))  ; Check length = 624
     (assert (every #'integerp state))     ; Check all integers
     (mt-internal-make-random-state
      :mti 0
      :arr (copy-seq (coerce state 'array))))
    
    ((mt-random-state-p state)
     ;; Copy existing state
     ;; Creates independent copy (modifications don't affect original)
     (mt-internal-make-random-state
      :mti (mt-random-state-mti state)
      :arr (copy-seq (mt-random-state-arr state))))
    
    (t
     ;; Error: invalid state argument
     (cerror "STATE should be T, NIL, integer, sequence, or mt-random-state.~%Got: ~A"
             state))))

;; Initialize global state from current time
;; Ensures *mt-random-state* is usable for mt-random calls
(setq *mt-random-state* (make-mt-random-state t))

;;;; ============================================================================
;;;; STATE REGENERATION: mt-refill
;;;; ============================================================================

(let* ((matrix-a #x9908B0DF)
       ;; Magic constant from Matsumoto & Nishimura paper
       ;; Coerced to vector for efficient access
       (mag01 (coerce (list 0 matrix-a) 'vector)))
  
  (defun mt-refill ()
    "INTERNAL: Regenerate state array when exhausted.
     
     PURPOSE:
     The MT19937 algorithm generates 624 random numbers per state batch.
     After 624 calls to mt-genrand, the state must be regenerated.
     This function implements the twist transformation algorithm.
     
     WHEN CALLED:
     Automatically called by mt-genrand when mti >= 624.
     
     ALGORITHM: Three-phase twist transformation
     
     PHASE 1: Main loop (k = 0 to 226)
       y = (mt[k] & upper-mask) | (mt[k+1] & lower-mask)
       mt[k] = mt[k+397] ^ (y >> 1) ^ mag01[y & 1]
       
       - Combines upper bit of mt[k] with lower 31 bits of mt[k+1]
       - XORs with mt[k+397] (feedback from later position)
       - Right shift by 1 (mixing)
       - XOR with mag01 (matrix multiplication step)
     
     PHASE 2: Wrap-around loop (k = 227 to 622)
       y = (mt[k] & upper-mask) | (mt[k+1] & lower-mask)
       mt[k] = mt[k-227] ^ (y >> 1) ^ mag01[y & 1]
       
       - Same operation as Phase 1
       - But uses offset mt[k-227] instead of mt[k+397]
       - Handles wrap-around (k+1 would exceed 624)
     
     PHASE 3: Final element (k = 623)
       y = (mt[623] & upper-mask) | (mt[0] & lower-mask)
       mt[623] = mt[396] ^ (y >> 1) ^ mag01[y & 1]
       
       - Combines last element with first (wrap-around)
       - Completes twist cycle
     
     WHY THIS DESIGN:
     - Implements tempering polynomial from paper
     - Ensures long period (2^19937 - 1)
     - Maintains equidistribution properties
     - Direct translation of C reference implementation
     
     SIDE EFFECTS:
     - Modifies *mt-random-state* array
     - Sets mti to 0 (ready for 624 new numbers)
     
     PERFORMANCE:
     O(N) = O(624) per refill
     Amortized O(1) per call (refill every 624 calls)"
    
    ;; Local variables for loop iterations
    (let (y kk)
      
      ;; ====== PHASE 1: Main loop (k = 0 to 226) ======
      (setq kk 0)
      (do ()
          ((>= kk (- *mt-n* *mt-m*)))  ; Loop while k < 227
        
        ;; Combine upper bit of mt[k] with lower bits of mt[k+1]
        (setq y (logior
                 (logand (aref (mt-random-state-arr *mt-random-state*) kk)
                         *mt-upper-mask*)
                 (logand (aref (mt-random-state-arr *mt-random-state*) (1+ kk))
                         *mt-lower-mask*)))
        
        ;; Apply twist transformation with feedback from mt[k+397]
        (setf (aref (mt-random-state-arr *mt-random-state*) kk)
              (logxor
               (aref (mt-random-state-arr *mt-random-state*) (+ kk *mt-m*))
               (ash y -1)                    ; Right shift by 1
               (aref mag01 (logand y 1))))   ; mag01[y & 1]
        
        (incf kk))
      
      ;; ====== PHASE 2: Wrap-around loop (k = 227 to 622) ======
      (do ()
          ((>= kk (- *mt-n* 1)))        ; Loop while k < 623
        
        ;; Combine upper bit of mt[k] with lower bits of mt[k+1]
        (setq y (logior
                 (logand (aref (mt-random-state-arr *mt-random-state*) kk)
                         *mt-upper-mask*)
                 (logand (aref (mt-random-state-arr *mt-random-state*) (1+ kk))
                         *mt-lower-mask*)))
        
        ;; Apply twist with feedback from mt[k-227] (wrap-around offset)
        (setf (aref (mt-random-state-arr *mt-random-state*) kk)
              (logxor (aref (mt-random-state-arr *mt-random-state*)
                            (+ kk (- *mt-m* *mt-n*)))
                      (ash y -1)
                      (aref mag01 (logand y 1))))
        
        (incf kk))
      
      ;; ====== PHASE 3: Final element (wrap-around) ======
      ;; Combine last element (k=623) with first element (k=0)
      (setq y (logior
               (logand (aref (mt-random-state-arr *mt-random-state*)
                             (- *mt-n* 1))
                       *mt-upper-mask*)
               (logand (aref (mt-random-state-arr *mt-random-state*) 0)
                       *mt-lower-mask*)))
      
      ;; Final twist: uses mt[396] for feedback
      (setf (aref (mt-random-state-arr *mt-random-state*) (- *mt-n* 1))
            (logxor
             (aref (mt-random-state-arr *mt-random-state*) (- *mt-m* 1))
             (ash y -1)
             (aref mag01 (logand y 1))))
      
      ;; Reset index: ready for 624 new calls
      (setf (mt-random-state-mti *mt-random-state*) 0))
    
    ;; Return symbol for debugging/tracing
    'mt-refill)))

;;;; ============================================================================
;;;; TEMPERING: Statistical Quality Improvement
;;;; ============================================================================

(defun mt-tempering-shift-u (n)
  "Right-shift tempering (U-tempering).
   
   FORMULA: (n >> 11) mod 2^32
   
   PURPOSE: Part of tempering transformation to improve statistical properties.
   
   PARAMETER: n — 32-bit unsigned integer
   
   RETURNS: Integer with upper 11 bits zeroed
   
   Used in mt-genrand as: y ^= y >> 11"
  (mod (ash n -11) *mt-k2^32*))

(defun mt-tempering-shift-s (n)
  "Left-shift tempering (S-tempering).
   
   FORMULA: (n << 7) mod 2^32
   
   PURPOSE: Part of tempering transformation.
   
   PARAMETER: n — 32-bit unsigned integer
   
   RETURNS: Integer with lower 7 bits zeroed
   
   Used in mt-genrand with mask: y ^= (y << 7) & 0x9d2c5680"
  (mod (ash n 7) *mt-k2^32*))

(defun mt-tempering-shift-t (n)
  "Left-shift tempering (T-tempering).
   
   FORMULA: (n << 15) mod 2^32
   
   PURPOSE: Part of tempering transformation.
   
   PARAMETER: n — 32-bit unsigned integer
   
   RETURNS: Integer with lower 15 bits zeroed
   
   Used in mt-genrand with mask: y ^= (y << 15) & 0xefc60000"
  (mod (ash n 15) *mt-k2^32*))

(defun mt-tempering-shift-l (n)
  "Right-shift tempering (L-tempering).
   
   FORMULA: (n >> 18) mod 2^32
   
   PURPOSE: Final part of tempering transformation.
   
   PARAMETER: n — 32-bit unsigned integer
   
   RETURNS: Integer with upper 18 bits zeroed
   
   Used in mt-genrand as: y ^= y >> 18"
  (mod (ash n -18) *mt-k2^32*))

;;;; ============================================================================
;;;; CORE GENERATOR: mt-genrand
;;;; ============================================================================

(let ((mt-tempering-mask-b #x9d2c5680)
      (mt-tempering-mask-c #xefc60000))
  
  (defun mt-genrand ()
    "INTERNAL: Generate next 32-bit random integer.
     
     PURPOSE: Core generator function producing raw 32-bit unsigned integer [0, 2^32).
     
     RETURNS: Uniformly distributed 32-bit unsigned integer
     
     ALGORITHM:
     1. Check if state exhausted (mti >= 624)
        → If yes, call mt-refill to regenerate state
     2. Extract y = mt[mti], increment mti
     3. Apply tempering (4 XOR and shift operations)
     4. Return tempered y
     
     TEMPERING SEQUENCE:
     y ^= (y >> 11)
     y ^= (y << 7) & 0x9d2c5680
     y ^= (y << 15) & 0xefc60000
     y ^= (y >> 18)
     
     WHY TEMPERING:
     - Raw twist output has statistical biases
     - Tempering adds nonlinearity
     - Improves equidistribution in higher dimensions
     - Standard approach from MT19937 paper
     
     PERFORMANCE:
     - Refill: O(624) every 624 calls (amortized O(1))
     - Extract & temper: O(1) per call
     - Total: ~10-20 cycles per number (fast)
     
     QUALITY:
     - Passes Diehard statistical tests
     - Good for Monte Carlo simulations
     - NOT suitable for cryptography
     
     NOTE: Internal function. Users should call mt-random."
    
    ;; Check if state exhausted (mti >= 624)
    ;; If yes, regenerate 624 new numbers
    (when (>= (mt-random-state-mti *mt-random-state*) *mt-n*)
      (mt-refill))
    
    ;; Extract y from current state at index mti
    ;; Then increment mti for next call
    (let ((y (aref (mt-random-state-arr *mt-random-state*)
                   (mt-random-state-mti *mt-random-state*))))
      (incf (mt-random-state-mti *mt-random-state*))
      
      ;; Apply tempering transformation
      ;; Note: Could optimize to single expression, but follows C reference
      
      ;; Tempering step 1: Right shift 11, XOR
      (setq y (logxor y (mt-tempering-shift-u y)))
      
      ;; Tempering step 2: Left shift 7, mask, XOR
      (setq y (logxor y (logand (mt-tempering-shift-s y)
                                mt-tempering-mask-b)))
      
      ;; Tempering step 3: Left shift 15, mask, XOR
      (setq y (logxor y (logand (mt-tempering-shift-t y)
                                mt-tempering-mask-c)))
      
      ;; Tempering step 4: Right shift 18, XOR
      (setq y (logxor y (mt-tempering-shift-l y)))
      
      ;; Return tempered value
      y)))

;;;; ============================================================================
;;;; PUBLIC API: mt-random
;;;; ============================================================================

(defun mt-random (n &optional state)
  "PUBLIC API: Generate random number in range [0, n).
   
   PARAMETERS:
   
   n — Upper bound (exclusive)
       - Integer: Returns random integer in [0, n)
       - Float: Returns random float in [0.0, n)
       - Can be arbitrarily large (bignum for integers)
   
   state — (optional) Random state to use or seed
           - NIL: Use global *mt-random-state*
           - t: Create new state from time (ignored if nil)
           - mt-random-state: Use given state
           - integer: Seed from integer
   
   RETURNS:
   - For integer n: Random integer in range [0, n)
   - For float n: Random float in range [0.0, n)
   
   ALGORITHM FOR INTEGER:
   1. Determine bits needed to represent n: ceil(log2(n))
   2. Accumulate 32-bit chunks until enough bits collected
   3. Return (accumulated-bits mod n)
   
   This ensures uniform distribution even for n not power-of-2.
   
   ALGORITHM FOR FLOAT:
   1. Generate 32-bit integer via mt-genrand
   2. Convert to [0.0, 1.0) via multiplication by 2^-32
   3. Multiply by n to scale to [0.0, n)
   
   EXAMPLES:
   (mt-random 100)              → Random integer [0, 100)
   (mt-random 1.0)              → Random float [0.0, 1.0)
   (mt-random (expt 2 64))       → Large integer (uses multiple chunks)
   (mt-random 1000000000000.0)   → Large float
   
   THREAD SAFETY WARNING:
   If state is provided, modifies global *mt-random-state*.
   NOT thread-safe. Use thread-local states for multi-threading.
   
   EXAMPLE WITH STATE:
   (let ((my-state (make-mt-random-state 12345)))
     (mt-random 100 my-state))   ; Creates new state from seed
   
   ASSERTIONS:
   - n must be positive (> 0)
   - state must be valid if provided
   
   NOTE: Primary user-facing function of MT19937 module."
  
  ;; Assertion: n must be positive
  (assert (plusp n))
  
  ;; If state provided, use it to seed global *mt-random-state*
  ;; This allows deterministic seeding: mt-random(n, seed)
  (when state
    (assert (mt-random-state-p state))
    ;; Save a copy of the random state
    (setq *mt-random-state* (make-mt-random-state state)))
  
  ;; Dispatch on type of n
  (if (integerp n)
      ;; INTEGER CASE: Return random integer in [0, n)
      ;; Algorithm: Accumulate 32-bit chunks until enough bits
      (mod (do ((bits-needed (log n 2))      ; How many bits to represent n
               (bit-count 0 (+ 32 bit-count)) ; Running count of accumulated bits
               (r 0 (+ (ash r 32) (mt-genrand))))  ; Accumulate 32-bit chunks
           ((>= bit-count bits-needed) r))   ; Stop when enough bits
       n)
    ;; FLOAT CASE: Return random float in [0.0, n)
    ;; Algorithm: Scale unit float [0.0, 1.0) to [0.0, n)
    (* (mt-genrand) *mt-k-inverse-2^32f* n)))

;;;; --- end of file ---

(in-package :cl-user)
