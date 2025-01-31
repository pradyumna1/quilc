;;;; euler-compile.lisp
;;;;
;;;; Author: Eric Peterson

(in-package #:cl-quil)

;; a different implementation of this might call csc-compile and then convert
;; the resulting uncontrolled UCRs into just rolls.

(defmacro define-euler-compiler (name
                                 &key
                                   (outer-prefactor 1)
                                   (inner-prefactor 1)
                                   (outer-gate "RZ")
                                   (inner-gate "RY")
                                   (prefix-quil nil))
  "Produces an Euler decomposition of the form OUTER-GATE INNER-GATE OUTER-GATE, where OUTER-GATE and INNER-GATE satisfy OUTER-GATE^OUTER-PREFACTOR = PREFIX-QUIL RZ (PREFIX-QUIL)^-1 and INNER-GATE^INNER-PREFACTOR = PREFIX-QUIL RY (PREFIX-QUIL)^-1 (both in Quil order, not matrix order)."
  (check-type outer-gate string)
  (check-type inner-gate string)
  (check-type outer-prefactor real)
  (check-type inner-prefactor real)
  (check-type prefix-quil a:proper-list)
  (a:with-gensyms (prefix-matrix postfix-matrix u0 u1 v0 v1 angles)
    `(let* ((,prefix-matrix (make-matrix-from-quil ,prefix-quil))
            (,postfix-matrix (magicl::conjugate-transpose ,prefix-matrix)))
       (declare (ignorable ,prefix-matrix ,postfix-matrix))
       (define-compiler ,name ((instr (_ _ q)))
         (let ((m ,(if prefix-quil
                       `(m* ,postfix-matrix (gate-matrix instr) ,prefix-matrix)
                       `(gate-matrix instr))))
           (multiple-value-bind (,u0 ,u1 ,v0 ,v1 ,angles) (magicl:lapack-csd m 1 1)
             (list (build-gate ,outer-gate `(,(* ,outer-prefactor
                                                 (- (phase (magicl:ref ,v1 0 0))
                                                    (phase (magicl:ref ,v0 0 0)))))
                               q)
                   (build-gate ,inner-gate `(,(* ,inner-prefactor 2 (first ,angles)))
                               q)
                   (build-gate ,outer-gate `(,(* ,outer-prefactor
                                                 (- (phase (magicl:ref ,u1 0 0))
                                                    (phase (magicl:ref ,u0 0 0)))))
                               q))))))))

(define-euler-compiler euler-YXY-compiler
    :outer-gate "RY"
    :inner-gate "RX"
    :prefix-quil (list (build-gate "RX" `(,(/ pi -2)) 0)
                       (build-gate "RY" `(,(/ pi -2)) 0)))

(define-euler-compiler euler-ZXZ-compiler
    :outer-gate "RZ"
    :inner-gate "RX"
    :prefix-quil (list (build-gate "RZ" `(,(/ pi -2)) 0)))

(define-euler-compiler euler-XYX-compiler
    :outer-gate "RX"
    :inner-gate "RY"
    :outer-prefactor -1
    :prefix-quil (list (build-gate "RY" `(,(/ pi -2)) 0)))

(define-euler-compiler euler-XZX-compiler
    :outer-gate "RX"
    :inner-gate "RZ"
    :outer-prefactor -1
    :inner-prefactor -1
    :prefix-quil (list (build-gate "RY" `(,(/ pi -2)) 0)
                       (build-gate "RX" `(,(/ pi -2)) 0)))

(define-euler-compiler euler-YZY-compiler
    :outer-gate "RY"
    :inner-gate "RZ"
    :inner-prefactor -1
    :prefix-quil (list (build-gate "RX" `(,(/ pi -2)) 0)))

(define-euler-compiler euler-ZYZ-compiler
    :outer-gate "RZ"
    :inner-gate "RY"
    :prefix-quil ())
