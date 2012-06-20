#lang racket
(require "parameter.rkt")
(require syntax/srcloc)
 
;;;
;;; NOTES: 
;;;   Changes from planet version:  ]] (CDB) Bug fixed
;;;   Strings are supported. 
;;;   Assignments changed from set! to define.
;;;   Assignment of functions.
;;;   Bug fix:  identifiers with more than one _ wasn't converted correctly

; <e> =   <num>
;      |  <string>
;      |  <id>                   variable reference
;      |  <e> [ <args> ]         application
;      |  { <args> }             list construction
;      |  <e> + <e>              addition
;      |  <e> - <e>              subtraction
;      |  <e> * <e>              multiplication
;      |  <e> / <e>              division
;      |  <e> ^ <e>              exponentiation
;      |  - <e>                  negation
;      | ( <e> )                 grouping
;      | <id> ( <args> ) := <e>  function definition


; <id>   An identifier begins with a letter, 
;        and is optionally followed by series of letters, digits or underscores.
;        An underscore is converted to a -. Thus list_ref will refer to list-ref.

; <num>  A number is an non-empty series of digits, 
;        optionally followed by a period followed by a series of digits.

; <string> A number is a " followed by a series of non-" characters followed by a " .

(provide parse-expression)

(require parser-tools/yacc
         parser-tools/lex
         (prefix-in : parser-tools/lex-sre)
         syntax/readerr)

(define-tokens value-tokens (NUMBER STRING IDENTIFIER IDENTIFIEROP IDENTIFIER:=))
(define-empty-tokens 
  op-tokens 
  (newline 
   := 
   OP CP    ; ( ) 
   CP:=     ; ):=
   OB CB    ; [ ]
   OC CC    ; { }
   ODB      ; [[ ]]
   COMMA    ; ,
   SEMI     ; ;
   PERIOD   ; .
   LAMBDA   ; lambda or λ
   SQRT     ; √ 
   NEG      ; ¬  (logical negation)
   LESS-EQUAL    ; <= or ≤
   GREATER-EQUAL ; >= or ≥
   NOT-EQUAL     ; <> or ≠
   = < >
   + - * / ^ 
   DEFINE
   EOF))

