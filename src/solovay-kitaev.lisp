;;;; solovay-kitaev.lisp
;;;;
;;;; Authors: Andrew Shi, Mark Skilbeck

(in-package :cl-quil)

;;; This file contains an implementation of the Solovay-Kitaev
;;; algorithm described in https://arxiv.org/pdf/quant-ph/0505030.pdf,
;;; used to approximately decompose arbitrary unitaries using a finite
;;; set of basis gates.

;;; In the rest of this file, d(x, y) refers to the function of
;;; operator distance defined in the above paper and is equal to ||X -
;;; Y||, the operator norm of (X - Y).

;;; Constant that upper bounds the ratio between d(V, I) [or d(W, I)]
;;; and sqrt(d(U, I)) if V and W are balanced group commutators of U
;;; [found on page 8 of the paper]. 0.9 is a value obtained
;;; numerically through testing gc-decompose on random unitaries.
(defparameter +c-gc+ 0.9)
;;; Constant that upper bounds the ratio between d(VWV'W', approximate
;;; VWV'W') and eps^(3/2), for the balanced group commutators V, W of
;;; a unitary and the eps-approximation of each commutator [eps = d(V,
;;; approximate V) = d(W, approximate W)]. It is also assumed that
;;; d(V, I) = d(W, I) < c-gc * sqrt(eps), which is true for group
;;; commutator decompositions made inside the SK-algorithm. [found on
;;; page 9 of the paper]

