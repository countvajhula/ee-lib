#lang racket/base

(require 
  racket/syntax
  syntax/parse
  syntax/parse/define
  racket/private/check

  syntax/id-table
  (for-template "private/lift-disappeareds.rkt")
  (for-syntax
   racket/base
   syntax/parse
   (only-in syntax/parse [define/syntax-parse def/stx]))
  (for-template racket/base)

  "private/binding.rkt"
  "private/flip-intro-scope.rkt"
  "persistent-id-table.rkt")

(provide
 flip-intro-scope
 same-binding?

 qstx/rc ; read as quasisyntax/loc+props
 qstx/lp
 stx/lp

 bind!
 racket-var
 racket-var?
 with-scope
 add-scope
 splice-from-scope
 add-scopes
 lookup
 apply-as-transformer

 define/hygienic
 define/hygienic-metafunction
 wrap-hygiene

 call-in-expression-context
 
 current-def-ctx
 current-ctx-id

 eval-transformer

 map-transform
 syntax-local-introduce-splice

 compiled-ids
 compile-binder!
 compile-binders!
 compile-reference
 compiled-from

 define-persistent-symbol-table
 define-local-symbol-table
 
 symbol-table-set!
 symbol-table-ref

 in-space

 module-macro
 non-module-begin-macro
 expression-macro
 definition-macro
 )

;; TODO / bug: when the template is just a reference to a pattern variable,
;; these change the source location and properties on the result.
(define-syntax (qstx/lp stx)
  (syntax-case stx ()
    [(_ arg template)
     #`(let ([orig arg]
             [stx (quasisyntax template)])
         (datum->syntax stx
                        (syntax-e stx)
                        orig orig))]))

(define-syntax (stx/lp stx)
  (syntax-case stx ()
    [(_ arg template)
     #`(let ([orig arg]
             [stx (syntax template)])
         (datum->syntax stx
                        (syntax-e stx)
                        orig orig))]))

(define-syntax (qstx/rc stx)
  (syntax-case stx ()
    [(_ template)
     #`(datum->syntax (quote-syntax #,stx)
                      (syntax-e (quasisyntax template))
                      this-syntax this-syntax)]))