(define-lex-abbrevs
  [letter       (:or (:/ "a" "z") (:/ #\A #\Z) )]
  [digit        (:/ #\0 #\9)]
  [string       (:: #\" (:* (:~ #\")) #\")]
  [identifier   (:: letter (:* (:or letter digit #\_ #\?)))]
  [identifier:= (:: letter (:* (:or letter digit #\_ #\?)) ":=")]
  [identifierOP (:: letter (:* (:or letter digit #\_ #\?)) "(")])

(define (string-drop-right n s)
  (substring s 0 (- (string-length s) n)))

(define expression-lexer
  (lexer-src-pos
   [(eof) 'EOF]
   [(:or #\tab #\space #\newline)    ; this skips whitespace
    (return-without-pos (expression-lexer input-port))] 
   [#\newline (token-newline)]  ; (token-newline) returns 'newline
   [(:or ":=" "+" "-" "*" "/" "^" "<" ">" "=" "\"") (string->symbol lexeme)] 
   ["(" 'OP]
   [")" 'CP]
   ["[" 'OB]
   ["]" 'CB]
   ["{" 'OC]
   ["}" 'CC]
   ["[[" 'ODB]
   ; ["]]" 'CDB]
   ["," 'COMMA]   
   [";" 'SEMI]
   ["." 'PERIOD]
   [#\λ 'LAMBDA]
   ["lambda" 'LAMBDA]
   ["√" 'SQRT]
   ["¬" 'NEG]
   ["≤" 'LESS-EQUAL]
   ["<=" 'LESS-EQUAL]
   ["≥" 'GREATER-EQUAL]
   [">=" 'GREATER-EQUAL]
   ["<>" 'NOT-EQUAL]
   ["≠" 'NOT-EQUAL]
   ["define" 'DEFINE]
   [string 
    (token-STRING (substring lexeme 1 (- (string-length lexeme) 1)))]
   ; The parser can only look ahead 1 token, so we have 3 
   ; different identifiers to see whether := or ( comes after the identfier.
   ; This is enough to prevent shift/reduce conflicts between atom, definition,
   ; and application.
   [identifier:= 
    (token-IDENTIFIER:= 
     (string->symbol (string-drop-right 2 (regexp-replace* #rx"_" lexeme "-"))))]
   [identifierOP 
    (token-IDENTIFIEROP 
     (string->symbol (string-drop-right 1 (regexp-replace* #rx"_" lexeme "-"))))]
   [identifier 
    (token-IDENTIFIER (string->symbol (regexp-replace* #rx"_" lexeme "-")))]
   [(:+ digit) (token-NUMBER (string->number lexeme))]
   [(:: (:+ digit) #\. (:* digit)) (token-NUMBER (string->number lexeme))]))


;; A macro to build the syntax object
(define-syntax (b stx)
  (syntax-case stx ()
    [(_ o value start end)
     #'(b o value start end 0 0)]
    [(_ o value start end start-adjust end-adjust)
     (with-syntax 
         ((start-pos (datum->syntax #'start
                                    (string->symbol 
                                     (format "$~a-start-pos"
                                             (syntax->datum #'start)))))
          (end-pos (datum->syntax #'end
                                  (string->symbol 
                                   (format "$~a-end-pos" 
                                           (syntax->datum #'end))))))
       #`(datum->syntax 
          o
          value
          (list (if (syntax? o) (syntax-source o) 'missing-in-action--sorry)
                (if (and o (syntax-line o)) 
                    (+ (syntax-line o) (position-line start-pos) start-adjust -1) #f)
                (if (and o (syntax-column o))
                    (+ (syntax-column o) (position-offset start-pos) start-adjust) #f)
                (if (and o (syntax-position o))
                    (+ (syntax-position o) (- (position-offset start-pos) start-adjust 1)) #f)
                (- (+ (position-offset end-pos) end-adjust)
                   (+ (position-offset start-pos) start-adjust)))
          o o))]))

; for testing: builds lists instead of syntax objects
#;(define-syntax (b stx)
    (syntax-case stx ()
      [(_ _ val _ _)
       #'val]))

(define (display-position-token pos)
  (display (position->list pos)))

(define (position->list pos)
  (list (position-offset pos)
        (position-line pos)
        (position-col pos)))


(define (expression-parser source-name orig-stx)
  (define o orig-stx)
  (parser
   (src-pos)
   ; (suppress)  ; hmm...
   ;(debug "parser-dump.txt")
   ;(yacc-output "parser-dump.yacc")
   (start start)
   (end newline EOF)
   (tokens value-tokens op-tokens)
   (error (lambda (token-ok? name val start end)
            ; The first argument will be #f if and only if the error is that an invalid token was received. 
            ; The second and third arguments will be the name and the value of the token at which the error was detected. 
            ; The fourth and fifth arguments, if present, provide the source positions of that token.
            #;(unless #f #; (string? (syntax->datum o))
                (display "DEBUGXXX: ")
                (display (list o token-ok? name val start end))
                (display-position-token start) (newline)
                (display-position-token end) (newline)
                (displayln source-name)
                (newline))
            (error-print-source-location #t)
            (displayln "Syntax error")
            (raise-read-error 
             "Syntax error"
             source-name
             (position-line start)
             (position-col start)
             (position-offset start)
             (+ (- (position-offset end) (position-offset start))))
            #;(raise-syntax-error
               #f
               "syntax error"
               (datum->syntax 
                #'here 'here
                (list 
                 source-name 
                 (position-line start)
                 (position-col start)
                 (position-offset start)
                 (+ (- (position-offset end) (position-offset start))))))))
   
   (precs ; (left :=)
          ; (right OP)          
          (left - +)
          (left * /)
          (right OB)
          (right ^)
          (left =)  ; comparisons
          (right NEG)
          (left SEMI)
          ; (right IDENTIFIER)
          )
   
   (grammar    
    (start [(exp) (b o `(#%infix ,$1) 1 1)] 
           [() #f]) 
    ;; If there is an error, ignore everything before the error
    ;; and try to start over right after the error        
    
    (args [(exp)            (b o (list $1) 1 1)]
          [(exp COMMA args) (b o (cons $1 $3) 1 3)]
          [() '()])
    
    (ids [()               '()]
         [(IDENTIFIER ids) (b o (cons $1 $2) 1 2)])
        
    (parenthensis-exp
     [(OP exp CP)                                   $2])
    
    (atom 
     [(NUMBER)                                      (b o $1 1 1)]
     [(IDENTIFIER)                (prec IDENTIFIER) (b o $1 1 1)]
     [(STRING)                                      (b o $1 1 1)]
     [(parenthensis-exp)                            $1])
    
    (construction-exp
     [(OC args CC)                                  (b o `(,(b o 'list 1 3) ,@$2) 1 3)]         
     [(OP LAMBDA ids PERIOD exp CP)                 (b o `(,(b o 'lambda 2 2) ,$3 ,$5) 1 6)]
     [(atom)                                        $1])
    
    (application-exp
     ;[(application-exp OB args CB)                 (b o `(,$1 ,@$3) 1 4)]                     ; function application
     ; Due the extra ( in IDENTIFIEROP we need to adjust the end with -1.
     [(IDENTIFIEROP args CP)                        (b o `(,(b o $1 1 1 0 -1) ,@$2) 1 3)]      ; function application
     [(application-exp OP args CP)      (prec OP)   (b o `(,$1 ,@$3) 1 4 )]                    ; function application
     [(application-exp ODB exp CB CB)               (b o `(,(b o 'list-ref 1 4) ,$1 ,$3) 1 4)] ; list ref
     [(construction-exp)                            $1])
    

    #;(implicit-exp
       [(application-exp application-exp) (prec *)  (b o `(,(b o '* 1 2) ,$1 ,$2) 1 2)]    ; implicit
       [(application-exp)                           $1])
    
    (power-exp 
     [(application-exp ^ power-exp) (prec ^)        (b o `(expt ,$1 ,$3) 1 3)]
     [(application-exp)                             $1])
    
    (sqrt-exp
     [(SQRT sqrt-exp)                               (b o `(,(b o 'sqrt 1 1) ,$2) 1 2)]
     [(power-exp)                                   $1])
    
    (negation-exp 
     [(- negation-exp)                              (b o `(,(b o '- 1 1) ,$2) 1 2)]
     [(sqrt-exp)                                    $1])
    
    (multiplication-exp
     [(multiplication-exp * negation-exp) (prec *)  (b o `(,(b o '* 2 2) ,$1 ,$3) 1 3)]
     [(multiplication-exp / negation-exp) (prec /)  (b o `(,(b o '/ 2 2) ,$1 ,$3) 1 3)]
     ;[(multiplication-exp  negation-exp) (prec *)  (b o `(,(b o '* 1 2) ,$1 ,$2) 1 2)]
     [(negation-exp)                                $1])
     
    (addition-exp
     [(addition-exp - multiplication-exp) (prec -)  (b o `(,(b o '- 2 2) ,$1 ,$3) 1 3)]
     [(addition-exp + multiplication-exp) (prec +)  (b o `(,(b o '+ 2 2) ,$1 ,$3) 1 3)]
     [(multiplication-exp)                          $1])
    
    (order-exp
     [(addition-exp LESS-EQUAL addition-exp)    (prec =)  (b o `(,(b o '<= 2 2) ,$1 ,$3) 1 3)]
     [(addition-exp < addition-exp)             (prec =)  (b o `(,(b o '< 2 2) ,$1 ,$3) 1 3)]
     [(addition-exp GREATER-EQUAL addition-exp) (prec =)  (b o `(,(b o '>= 2 2) ,$1 ,$3) 1 3)]
     [(addition-exp > addition-exp)             (prec =)  (b o `(,(b o '> 2 2) ,$1 ,$3) 1 3)]
     [(addition-exp NOT-EQUAL addition-exp)     (prec =)  (b o `(not (,(b o '= 2 2) ,$1 ,$3)) 1 3)]
     [(addition-exp = addition-exp)             (prec =)  (b o `(,(b o '= 2 2) ,$1 ,$3) 1 3)]
     [(addition-exp)                            $1])
    
    (logical-negation-exp
     [(NEG logical-negation-exp)   (prec NEG)      (b o `(,(b o 'not 1 1) ,$2) 1 2)]
     [(order-exp)                                  $1])
    
    ; The no DEFINE version conflicts with application.
    ; Solution? Move definition with := into rule for application.
    (assignment-exp
     ;[(DEFINE IDENTIFIER := assignment-exp)               (b o `(,(b o 'define 3 3) ,$2 ,$4) 2 4)]
     ;[(DEFINE IDENTIFIER OP args CP := assignment-exp)    (b o `(,(b o 'define 4 4) (,$2 ,@$4) ,$7) 2 6)]
     [(IDENTIFIER:= assignment-exp)                  (b o `(,(b o 'define 1 1) 
                                                            ,(b o $1 1 1 
                                                                ; adjust end with -2 due to the chars in :=
                                                                0 -2)
                                                            ,(b o $2 2 2)) 1 2)]
     [(IDENTIFIEROP args CP := assignment-exp)       (b o `(,(b o 'define 2 2) (,$1 ,@$2) ,$5) 1 5)]
     [(logical-negation-exp)                          $1])
    
    (compound-exp 
     [(compound-exp SEMI assignment-exp)            (b o `(,(b o 'begin 2 2) ,$1 ,$3) 1 3)]
     [(assignment-exp)                              $1])
     
    (exp 
     [(compound-exp)                                $1]))))

(define (parse-expression src stx ip)
  (port-count-lines! ip)
  ((expression-parser 
    src 
    ; If you change any of these values, then
    ; you must change the builder b which uses
    ; the the values in here to add to newly read
    ; objects. If the lexer/parser was only to
    ; read from entire files, there would be no problem,
    ; but sometimes one must read from strings 
    ; entered in a repl. There the syntax-objects must be 
    ; adjusted.
    (datum->syntax #f
                   'here
                   (list src
                         1   ; line 1
                         0   ; column 0
                         1   ; offset/position 1 (contract for datum->syntax requires a positive offset)
                         #f) ; span
                   )) ; no properties
   ; The following Tom Foolery is to needed to turn
   ;   SEMI EOF into EOF
   ; This allows one to have an optional semi colon in the end of the file.   
   (let ([peek  (expression-lexer ip)]
         [peek1 (expression-lexer ip)])
     (define (next)
       (cond
         [(eq? (position-token-token peek) 'EOF) (void)]
         [else (set! peek peek1)
               (set! peek1 (expression-lexer ip))]))
     (λ ()
       (if (and (eq? (position-token-token peek) 'SEMI)
                (eq? (position-token-token peek1) 'EOF))
           (begin0 peek1 (next))
           (begin0 peek  (next)))))))