;;; This should theoretically be approximately equal to (* 8 +c-gc+),
;;; but as the paper's authors have shown, a c-approx as low as 2.67
;;; can work in practice [yielding a base approximation distance of
;;; 1/c-approx^2 = 0.14]. We'll use that for now.
(defparameter +c-approx+ 2.67)
;;; One-qubit identity and pauli spin matrices, may be replaced later
(defparameter +I+ (magicl:make-complex-matrix 2 2 '(1 0 0 1)))
(defparameter +PX+ (magicl:make-complex-matrix 2 2 '(0 1 1 0)))
(defparameter +PY+ (magicl:make-complex-matrix 2 2 '(0 #C(0 1) #C(0 -1) 0)))
(defparameter +PZ+ (magicl:make-complex-matrix 2 2 '(1 0 0 -1)))

;;; ------------------------------------------------------------------
;;; --------------Various utility functions/structures----------------
;;; ------------------------------------------------------------------

(defun vector-dot-product (a b)
  "Dot product between vectors A and B."
  (assert (= (length a) (length b)))
  (reduce #'+ (loop :for ai :across a :for bi :across b
                    :collect (* ai bi))))

(defun vector-cross-product (a b)
  "Cross product between vectors A and B."
  (assert (= (length a) (length b) 3))
  (let ((ax (aref a 0))
        (ay (aref a 1))
        (az (aref a 2))
        (bx (aref b 0))
        (by (aref b 1))
        (bz (aref b 2))
        (result (make-array 3)))
    (setf (aref result 0) (- (* ay bz) (* az by)))
    (setf (aref result 1) (- (* az bx) (* ax bz)))
    (setf (aref result 2) (- (* ax by) (* ay bx)))
    result))

(defun vector-norm (a)
  "Norm of the vector A."
  (sqrt (vector-dot-product a a)))

(defun vector-distance (a b)
  "Norm of the vector A - B."
  (assert (= (length a) (length b)))
  (sqrt (reduce #'+ (loop :for ai :across a :for bi :across b
                          :collect (expt (- ai bi) 2)))))

(defun axis-angle-ball-distance (bv1 bv2)
  "Distance on the axis-angle ball between bloch-vectors BV1 and BV2."
  (let ((ball1 (make-array 3))
        (ball2 (make-array 3)))
    (loop :for i :below 3
          :for i1 :across (bloch-vector-axis bv1)
          :for i2 :across (bloch-vector-axis bv2)
          :do (setf (aref ball1 i) (* i1 (bloch-vector-theta bv1)))
              (setf (aref ball2 i) (* i2 (bloch-vector-theta bv2))))
    (vector-distance ball1 ball2)))

(defun vector-normalize (v)
  "Normalizes the vector V in-place; returns its norm."
  (let ((norm (vector-norm v)))
    (assert (> norm 0) nil "ERROR: cannot normalize the zero vector ~A" v)
    (loop :for i :below (length v) :do (setf (aref v i) (/ (aref v i) norm)))
    norm))

(defun basis-gate-from-index (basis-gates idx)
  "Given an index IDX in sign-inverse convention, return the corresponding basis gate from BASIS-GATES. Specifically, if IDX is negative, return the inverse of the corresponding gate, which is the element in BASIS-GATES indexed by (absolute value of IDX minus 1)."
  (aref basis-gates (1- (abs idx))))

;; (defstruct commutator
;;   (v '() :type list)
;;   (w '() :type list))

;; (defun multiply-commutator (comm)
;;   comm)

;; (defun expand-commutator (comm)
;;   (let ((v (commutator-v comm))
;;         (w (commutator-w comm)))
;;     (append v w (dagger v) (dagger w))))

(defun seq-dagger (op-seq)
  (reverse (mapcar #'(lambda (x) (* -1 x)) op-seq)))

(defun random-bloch-vector (max-theta &key (def-theta 0))
  "Generate a random bloch-vector with a maximum rotation angle of MAX-THETA. However, if DEF-THETA is set to a non-zero value, generate a random bloch-vector with the exact rotation angle DEF-THETA."
  (let ((bv (matrix-to-bloch-vector (magicl:random-unitary 2))))
    (setf (bloch-vector-theta bv) (if (zerop def-theta) (random max-theta) def-theta))
    bv))

(defun matrix-trace (m)
  (loop :for i :below (magicl:matrix-cols m)
        :sum (magicl:ref m i i)))

(defun fidelity (m)
  (let ((p (* 2 (log (magicl:matrix-cols m) 2))))
    (/ (+ (expt (abs (matrix-trace m)) 2) p)
       (+ (expt p 2) p))))

;;; Charles
(defun charles-distance (u s)
  (- 1 (fidelity (magicl:multiply-complex-matrices
                  (magicl:conjugate-transpose s)
                  u))))

;;; Not sure which distance measure to use, this one or trace norm or charles' fidelity
(defun distance (u s)
  "Returns d(u, s) = ||U - S||, the operator norm of U - S defined in the paper."
  (let ((sigma (nth-value 1 (magicl:svd (magicl:sub-matrix u s)))))
    (sqrt (reduce #'max (loop :for i :below (magicl:matrix-rows sigma) :collect (magicl:ref sigma i i))))))

(defun find-c-gc (num-trials)
  "Numerically tests for the value of c-gc, the upper bound on the ratio between d(V, I) [or d(W, I)] and sqrt(d(U, I)) if V and W are balanced group commutators of U."
  (loop :for i :below num-trials :for u := (magicl:random-unitary 2) :for v := (gc-decompose u) :maximize (/ (distance v +I+) (sqrt (distance u +I+)))))

;;; ------------------------------------------------------------------
;;; -------------------------THE MEATY PART---------------------------
;;; ------------------------------------------------------------------

(defclass decomposer ()
  ((basis-gates :reader basis-gates
                :initarg :basis-gates
                :type (vector simple-gate *)
                :initform (error ":BASIS-GATES is a required initarg to DECOMPOSER.")
                :documentation "Set of basic gates/operators to decompose to.")
   (num-qubits :reader num-qubits
               :initarg :num-qubits
               :type non-negative-fixnum
               :initform (error ":NUM-QUBITS is a required initarg to DECOMPOSER.")
               :documentation "Number of qubits the operators of this decomposer act on.")
   (epsilon0 :reader epsilon0
             :initarg :epsilon0
             :type double-float
             :initform (error ":EPSILON0 is a required initarg to DECOMPOSER.")
             :documentation "Parameter controlling the density of base-approximation unitaries for this decomposer. Specifically, every unitary operator on NUM-QUBITS should be within EPSILON0 of some unitary in BASE-APPROXIMATIONS.")
   (base-approximations :accessor base-approximations
                        :initarg :base-approximations
                        :initform nil
                        :documentation "A set of base approximations such that every unitary operator on NUM-QUBITS (all operators in SU(2^NUM-QUBITS)) is within EPSILON0 of some unitary in the set."))
  (:documentation "A decomposer which uses the Solovay-Kitaev algorithm to approximately decompose arbitrary unitaries to a finite set of basis gates."))

(defun make-decomposer (basis-gates num-qubits epsilon0)
  "Initializer for a unitary decomposer."
  (assert (< epsilon0 (/ (expt +c-approx+ 2))) (epsilon0) "ERROR: the provided base approximation epsilon ~A is not less than ~A, which it must be for approximations to improve on each iteration." epsilon0 (/ (expt +c-approx+ 2)))
  (make-instance 'decomposer
                 :basis-gates basis-gates
                 :num-qubits num-qubits
                 :epsilon0 epsilon0
                 :base-approximations (generate-base-approximations basis-gates num-qubits epsilon0)))

(defun epsilon0-from-ball-division (num-trials grid-length)
  "Computes the max value of epsilon0 that a grid of spacing GRID-LENGTH on the angle-axis ball would satisfy."
  (loop :for i :below num-trials
        :for bv1 := (random-bloch-vector (/ pi 2))
        :for bv2 := (random-bloch-vector (/ pi 2))
        :for bv-dist := (axis-angle-ball-distance bv1 bv2)
        :for mat-dist := (distance (bloch-vector-to-matrix bv1) (bloch-vector-to-matrix bv2))
        ;; Checks if the random unitaries picked have an angle-axis
        ;; ball distance shorter than the diagonal of a grid cube
        :when (< bv-dist (sqrt (* 3 (expt grid-length 2))))
          :maximize mat-dist))

;;; --------------------------------------------------------------
;;; --------------BASE APPROXIMATION GENERATION-------------------
;;; --------------------------------------------------------------

;;; The general procedure here is to use what I call the "angle-axis
;;; ball" mapping of SU(2) (technically PU(2), the group of SU(2)
;;; modulo global phase). The unitary which is a rotation about an
;;; axis in 3d space by an angle theta is mapped to a point of radius
;;; theta in the direction of the rotation axis; thus, the entire
;;; group is mapped to a ball of radius pi. The Euclidean distance
;;; between points in the angle-axis ball is not perfectly correlated
;;; with our desired metric of operator distance, but is related
;;; closely enough to serve as a surprisingly good heuristic. It is
;;; also much more convenient to work with than a 3-sphere, which is
;;; kind of the whole reason why I'm using this.

(defun generate-base-approximations (basis-gates num-qubits epsilon0)
  "Generates a set of base approximations such that every unitary operator on NUM-QUBITS (all operators in SU(2^NUM-QUBITS)) is within EPSILON0 of some unitary in the set. The approximations are returned as a hash map from each grid block in the axis-angle ball to the unitary that approximates that block."
  (values basis-gates num-qubits epsilon0))

(defun find-base-approximation (base-approximations u)
  "Returns the base case approximation for a unitary U, represented as a list of indices in sign-inverse convention."
  (values base-approximations u))

(defun sk-iter (decomposer u n)
  "An approximation iteration within the Solovay-Kitaev algorithm at a depth N. Returns a list of integer indices in sign-inverse convention."
  (if (zerop n)
      (find-base-approximation (base-approximations decomposer) u)
      (multiple-value-bind (v w) (gc-decompose u)
        (let* ((v-next (sk-iter decomposer v (1- n)))
               (w-next (sk-iter decomposer w (1- n))))
          (append v-next w-next (seq-dagger v-next) (seq-dagger w-next) (sk-iter decomposer u (1- n)))))))

(defun decompose (decomposer unitary epsilon)
  "Decomposes a unitary into a sequence of basis gates defined by DECOMPOSER, such that the resulting decomposition is within EPSILON of the original unitary."
  (let* ((eps0 (epsilon0 decomposer))
         (depth (ceiling (log (/ (log (* epsilon +c-approx+ +c-approx+))
                                 (log (* eps0 +c-approx+ +c-approx+))))
                         (log (/ 3 2))))
         (basis-gates (basis-gates decomposer)))
    (mapcar #'(lambda (x) (basis-gate-from-index basis-gates x)) (sk-iter decomposer unitary depth))))

;;; ------------------------------------------------------------------
;;; -------------FUNCTIONS FOR FINDING GROUP COMMUTATORS--------------
;;; ------------------------------------------------------------------
;;; Overall procedure taken in https://github.com/cmdawson/sk to find
;;; balanced group commutators V and W for a unitary U (the ' symbol
;;; represents a dagger):
;;;
;;;    1) Convert U to its Bloch vector representation, which is a
;;;       rotation by some theta around an arbitrary axis.
;;;
;;;    2) Find unitaries S and Rx s.t. Rx is a rotation around the X
;;;       axis by theta and SRxS' = U.
;;;
;;;    3) Find the group commutators B, C for Rx s.t. Rx = BCB'C'.
;;;
;;; With A, B, and S, we can set V = SBS' and W = SCS', because then
;;; VWV'W' = SBS'SCS'SB'S'SC'S' = SBCB'C'S' = SRxS' = U.

;;; Bloch vector structure and conversions to/from unitary matrices
(defstruct (bloch-vector (:constructor make-bloch-vector))
  "A bloch-vector representation of unitaries as a rotation about an axis on the Bloch sphere."
  (theta 0.0d0 :type double-float)
  (axis #(0 0 0) :type (simple-vector 3)))

;;; Conversions between matrix and bloch vector representations of
;;; unitaries. To understand them, remember/note that for a rotation
;;; of an angle theta about the bloch sphere axis <x, y, z> with unit
;;; norm, the corresponding matrix representation is U = cos(t/2)*I -
;;; isin(t/2) * (x*X + y*Y + z*Z), where t = theta/2 and X, Y, Z are
;;; the usual Pauli matrices (I = identity). Thus, a unitary obtained
;;; from this representation would have the form
;;;
;;;           /                                           \
;;;           | cos(t) - z*i*sin(t)    -sin(t)*(x*i + y)  |
;;;           |                                           |
;;;           |  -sin(t)*(x*i - y)    cos(t) + z*i*sin(t) |
;;;           \                                           /
;;;
;;; up to a global phase factor. Using the equation, we can convert
;;; from bloch vector to matrix, and using this matrix, we can extract
;;; the bloch vector parameters to convert back, which is what the
;;; functions below do.
(defun matrix-to-bloch-vector (mat)
  "Converts a unitary matrix into its bloch-vector representation."
  (let* ((phase-correction (bloch-phase-correction mat))
         (mat (magicl:scale phase-correction mat))
         (x-sin (* -1 (imagpart (magicl:ref mat 0 1))))
         (y-sin (realpart (magicl:ref mat 1 0)))
         (z-sin (imagpart (/ (- (magicl:ref mat 1 1) (magicl:ref mat 0 0)) 2)))
         (cos-theta (realpart (/ (+ (magicl:ref mat 0 0) (magicl:ref mat 1 1)) 2)))
         (sin-theta (sqrt (+ (expt x-sin 2) (expt y-sin 2) (expt z-sin 2))))
         (theta (* 2 (atan sin-theta cos-theta)))
         (axis (make-array 3)))
    (setf (aref axis 0) (if (zerop sin-theta) 0 (/ x-sin sin-theta)))
    (setf (aref axis 1) (if (zerop sin-theta) 0 (/ y-sin sin-theta)))
    (setf (aref axis 2) (if (zerop sin-theta) 0 (/ z-sin sin-theta)))
    (make-bloch-vector :theta theta :axis axis)))

(defun bloch-vector-to-matrix (bv)
  "Converts a bloch-vector to the corresponding unitary matrix."
  (let* ((half-theta (/ (bloch-vector-theta bv) 2))
         (axis (bloch-vector-axis bv))
         (nx (aref axis 0))
         (ny (aref axis 1))
         (nz (aref axis 2))
         (axis-factor (* #C(0 -1) (sin half-theta))))
    (magicl:add-matrix (magicl:scale (cos half-theta) +I+)
                       (magicl:scale (* nx axis-factor) +PX+)
                       (magicl:scale (* ny axis-factor) +PY+)
                       (magicl:scale (* nz axis-factor) +PZ+))))

(defun bloch-phase-correction (mat)
  "Calculates the global phase adjustment needed to put a matrix MAT into the bloch-vector matrix form described in the comment above. MAT should be multiplied by the returned phase number to produce the desired form."
  (let* ((diag-sum (+ (magicl:ref mat 0 0) (magicl:ref mat 1 1)))
         (off-diag-sum (+ (magicl:ref mat 1 0) (magicl:ref mat 0 1)))
         (off-diag-diff (- (magicl:ref mat 1 0) (magicl:ref mat 0 1)))
         (diag-diff (- (magicl:ref mat 0 0) (magicl:ref mat 1 1)))
         (phase-nums (list diag-sum off-diag-sum off-diag-diff diag-diff)))
    ;; In a matrix directly obtained from expanding the bloch vector
    ;; representation, the sum of the diagonal and the difference of
    ;; the off-diagonal should be purely real. Likewise, the diagonal
    ;; difference and the off-diagonal sum should be purely
    ;; imaginary. Thus, we use the first non-zero number in these
    ;; quantities to find our phase correction.
    (loop :for i :below 4
          :for num :in phase-nums
          :when (not (zerop num))
            :do (return (* (/ (abs num) num) (if (evenp i) 1 #C(0 -1)))))))

(defun unitary-to-conjugated-x-rotation (u)
  "Given a unitary U, returns unitaries S and Rx such that Rx is a rotation around the X axis by the same angle that U rotates around its axis, and U = SRxS'."
  (let* ((u-bv (matrix-to-bloch-vector u))
         (rx-bv (make-bloch-vector :theta (bloch-vector-theta u-bv) :axis #(1 0 0)))
         (rx (bloch-vector-to-matrix rx-bv)))
    (values (find-transformation-matrix u rx) rx)))

(defun find-transformation-matrix (a b)
  "Given unitaries A and B, finds the unitary S such that A = SBS'."
  (let* ((a-bv (matrix-to-bloch-vector a))
         (b-bv (matrix-to-bloch-vector b))
         (a-axis (bloch-vector-axis a-bv))
         (b-axis (bloch-vector-axis b-bv))
         (dot-prod (vector-dot-product a-axis b-axis))
         (cross-prod (vector-cross-product b-axis a-axis))
         (result-bv (make-bloch-vector)))
    ;; Only bother finding an axis if the vectors aren't parallel
    (unless (and (zerop (vector-norm cross-prod)) (double~ dot-prod 0))
      (cond ((zerop (vector-norm cross-prod)) nil) ;; very special anti-parallel case
            (t ;; General case
             (vector-normalize cross-prod)
             (setf (bloch-vector-axis result-bv) cross-prod)
             (setf (bloch-vector-theta result-bv) (acos dot-prod)))))
    (bloch-vector-to-matrix result-bv)))

(defun gc-decompose-x-rotation (u)
  "Given a unitary U, returns B and C, two unitaries which are balanced commutators of U (i.e. U = [B, C] = BCB'C'). IMPORTANT: U must be a rotation about the X axis; this is not the general function for any U."
  (let* ((u-cos-half-theta (cos (/ (bloch-vector-theta (matrix-to-bloch-vector u)) 2)))
         (st (expt (/ (- 1 u-cos-half-theta) 2) 1/4))
         (ct (sqrt (- 1 (expt st 2))))
         (theta (* 2 (asin st)))
         (alpha (atan st))
         (b-axis (make-array 3))
         (w-axis (make-array 3)))
    (setf (aref w-axis 0) (* st (cos alpha)))
    (setf (aref b-axis 0) (* st (cos alpha)))
    (setf (aref w-axis 1) (* st (sin alpha)))
    (setf (aref b-axis 1) (* st (sin alpha)))
    (setf (aref w-axis 2) ct)
    (setf (aref b-axis 2) (- ct))
    (let ((b (bloch-vector-to-matrix (make-bloch-vector :theta theta :axis b-axis)))
          (w (bloch-vector-to-matrix (make-bloch-vector :theta theta :axis w-axis))))
      (values b (find-transformation-matrix w (magicl:dagger b))))))

(defun gc-decompose (u)
  "Find the balanced group commutators V and W for any unitary U."
  (let* ((u-theta (bloch-vector-theta (matrix-to-bloch-vector u)))
         (rx-theta (bloch-vector-to-matrix (make-bloch-vector :theta u-theta :axis #(1 0 0))))
         (s (find-transformation-matrix u rx-theta)))
    (multiple-value-bind (b c) (gc-decompose-x-rotation rx-theta)
      (values (magicl:multiply-complex-matrices s (magicl:multiply-complex-matrices b (magicl:dagger s)))
              (magicl:multiply-complex-matrices s (magicl:multiply-complex-matrices c (magicl:dagger s)))))))

;;; Some functions which explore the ball representation of SU(2)
(defun ball-op-distances ()
  (let* ((bv1 (random-bloch-vector pi))
         (bv2 (random-bloch-vector pi))
         (u1 (bloch-vector-to-matrix bv1))
         (u2 (bloch-vector-to-matrix bv2))
         (ball1 (make-array 3))
         (ball2 (make-array 3)))
    (loop :for i :below 3
          :for i1 :across (bloch-vector-axis bv1)
          :for i2 :across (bloch-vector-axis bv2)
          :do (setf (aref ball1 i) (* i1 (bloch-vector-theta bv1)))
              (setf (aref ball2 i) (* i2 (bloch-vector-theta bv2))))
    (values (distance u1 u2) (vector-distance ball1 ball2))))

(defun ball-op-distance-ratios (num-trials)
  (let ((min-ratio MOST-POSITIVE-FIXNUM)
        (max-ratio MOST-NEGATIVE-FIXNUM))
    (dotimes (i num-trials)
      (multiple-value-bind (op-dist ball-dist) (ball-op-distances)
        (setf min-ratio (min min-ratio (/ op-dist ball-dist)))
        (setf max-ratio (max max-ratio (/ op-dist ball-dist)))))
    (format t "~%TESTING RATIO OF OPERATOR DISTANCE TO BALL DISTANCE~%Min: ~A~%Max: ~A~%" min-ratio max-ratio)))

(defun op-dist-range (num-trials max-angle)
  (let ((min-dist MOST-POSITIVE-FIXNUM)
        (max-dist MOST-NEGATIVE-FIXNUM))
    (loop :for i :below num-trials
          :for bv1 := (random-bloch-vector max-angle)
          :for bv2 := (random-bloch-vector max-angle)
          :for u1 := (bloch-vector-to-matrix bv1)
          :for u2 := (bloch-vector-to-matrix bv2)
          :for dist := (distance u1 u2)
          :do (setf min-dist (min min-dist dist))
              (setf max-dist (max max-dist dist)))
    (format t "~%[TESTING THE RANGE OF OPERATOR DISTANCES]~%Up to max-angle: ~A~%Min op dist: ~A~%Max op dist: ~A~%" max-angle min-dist max-dist)))

(defun search-op-variations (num-trials target-dist &key (tolerance 0))
  (let ((min-dist MOST-POSITIVE-FIXNUM)
        (max-dist MOST-NEGATIVE-FIXNUM)
        (hits 0))
    (loop :for i :below num-trials
          :for bv1 := (random-bloch-vector (/ pi 2))
          :for bv2 := (random-bloch-vector (/ pi 2))
          :for bv-dist := (axis-angle-ball-distance bv1 bv2)
          :for op-dist := (distance (bloch-vector-to-matrix bv1) (bloch-vector-to-matrix bv2))
          :when (if (zerop tolerance) (< bv-dist target-dist) (< (abs (- bv-dist target-dist)) tolerance))
            :do (setf min-dist (min min-dist op-dist))
                (setf max-dist (max max-dist op-dist))
                (incf hits))
    (format t "~%[TESTING VARIATION OF OPERATOR DISTANCES]~%")
    (format t "Num trials: ~A~%Target ball dist: ~A~%Max op dist: ~A~%Percent hits: ~A~%"
            num-trials target-dist max-dist (/ hits num-trials 1.0))
    (unless (zerop tolerance)
      (format t "(Additional data)~%Tolerance: ~A~%Min op dist: ~A~%% of entire interval [0, 1.2] taken up: ~A~%"
              tolerance min-dist (/ (- max-dist min-dist) 1.2)))))

(defun search-ball-variations (num-trials target-dist &key (tolerance 0))
  (let ((min-dist MOST-POSITIVE-FIXNUM)
        (max-dist MOST-NEGATIVE-FIXNUM)
        (hits 0))
    (loop :for i :below num-trials
          :for bv1 := (random-bloch-vector (/ pi 2))
          :for bv2 := (random-bloch-vector (/ pi 2))
          :for bv-dist := (axis-angle-ball-distance bv1 bv2)
          :for op-dist := (distance (bloch-vector-to-matrix bv1) (bloch-vector-to-matrix bv2))
          :when (if (zerop tolerance) (< op-dist target-dist) (< (abs (- op-dist target-dist)) tolerance))
            :do (setf min-dist (min min-dist bv-dist))
                (setf max-dist (max max-dist bv-dist))
                (incf hits))
    (format t "~%[TESTING VARIATION OF BALL DISTANCES]~%")
    (format t "Num trials: ~A~%Target op dist: ~A~%Max ball dist: ~A~%Percent hits: ~A~%"
            num-trials target-dist max-dist (/ hits num-trials 1.0))
    (unless (zerop tolerance)
      (format t "(Additional data)~%Tolerance: ~A~%Min op dist: ~A~%% of entire interval [0, pi] taken up: ~A~%"
              tolerance min-dist (/ (- max-dist min-dist) pi)))))

(defun compare-variations (num-trials tolerance-var)
  (search-ball-variations num-trials tolerance-var)
  (search-op-variations num-trials (* tolerance-var (/ pi (sqrt 2)))))