(define current-def-ctx (make-parameter #f))
(define current-ctx-id (make-parameter #f))

(define (call-with-scope p)
  (let* ([ctx (syntax-local-make-definition-context (current-def-ctx))])
    (parameterize ([current-def-ctx ctx]
                   [current-ctx-id (gensym 'with-scope-ctx)])
      (p ctx))))

(define-simple-macro
  (with-scope name:id body ...)
  (call-with-scope (lambda (name) body ...)))

(define/who (add-scope stx sc)
  (check who syntax? stx)
  (check who internal-definition-context? sc)
  
  (internal-definition-context-add-scopes sc stx))

(define/who (add-scopes stx scs)
  (check who syntax? stx)
  (check who (lambda (v) (and (list? v) (andmap internal-definition-context? v)))
         #:contract "(listof internal-definition-context?)"
         scs)
  
  (for/fold ([stx stx])
            ([sc scs])
    (internal-definition-context-add-scopes sc stx)))

(define/who (splice-from-scope id sc)
  (check who identifier? id)
  (check who internal-definition-context? sc)
  
  (internal-definition-context-splice-binding-identifier sc id))

(define (add-ctx-scope ctx stx)
  (if ctx
      (internal-definition-context-introduce ctx stx 'add)
      stx))

(struct racket-var [])

(define/who (bind! id rhs-arg #:space [binding-space #f])
  (check who (lambda (v) (or (identifier? v) (and (list? v) (andmap identifier? v))))
         #:contract "(or/c identifier? (listof identifier?))"
         id)
  (check who symbol? #:or-false binding-space)

  (unless (current-ctx-id)
    (error 'bind!
           "cannot bind outside of dynamic extent of with-scope"))
  (unless (current-def-ctx)
    (error 'bind!
           "cannot bind in outer scope from an expression context"))
  (when (not rhs-arg)
    (error 'bind! "environment value must not be #f"))

  (define rhs
    (if (syntax? rhs-arg)
        rhs-arg
        (if (racket-var? rhs-arg)
            #f
            #`'#,rhs-arg)))

  ;; Adjust scopes manually rather than use the result of syntax-local-bind-syntaxes
  ;; so that we can check that the names are not already bound.
  (define ids-in-sc (for/list ([id (if (list? id) id (list id))])
                      ((in-space binding-space)
                       (syntax-local-identifier-as-binding
                        (internal-definition-context-introduce (current-def-ctx) id 'add)
                        (current-def-ctx)))))
  (check-not-bound ids-in-sc (current-def-ctx))
  
  (syntax-local-bind-syntaxes
   ids-in-sc
   rhs
   (current-def-ctx))

  (define ids-with-prop
    (for/list ([id ids-in-sc])
      (syntax-property id 'binder #t)))

  (apply lift-disappeared-bindings! ids-with-prop)
  (if (list? id) ids-with-prop (car ids-with-prop)))

(define (check-not-bound ids def-ctx)
  ;; internal-definition-context-binding-identifiers returns ids in positive space.
  ;; Flip to negative to compare.
  (define ctx-bound-ids
    (map flip-intro-scope
         (internal-definition-context-binding-identifiers def-ctx)))
  
  (for ([id ids])
    (when (member id ctx-bound-ids bound-identifier=?)
      (wrong-syntax id "identifier already defined"))))

(define/who (eval-transformer stx)
  (check who syntax? stx)
  
  (syntax-local-eval stx (or (current-def-ctx) '())))

; used only for eq? equality.
(define unbound
  (let ()
    (struct unbound [])
    (unbound)))

(define/who (lookup id [predicate (lambda (v) #t)] #:space [binding-space #f])
  (check who identifier? id)
  (check who procedure? predicate)
  (check who symbol? #:or-false binding-space)
  
  (define id-in-sc ((in-space binding-space) (add-ctx-scope (current-def-ctx) id)))

  (define result
    (syntax-local-value
     id-in-sc
     (lambda () unbound)
     (current-def-ctx)))

  (when (eq? result unbound)
    (maybe-raise-ambiguity-error id-in-sc))

  (if (and (not (eq? result unbound)) (predicate result))
      (begin
        (lift-disappeared-uses! id-in-sc)
        result)
      #f))

(define/who (syntax-local-introduce-splice stx)
  (check who identifier? stx)
  
  (syntax-local-identifier-as-binding
   (syntax-local-introduce stx)
   (current-def-ctx)))

(define/who (apply-as-transformer f f-id ctx-type-arg . args)
  (check who procedure? f)
  (check who (lambda (v) (or (identifier? v) (not v)))
         #:contract "(or/c identifier? #f)"
         f-id)
  (check who (lambda (v) (member v '(expression definition)))
         #:contract "(or/c 'expression 'definition)"
         ctx-type-arg)

  (apply-with-hygiene f f-id ctx-type-arg #t args))

(define (syntax-local-apply-transformer-use-site-workaround
         f f-id ctx-type def-ctx . args)
  (define (maybe-flip v)
    (if (syntax? v) (flip-intro-scope v) v))
  (if (eq? ctx-type 'expression)
      ; Expand as a definition first to get a use-site scope, as a workaround for
      ; https://github.com/racket/racket/pull/2237
      (let ([f-id^ (maybe-flip f-id)])
        (apply syntax-local-apply-transformer
               (lambda args
                 (apply syntax-local-apply-transformer f (maybe-flip f-id^) 'expression def-ctx args))
               f-id (list (gensym)) def-ctx args))
      (apply syntax-local-apply-transformer f f-id ctx-type def-ctx args)))

(define (apply-with-hygiene f f-id ctx-type seal? args)
  (define def-ctx (current-def-ctx))
  (parameterize ([current-def-ctx (if seal? #f (current-def-ctx))])
    (apply syntax-local-apply-transformer-use-site-workaround
           f
           f-id
           (case ctx-type
             [(expression) 'expression]
             [(definition) (list (current-ctx-id))])
           def-ctx
           args)))

(define/who (wrap-hygiene f ctx-type)
  (check who procedure? f)
  (check who (lambda (v) (or (eq? v 'expression) (eq? v 'definition)))
         #:contract "(or/c 'expression 'definition)"
         ctx-type)
  
  (lambda args
    ; Hack: Provide a name from racket/base (which we require for-template)
    ; as binding-id to avoid creation of use-site scopes for define/hygienic.
    ;
    ; We don't need use-site scopes here because we know that *all*
    ; invocations of define/hygienic generate syntax with unique scopes,
    ; so syntax from a use (that is, one invocation) can't bind syntax
    ; from another invocation.
    ;
    ; Interface macros also generate syntax with unique scopes, so we don't
    ; have to worry about use-site binders from those entry points either.
    (apply-with-hygiene f #'car ctx-type (eq? ctx-type 'expression) args)))

(define (call-in-expression-context f)
  (define result (void))
  ((wrap-hygiene
    (lambda ()
      (set! result (f)))
    'expression))
  result)

(begin-for-syntax
  (define-syntax-class ctx-type
    (pattern #:expression
      #:attr type #''expression)
    (pattern #:definition
      #:attr type #''definition)))

(define-syntax define/hygienic
  (syntax-parser
    [(_ (name:id arg:id ...) ctx:ctx-type
        body ...+)
     #'(define name
         (wrap-hygiene
          (lambda (arg ...)
            body ...)
          ctx.type))]))

; Convenient for cmdline-ee case study
(require syntax/parse/experimental/template)
(provide define/hygienic-metafunction)
(define-syntax define/hygienic-metafunction
  (syntax-parser
    [(_ (name:id arg:id) ctx:ctx-type
        body ...)
     #'(define-template-metafunction name
         (wrap-hygienic
          (lambda (arg) body ...)
          ctx.type))]))

; Applies the function f to each element of the tree, starting
; from the leaves. For nodes wrapped as a syntax object, the function
; is applied to the syntax object but not its immediate datum contents.
(define/who (map-transform f stx)
  (check who procedure? f)
  
  (define (recur stx)
    (cond
      [(syntax? stx)
       (let ([e (syntax-e stx)])
         (datum->syntax stx (recur e) stx stx))]
      [(pair? stx)
       (cons
        (map-transform f (car stx))
        (map-transform f (cdr stx)))]
      ; TODO: handle vectors and other composite data that may appear in syntax
      [else stx]))
  (f (recur stx)))

(module get-module-inside-edge racket/base
  (provide get-module-inside-edge-m)
  (require (for-syntax racket/base))
  (define-syntax (get-module-inside-edge-m stx)
    #`(quote-syntax
       #,(syntax-local-introduce
          (datum->syntax #f 'get-module-inside-edge-introducer/id)))))

(require 'get-module-inside-edge)

(define (get-module-inside-edge-introducer)
  (make-syntax-delta-introducer
   (syntax-parse (expand-syntax #'(get-module-inside-edge-m))
     [(quote-syntax id) #'id])
   (datum->syntax #f 'get-module-inside-edge-introducer/id)))

(define (syntax-local-get-shadower/including-module id)
  ((get-module-inside-edge-introducer)
   (syntax-local-get-shadower id)
   'add))

(define/who (generate-same-name-temporary id)
  (check who identifier? id)
  ((make-syntax-introducer) (datum->syntax #f (syntax-e id) id id)))


(define-persistent-free-id-table compiled-ids)

(define (table-ref table id fail)
  (if (persistent-free-id-table? table)
        (persistent-free-id-table-ref
         table
         (flip-intro-scope id)
         fail)
        (free-id-table-ref
         table
         (flip-intro-scope id)
         fail)))

(define (table-set! table id val)
  (if (persistent-free-id-table? table)
      (persistent-free-id-table-set! table (flip-intro-scope id) val)
      (free-id-table-set! table
                          (flip-intro-scope id)
                          val)))

(define/who (compile-binder! id #:table [table compiled-ids] #:reuse? [reuse? #f])
  (check who (lambda (v) (or (mutable-free-id-table? v) (persistent-free-id-table? v)))
         #:contract "(or/c mutable-free-id-table? persistent-free-id-table?)"
         table)
  (check who identifier? id)
  (check who boolean? reuse?)

  (define ref-result (table-ref table id #f))

  (define renamed
    (if ref-result
        (if reuse?
            (flip-intro-scope ref-result)
            (error 'compile-binder! "compiled binder already recorded for identifier ~v" id))
        (let ([result (generate-same-name-temporary id)])
          (table-set! table id result)
          (flip-intro-scope result))))

  (with-compiled-from renamed (flip-intro-scope id)))

(define (compile-binders! ids #:table [table compiled-ids] #:reuse? [reuse? #f])
  (map (lambda (id) (compile-binder! id #:table table #:reuse? reuse?))
       (if (syntax? ids)
           (syntax->list ids)
           ids)))

(define/who (compile-reference id #:table [table compiled-ids])
  (check who (lambda (v) (or (mutable-free-id-table? v) (persistent-free-id-table? v)))
         #:contract "(or/c mutable-free-id-table? persistent-free-id-table?)"
         table)
  (check who identifier? id)

  (define table-val
    (table-ref table id (lambda () (error 'compile-reference "no compiled name in table for ~v" id))))
  
  (define renamed
    (syntax-local-get-shadower/including-module
     (flip-intro-scope
      table-val)))

  (with-compiled-from renamed (flip-intro-scope id)))

(define (with-compiled-from new-id old-id)
  (syntax-property new-id 'compiled-from old-id #t))

(define/who (compiled-from id)
  (define prop (syntax-property id 'compiled-from))
  (when (not prop)
    (raise-syntax-error 'compiled-from "not a compiled identifier" id))
  (flip-intro-scope prop))

(define-syntax-rule
  (define-persistent-symbol-table id)
  (define-persistent-free-id-table id))

(define-syntax-rule
  (define-local-symbol-table id)
  (define id (make-free-id-table)))

(define/who (symbol-table-set! t id val)
  (check who (lambda (v) (or (mutable-free-id-table? v) (persistent-free-id-table? v)))
         #:contract "(or/c mutable-free-id-table? persistent-free-id-table?)"
         t)
  
  (when (and (free-id-table? t) (module-or-top-binding? (compiled-from id)))
    (error who "local symbol tables cannot store information about module-level bindings"))

  (when (not (eq? unbound (symbol-table-ref t id unbound)))
    (error who "table already has an entry for key"))
  
  (table-set! t (compiled-from id) val))

(define (symbol-table-ref-error)
  (error 'symbol-table-ref "no value found for key"))

(define/who (symbol-table-ref t id [fail symbol-table-ref-error])
  (check who (lambda (v) (or (free-id-table? v) (persistent-free-id-table? v)))
         #:contract "(or/c free-id-table? persistent-free-id-table?)"
         t)
  
  (table-ref t (compiled-from id) fail))

(define/who (in-space binding-space)
  (check who symbol? #:or-false binding-space)
  
  (lambda (stx)
    (check who syntax? stx)
    
    (if binding-space
        ((make-interned-syntax-introducer binding-space) stx 'add)
        stx)))

(define/who (module-macro t)
  (check who procedure? t)
  
  (lambda (stx)
    (case (syntax-local-context)
      [(module-begin) #`(begin #,stx)]
      [(module) (t stx)]
      [else (raise-syntax-error #f "Only allowed in module context" stx)])))

(define/who (non-module-begin-macro t)
  (lambda (stx)
    (check who procedure? t)
    
    (case (syntax-local-context)
      [(module-begin) #`(begin #,stx)]
      [else (t stx)])))

(define/who (definition-macro t)
  (check who procedure? t)
  
  (lambda (stx)
    (case (syntax-local-context)
      [(module-begin) #`(begin #,stx)]
      [(expression) (raise-syntax-error #f "only allowed in a definition context" stx)]
      [else (t stx)])))

(define/who (expression-macro t)
  (check who procedure? t)
  
  (lambda (stx)
    (case (syntax-local-context)
      [(expression) (t stx)]
      [else #`(#%expression #,stx)])))
