(in-package :wookie)

(define-condition use-next-route () ()
  (:documentation
    "Signals to the routing system to load the next route after the one loaded.
     can be used to set up route load chains based on criteria not sent directly
     to find-route."))

(define-condition route-error (wookie-error)
  ((resource :initarg :resource :reader route-error-resource :initform nil))
  (:report (lambda (c s) (format s "Routing error: ~s" (route-error-resource c))))
  (:documentation "Describes a general routing error."))

(define-condition route-not-found (route-error) ()
  (:report (lambda (c s) (format s "Routing error: route not found for ~s" (route-error-resource c))))
  (:documentation "Describes a route not found error."))

(defvar *default-vhost* nil
  "Defines the default virtualhost that routes use (unless explicitely stated
   otherwise). Nil means no vhost (respond to all requests).")

(defun clear-routes ()
  "Clear out all routes."
  (wlog :debug "(route) Clearing routes~%")
  (setf (wookie-state-routes *state*) (make-array 0 :adjustable t :fill-pointer t)))

(defun make-route (method resource fn &key regex case-sensitive allow-chunking buffer-body suppress-100 vhost)
  "Simple wrapper to make a route object from a set of args."
  (let ((scanner (if regex
                     (cl-ppcre:create-scanner
                       (concatenate 'string "^" resource "$")
                       :case-insensitive-mode (not case-sensitive))
                     resource)))
    (list :method method
          :resource scanner
          :fn fn
          :regex regex
          :allow-chunking allow-chunking
          :buffer-body buffer-body
          :suppress-100 suppress-100
          :resource-str resource
          :vhost vhost)))

(defun next-route ()
  "Lets the routing system know to re-route the current request, excluding this
   route from the available options."
  (error 'use-next-route))

(defun find-route (method resource &key exclude host)
  "Given a method and a resource, find the best matching route."
  (loop for route across (wookie-state-routes *state*) do
    ;; don't load excluded routes
    (unless (find-if (lambda (ex)
                       (eq (getf ex :fn) (getf route :fn)))
                     exclude)
      (when (and (let ((route-method (getf route :method)))
                   ;; test for a list of methods as well as exact method match.
                   ;; also allow wildcard method match via :*
                   (if (listp route-method)
                       (find method route-method)
                       (or (eq method route-method)
                           (eq :* route-method))))
                 (or (not (getf route :vhost))
                     ;; either exact match the host or match without portnum
                     (or (equal (getf route :vhost) host)
                         (when (stringp host)
                           (equal (getf route :vhost)
                                  (subseq host 0 (position #\: host)))))))
        (multiple-value-bind (matchedp matches)
            (if (getf route :regex)
                (cl-ppcre:scan-to-strings (getf route :resource) resource)
                (string= (getf route :resource) resource))
          (when matchedp
            (let* ((fn (getf route :fn))
                   (curried-fn (lambda (request response)
                                 (apply fn (append (list request response)
                                                   (coerce matches 'list))))))
              (setf (getf route :curried-route) curried-fn)
              (return-from find-route route))))))))

(defun add-route (new-route)
  "Add a new route to the table."
  (vector-push-extend new-route (wookie-state-routes *state*))
  (length (wookie-state-routes *state*)))

(defun upsert-route (new-route)
  "Add a new route to the table. If a route already exists with the same method
   and resource string, it is replaced with the new one in the same position the 
   old route existed in (as to preserve routing order)."
  (let ((route-found nil)
        (resource-str (getf new-route :resource-str) )
        (method (getf new-route :method)))
    (unless (zerop (length (wookie-state-routes *state*)))
      (loop for i from 0
            for route across (wookie-state-routes *state*) do
        (when (and (eq (getf route :method) method)
                   (string= (getf route :resource-str) resource-str))
          (setf (aref (wookie-state-routes *state*) i) route
                route-found t)
          (return))))
    (unless route-found
      (vector-push-extend new-route (wookie-state-routes *state*)))
    (length (wookie-state-routes *state*))))

(defun clear-route (method resource-str)
  "Clear out a route in the routing table."
  (wlog :debug "(route) Clear route ~s~%" resource-str)
  (let ((new-routes (delete-if
                      (lambda (route)
                        (and (eq (getf route :method) method)
                             (string= (getf route :resource-str) resource-str)))
                      (wookie-state-routes *state*))))
    (setf (wookie-state-routes *state*) new-routes)))

(defmacro defroute ((method resource &key (regex t) (case-sensitive t) chunk buffer-body suppress-100 (replace t) (vhost '*default-vhost*))
                    (bind-request bind-response &optional bind-args)
                    &body body)
  "Defines a wookie route and pushes it into the route list.

     :regex specifies whether resource is a regex or not
     :chunk specifies if the route can handle chunked content
     :replace tells the routing system to upsert this resource/method set
       (instead of just blindly adding it to the end of the list like default)

   bind-request/bind-response are the variable names that the request/response
   values are bound to, and bind-args specifies that variable that regex group
   matches get sent to (a list)."
  (let* ((new-route (gensym))
         (ignore-bind-args nil)
         (bind-args (if bind-args
                        bind-args
                        (progn
                          (setf ignore-bind-args t)
                          (gensym))))
         ;; allow method to be a list of keywords
         (method (if (listp method)
                     `(list ,@method)
                     method))
         (docstring (when (stringp (car body)) (car body)))
         (body (if docstring
                   (cdr body)
                   body)))
    `(let ((,new-route (make-route ,method ,resource
                                   (lambda (,bind-request ,bind-response &rest ,bind-args)
                                     ,(or docstring "")
                                     (declare (ignorable ,bind-request))
                                     ,(when ignore-bind-args
                                        `(declare (ignore ,bind-args)))
                                     ,@body)
                                   :regex ,regex
                                   :case-sensitive ,case-sensitive
                                   :allow-chunking ,chunk
                                   :buffer-body ,buffer-body
                                   :suppress-100 ,suppress-100
                                   :vhost ,vhost)))
       (if ,replace
           (upsert-route ,new-route)
           (add-route ,new-route)))))

(defmacro with-vhost (host &body body)
  "Simple wrapper that makes all defroutes in the body bind to a specific vhost:

     (with-vhost \"omg.com\"
       (defroute ...)
       (defroute ...))"
  `(let ((*default-vhost* ,host))
     ,@body))

