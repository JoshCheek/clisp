;;; Copyright (C) 2000-2008 by Sam Steingold
;;; This file is a part of CLISP (http://clisp.cons.org), and, as such,
;;; is distributed under the GNU GPL (http://www.gnu.org/copyleft/gpl.html)

(in-package "EXT")

(export '(clhs clhs-root read-from-file browse-url open-http with-http-input
          http-proxy))

(in-package "SYSTEM")

(defvar *browsers*
  '((:netscape "netscape" "~a")
    (:netscape-window "netscape" "-remote" "openURL(~a,new-window)")
    (:netscape-tab "netscape" "-remote" "openURL(~a,new-tab)")
    (:mozilla "mozilla" "~a")
    (:mozilla-window "mozilla" "-remote" "openURL(~a,new-window)")
    (:mozilla-tab "mozilla" "-remote" "openURL(~a,new-tab)")
    (:firefox "firefox" "~a")
    (:konqueror "kfmclient" "openURL" "~a")
    (:lynx "lynx" "~a")
    #+unix (:lynx-xterm "xterm" "-e" "lynx" "~a")
    (:links "links" "~a")
    #+unix (:links-xterm "xterm" "-e" "links" "~a")
    (:w3m "w3m" "~a")
    #+unix (:w3m-xterm "xterm" "-e" "w3m" "~a")
    #+cygwin (:default "cygstart" "~a")
    #+macos (:default "open" "~a")
    (:mmm "mmm" "-external" "~a")
    (:mosaic "xmosaic" "~a")
    (:chromium "chromium-browser" "~a")
    (:conkeror "conkeror" "~a")
    (:opera "opera" "~a")
    (:emacs "emacsclient" "--eval" "(browse-url ~s)"))
  "Alist of browsers and commands that invoke them.
`~a' will be replaced with the URL to view.")
(defvar *browser* nil
  "The default browser - a key in `*browsers*' or a list of strings.")

(defun start-message (out caller file size &optional (units "bytes"))
  (when out
    (format out "~&;; ~S(~A): ~:D ~A..." caller file size units)
    (force-output (if (eq out t) *standard-output* out))))

(defun read-from-file (file &key (out *standard-output*) (package "KEYWORD")
                       repeat)
  "Read an object from a file.
The keyword argument PACKAGE specifies the package to read in.
The keyword argument OUT specifies the output for log messages.
The keyword argument REPEAT specifies how many objects to read:
 If NIL (default), read once and return the object read;
 if a number, read that many times and return a list of objects read,
 if T, read until end of file and return a list of objects read"
  (let ((beg-real (get-internal-real-time)))
    (prog1 (with-open-file (str file :direction :input)
             (start-message out 'read-from-file file (file-length str))
             (with-standard-io-syntax
               (let ((*package* (find-package package)))
                 (cond ((null repeat) (read str))
                       ((numberp repeat)
                        (loop :repeat repeat :collect (read str)))
                       (t (loop :for obj = (read str nil str)
                            :until (eq obj str) :collect obj))))))
      (when out
        (format out "done [~,2f sec]~%"
                (/ (- (get-internal-real-time) beg-real)
                   internal-time-units-per-second))))))

(defun browse-url (url &key (browser *browser*) (out *standard-output*))
  "Run the browser (a keyword in *BROWSERS* or a list) on the URL."
  #+WIN32
  (when (eq browser :default) ; feed url to ShellExecute
    (when out
      (format out "~&;; starting the default system browser with url ~s..." url)
      (force-output (if (eq out t) *standard-output* out)))
    (ext::shell-execute "open" url nil nil) ;to start default browser
    (when out (format out "done~%"))
    (return-from browse-url))
  (let* ((command
          (etypecase browser
            (list browser)
            (symbol (or (cdr (assoc browser *browsers* :test #'eq))
                        (error "unknown browser: `~s' (must be a key in `~s')"
                               browser '*browsers*)))))
         (args (mapcar (lambda (arg) (format nil arg url)) (cdr command))))
    (cond (command
           (when out
             (format out "~&;; running [~s~{ ~s~}]..." (car command) args)
             (force-output (if (eq out t) *standard-output* out)))
           (#+WIN32 ext::launch #-WIN32 run-program (car command) :arguments args :wait nil)
           (when out
             (format out "done~%")))
          (t (format t "~s: no browser specified; please point your browser at
 --> <URL:~a>~%" 'browse-url url)))))

(defvar *http-log-stream* (make-synonym-stream '*terminal-io*))
;;; keep in sync with clocc/cllib/url.lisp
(defvar *http-proxy* nil
  "A list of 3 elements (user:password host port), parsed from $http_proxy
\[http://]proxy-user:proxy-password@proxy-host:proxy-port[/]
by HTTP-PROXY.")
(defconstant *http-port* 80)
(defun http-proxy (&optional (proxy-string (getenv "http_proxy") proxy-p))
  "When the argument is supplied or *HTTP-PROXY* is NIL, parse the argument,
set *HTTP-PROXY*, and return it; otherwise just return *HTTP-PROXY*."
  (when (or proxy-p (and (null *http-proxy*) proxy-string))
    (check-type proxy-string string)
    (let* ((start (if (string-equal #1="http://" proxy-string
                                    :end2 (min (length proxy-string)
                                               #2=#.(length #1#)))
                      #2# 0))
           (at (position #\@ proxy-string :start start))
           (colon (position #\: proxy-string :start (or at start)))
           (slash (position #\/ proxy-string :start (or colon at start))))
      (setq *http-proxy*
            (list (and at (subseq proxy-string start at))
                  (subseq proxy-string (if at (1+ at) start) (or colon slash))
                  (if colon
                      (parse-integer proxy-string :start (1+ colon) :end slash)
                      *http-port*)))
      (format *http-log-stream* "~&;; ~S=~S~%" '*http-proxy* *http-proxy*)))
  *http-proxy*)

(defmacro with-http-input ((var url) &body body)
  (if (symbolp var)
      `(with-open-stream (,var (open-http ,url)) ,@body)
      (multiple-value-bind (body-rest declarations) (SYSTEM::PARSE-BODY body)
        `(multiple-value-bind ,var (open-http ,url)
           (DECLARE (READ-ONLY ,@var) ,@declarations)
           (UNWIND-PROTECT
                (MULTIPLE-VALUE-PROG1 (PROGN ,@body-rest)
                  (when ,(first var) (CLOSE ,(first var))))
             (when ,(first var) (CLOSE ,(first var) :ABORT T)))))))
(defun open-http (url &key (if-does-not-exist :error)
                  ((:log *http-log-stream*) *http-log-stream*))
  (unless (string-equal #1="http://" url
                        :end2 (min (length url) #2=#.(length #1#)))
    (error "~S: ~S is not an HTTP URL" 'open-http url))
  (format *http-log-stream* "~&;; connecting to ~S..." url)
  (force-output *http-log-stream*)
  (http-proxy)
  (let* ((host-port-end (position #\/ url :start #2#))
         (port-start (position #\: url :start #2# :end host-port-end))
         (url-host (subseq url #2# (or port-start host-port-end)))
         (host (if *http-proxy* (second *http-proxy*) url-host))
         (url-port (if port-start
                       (parse-integer url :start (1+ port-start)
                                      :end host-port-end)
                       *http-port*))
         (port (if *http-proxy* (third *http-proxy*) url-port))
         (path (if *http-proxy* url
                   (if host-port-end (subseq url host-port-end) "/")))
         (sock (handler-bind ((error (lambda (c)
                                       (unless (eq if-does-not-exist :error)
                                         (format *http-log-stream*
                                                 "cannot connect to ~S:~D: ~A~%"
                                                 host port c)
                                         (return-from open-http nil)))))
                 (socket:socket-connect port host :external-format :dos)))
         status code content-length)
    (format *http-log-stream* "connected...") (force-output *http-log-stream*)
    ;; http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.23
    ;; http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.43
    (format sock "GET ~A HTTP/1.0~%User-agent: ~A ~A~%Host: ~A:~D~%" path
            (lisp-implementation-type) (lisp-implementation-version)
            url-host url-port)
    #+unicode ; base64 requires unicode for some weird infrastructure reasons
    (when (first *http-proxy*) ; auth: http://www.ietf.org/rfc/rfc1945.txt
      ;; http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.34
      (format sock "Proxy-Authorization: Basic ~A~%"
              (convert-string-from-bytes
               (convert-string-to-bytes (first *http-proxy*)
                                        *http-encoding*)
               charset:base64)))
    ;; http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.1
    ;; http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.10
    (format sock "Accept: */*~%Connection: close~2%") ; finish request
    (write-string (setq status (read-line sock))) (force-output)
    (let* ((pos1 (position #\Space status))
           (pos2 (position #\Space status :start (1+ pos1))))
      (setq code (parse-integer status :start pos1 :end pos2)))
    (when (>= code 400)
      ;; dump headers
      (loop :for line = (read-line sock nil nil) :while line
        :do (format *http-log-stream* "~&;; ~S~%" line))
      (case if-does-not-exist
        (:error (error (TEXT "~S: error ~D: ~S") 'open-http code status))
        (t (close sock)
           (return-from open-http nil))))
    (if (>= code 300)        ; redirection
        (loop :for res = (read-line sock)
          :until (string-equal #3="Location: " res
                               :end2 (min (length res) #4=#.(length #3#)))
          :finally (let ((new-url (subseq res #4#)))
                     (format *http-log-stream* " --> ~S~%" new-url)
                     (unless (string-equal #1# new-url
                                           :end2 (min (length new-url) #2#))
                       (setq new-url (string-concat #1# host new-url)))
                     (return-from open-http (open-http new-url))))
        ;; drop response headers
        (loop :for line = (read-line sock) :while (plusp (length line)) :do
          (when (string-equal #5="Content-Length: " line
                              :end2 (min (length line) #6=#.(length #5#)))
            (format *http-log-stream* "...~:D bytes"
                    (setq content-length (parse-integer line :start #6#))))
          :finally (terpri)))
    (values sock content-length)))
(defun open-url (path &rest options &aux (len (length path)))
  (cond ((string-equal #1="http://" path :end2 (min len #.(length #1#)))
         (apply #'open-http path options))
        ((string-equal #2="file:/" path :end2 (min len #3=#.(length #2#)))
         ;; Tomas Zellerin writes in bug 1494059:
         ;; I think that proper RFC compliant URL of this kind is
         ;; file://<machine>/<path>, where machine may be the empty string
         ;; for localhost and path should be an absolute path (including
         ;; the leading slash on Unix), but browsers usually do not require
         ;; four slashes in row.
         (let ((path-beg (position #\/ path :test-not #'eql :start #3#)))
           ;; we first try stripping all leading slashes to catch things like
           ;; file:///c:/foo/bar and then resort to keeping one leading #\/
           (apply #'open (or #+(or win32 cygwin)
                             (probe-file (subseq path path-beg))
                             (subseq path (1- path-beg)))
                  options)))
        (t (open path))))

;;; the CLHS & IMPNOTES documentation:
;; * symbols (and packages for IMPNOTES) can have a doc string that points
;;   to the position of the documentation text in the CLHS or IMPNOTES.
;; * (documentation foo 'sys::clhs) and (documentation foo 'sys::impnotes)
;;   return a valid URL that can be printed or passed to the browser
;; * (setf (documentation foo 'sys::clhs) "bar") and
;;   (setf (documentation foo 'sys::impnotes) "bar")
;;   "bar" is the URL sans (clhs-root) and (impnotes-root)

(defun get-clhs-map (stream)
  "Download and install the CLHS map."
  (format *http-log-stream* "~&;; ~S(~S)..." 'get-clhs-map stream)
  (force-output *http-log-stream*)
  (loop :with good = 0 :for symbol-name = (read-line stream nil nil)
    :and destination = (read-line stream nil nil)
    :and total :upfrom 0
    :while (and symbol-name destination) :do
    (multiple-value-bind (symbol status) (find-symbol symbol-name "COMMON-LISP")
      (cond (status
             (incf good)
             (setf (documentation symbol 'sys::clhs)
                   (subseq destination #.(length "../"))))
            (t (warn (TEXT "~S is not found") symbol-name))))
    :finally (format *http-log-stream* "~:D/~:D symbol~:P~%" good total)))
(let ((clhs-map-source nil) (clhs-map-good nil))
  ;; if clhs-map-source is the same as (clhs-root), do nothing and
  ;; return (clhs-root); otherwise set clhs-map-source to (clhs-root)
  ;; and try to get the clhs map from (clhs-root)
  ;; nil return value means no map exists
(defun ensure-clhs-map ()
  "make sure that the CLHS map is present"
  (let ((clhs-root (clhs-root)))
    (when (and clhs-root (string/= clhs-map-source clhs-root))
      (setq clhs-map-source clhs-root)
      ;; there are two version of CLHS available:
      ;; cf http://www.ai.mit.edu/projects/iiip/doc/CommonLISP/HyperSpec/Data/Symbol-Table.text
      ;; vs http://www.lispworks.com/documentation/HyperSpec/Data/Map_Sym.txt
      ;; we support both.
      ;; is you are scared of the 404 errors on the screen,
      ;; bind or set *HTTP-LOG-STREAM*
      (with-open-stream (s (or (open-url (string-concat clhs-root "Data/Map_Sym.txt") :if-does-not-exist nil)
                               (open-url (string-concat clhs-root "Data/Symbol-Table.text") :if-does-not-exist nil)))
        (unless s
          (warn (TEXT "~S returns invalid value ~S, fix it, ~S, ~S, or ~S")
                'clhs-root clhs-root '(getenv "CLHSROOT")
                '*clhs-root-default* '*http-proxy*)
          (return-from ensure-clhs-map))
        (get-clhs-map s))
      (setq clhs-map-good t))
    (and clhs-map-good clhs-root))))
(defun get-string-map (stream &aux (table (make-hash-table :test 'equal)))
  (format *http-log-stream* "~&;; ~S(~S)..." 'get-string-map stream)
  (force-output *http-log-stream*)
  (loop :for total :upfrom 0 :and id = (read-line stream nil nil)
    :and destination = (read-line stream nil nil)
    :while (and id destination) :do
    (when (or (find-if #'whitespacep id) (find-if #'whitespacep destination)
              (zerop (length id)) (zerop (length destination)))
      (warn "~S: invalid map ~S --> ~S" 'get-string-map id destination)
      (return-from get-string-map nil))
    (let ((old (gethash id table)))
          (when old (warn "~S: remapping ~S: ~S --> ~S"
                          'get-string-map id old destination)))
    (setf (gethash id table) destination)
    :finally (format *http-log-stream* "~:D ID~:P~%" total))
  table)
(let ((impnotes-map-source nil) (impnotes-map-good nil) id-href
      (dest (lambda (id) (string-concat "#" id))))
  ;; if impnotes-map-source is the same as (impnotes-root), do nothing
  ;; and return (and impnotes-map-good (impnotes-root));
  ;; otherwise set impnotes-map-source to (impnotes-root) and try to get
  ;; the impnotes map from (impnotes-root)
  ;; nil return value means no map exists
(defun ensure-impnotes-map (&optional check-symbol-map)
  "make sure that the impnotes map is present"
  (let ((impnotes-root (impnotes-root)))
    (when (and impnotes-root (string/= impnotes-map-source impnotes-root))
      (setq impnotes-map-source impnotes-root)
      (case (char impnotes-root (1- (length impnotes-root)))
        ((#\/ #+win32 #\\) ; chunked impnotes ==> get id-href
         (setq id-href (string-concat impnotes-root "id-href.map"))
         (with-open-stream (s (open-url id-href :if-does-not-exist nil))
           (unless s
             #2=(warn (TEXT "~S returns invalid value ~S, fix it, ~S, ~S, or ~S")
                      'impnotes-root impnotes-root '(getenv "IMPNOTES")
                      '*impnotes-root-default* '*http-proxy*)
             (return-from ensure-impnotes-map))
           (let ((table (get-string-map s)))
             (unless table   ; no table --> bail out
               #2# (return-from ensure-impnotes-map))
             (setq dest (lambda (id) (gethash id table)))))))
      (with-open-file (in (clisp-data-file "Symbol-Table.text"))
        (format *http-log-stream* "~&;; ~S(~S)..."
                'ensure-impnotes-map (truename in))
        (force-output *http-log-stream*)
        (loop :for count :upfrom 0
          :and symbol-printname = (read-line in nil nil)
          :and id = (read-line in nil nil)
          :while (and symbol-printname id) :do
          (let ((destination (funcall dest id)))
            (if destination
                (multiple-value-bind (symbol error)
                    (ignore-errors (read-from-string symbol-printname))
                  (if (integerp error)
                    (setf (documentation symbol 'sys::impnotes)
                          destination)
                    (and check-symbol-map
                         (not (gethash symbol-printname
                                       #S(HASH-TABLE EQUALP
                                          #-(or win32 cygwin) ("CUSTOM:*DEVICE-PREFIX*" . t)
                                          #-(or win32 cygwin) ("POSIX:FILE-PROPERTIES" . t)
                                          ("CUSTOM:*DEFAULT-TIME-ZONE*" . t)
                                          ("CLOS:MAKE-METHOD-LAMBDA" . t)
                                          ("SYS::DYNLOAD-MODULES" . t))))
                         ;; *default-time-zone* sys::dynload-modules ...
                         (warn (TEXT "~S: invalid symbol ~S with id ~S: ~A")
                               'ensure-impnotes-map symbol-printname
                               id error))))
                (warn (TEXT "~S: invalid id ~S for symbol ~S")
                      'ensure-impnotes-map id symbol-printname)))
          :finally (format *http-log-stream* "~:D ID~:P~%" count)))
      (setq impnotes-map-good t)) ; success
    (and impnotes-map-good impnotes-root)))
(defmethod documentation ((obj package) (type (eql 'sys::impnotes)))
  (let ((doc (sys::package-documentation obj)))
    (and (consp doc) (ensure-impnotes-map)
         (let ((suffix (funcall dest (second doc))))
           (if suffix (string-concat (impnotes-root) suffix)
               (cerror (TEXT "Ignore") (TEXT "~S(~S): ~S does not know about ~S; the Implementation Notes must be regenerated")
                       'documentation obj id-href (second doc))))))))

(defmethod documentation ((obj symbol) (type (eql 'sys::clhs)))
  (when (and (eq (symbol-package obj) #,(find-package "CL")) (ensure-clhs-map))
    (let ((doc (call-next-method)))
      (when doc (string-concat (clhs-root) doc)))))

(defmethod documentation ((obj symbol) (type (eql 'sys::impnotes)))
  (let ((pack (symbol-package obj)))
    ;; do not search impnotes for user symbols
    (when (and pack
               (or (eq pack #,(find-package "CUSTOM"))
                   ;; CUSTOM is not in *SYSTEM-PACKAGE-LIST*
                   ;; because it must not be locked
                   (member (package-name pack) *system-package-list*
                           :test #'equal))
               (ensure-impnotes-map))
      (let ((doc (call-next-method)))
        (if doc
          (string-concat (impnotes-root) doc)
          (documentation pack 'sys::impnotes))))))

(defmethod (setf documentation) (new-value (obj package)
                                 (type (eql 'sys::impnotes)))
  (let ((doc (sys::package-documentation obj)))
    (if (consp doc)
        (setf (second doc) new-value)
        (setf (sys::package-documentation obj)
              (list "see the implementation notes" new-value)))))

;; what is the right place for these?
(setf (documentation (find-package "GRAY") 'sys::impnotes) "gray")
(setf (documentation (find-package "CL-USER") 'sys::impnotes) "clupack")
(setf (documentation (find-package "CS-CL-USER") 'sys::impnotes) "cs-clu")
(setf (documentation (find-package "CS-CL") 'sys::impnotes) "package-case")
#+screen (setf (documentation (find-package "SCREEN") 'sys::impnotes) "screen")
#+sockets (setf (documentation (find-package "SOCKET") 'sys::impnotes) "socket")
#+generic-streams
(setf (documentation (find-package "GSTREAM") 'sys::impnotes) "gstream")
(setf (documentation (find-package "I18N") 'sys::impnotes) "i18n")
#+FFI
(setf (documentation (find-package "FFI") 'sys::impnotes) "dffi")
(setf (documentation (find-package "CUSTOM") 'sys::impnotes) "customize")
#+UNICODE
(setf (documentation (find-package "CHARSET") 'sys::impnotes) "charset")
(setf (documentation (find-package "CLOS") 'sys::impnotes) "classes")
(setf (documentation (find-package "EXT") 'sys::impnotes) "ext-pac")
#+MT (setf (documentation (find-package "THREADS") 'sys::impnotes) "mt")

(defun clhs (symbol &key (browser *browser*) (out *standard-output*))
  "Dump the CLHS doc for the symbol."
  (warn "function ~S is deprecated, set ~S and use ~S instead"
        'clhs '*browser* 'describe)
  (browse-url (or (documentation symbol 'sys::clhs)
                  (error "No HyperSpec doc for ~S" symbol))
              :browser browser :out out))
