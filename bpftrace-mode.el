;;; bpftrace-mode.el --- Major mode for editing bpftrace scripts -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Abdelhak Bougouffa

;; Author: Abdelhak Bougouffa (rot13 "nobhtbhssn@srqbencebwrpg.bet")
;; URL: https://github.com/abougouffa/bpftrace-mode
;; Created: October 06, 2026
;; Modified: October 07, 2026
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: languages, tools, c
;; SPDX-License-Identifier: GPL-3.0

;;; Commentary:

;; `bpftrace-mode' is a major mode for editing
;; [bpftrace](https://github.com/bpftrace/bpftrace) files:
;;
;; `bpftrace-mode' is built on top of cc-mode for indentation and syntax
;; highlighting. Highlighting follows the bpftrace 0.27 [language
;; reference](https://bpftrace.org/docs/release_027/language) and [standard
;; library](https://bpftrace.org/docs/release_027/stdlib):
;;
;; It covers:
;;
;;  - Probes (full and short provider names, `name=' prefixes, the special
;;    `begin'/`end' probes, `test', `bench' and `self'), only recognised at the
;;    top level so short names such as `t' or `k' are never confused with code
;;    inside action blocks;
;;  - Language keywords (`let', `macro', `import', `config', `unroll', `for',
;;    `offsetof', `sizeof', `typeof', ...);
;;  - Built-in types, kernel fixed-width `_t' types and map declaration types
;;    (`hash', `lruhash', `percpuhash', `percpulruhash');
;;  - The standard library: builtins usable without parentheses (`pid', `comm',
;;    `argN', `args', ...), helper functions and map value functions (`count',
;;    `hist', `tseries', ...), skipping struct/record field accesses such as
;;    `ctx.task.comm';
;;  - Scratch variables (`$x'), maps (`@x', `@'), positional parameters (`$1',
;;    `$#');
;;  - Macro definitions and `name!()' macro calls;
;;  - Config block variables (with or without the `BPFTRACE_' prefix);
;;  - Integer literals, including `_' separators, scientific notation and
;;    duration suffixes (`100ms', `1s', ...);
;;  - A leading shebang line.
;;
;; Imenu lists probes, macros and declared maps.

;;; Code:

(require 'cc-mode)
(require 'rx)

(defgroup bpftrace nil
  "Major mode for editing bpftrace scripts."
  :group 'languages
  :prefix "bpftrace-")

;;; Faces

(defface bpftrace-probe-face '((t :inherit font-lock-constant-face))
  "Face for probe providers such as `kprobe' or `tracepoint'."
  :group 'bpftrace)

(defface bpftrace-probe-target-face '((t :inherit font-lock-function-name-face))
  "Face for the part of a probe after the provider, e.g. `syscalls:sys_enter_open'."
  :group 'bpftrace)

(defface bpftrace-probe-name-face '((t :inherit font-lock-variable-name-face))
  "Face for the optional `name=' prefix of a probe."
  :group 'bpftrace)

(defface bpftrace-builtin-face '((t :inherit font-lock-builtin-face))
  "Face for bpftrace builtins, helper functions and map value functions."
  :group 'bpftrace)

(defface bpftrace-map-face '((t :inherit font-lock-variable-name-face))
  "Face for map variables such as `@start' or `@'."
  :group 'bpftrace)

(defface bpftrace-scratch-variable-face '((t :inherit font-lock-variable-name-face))
  "Face for scratch variables such as `$x'."
  :group 'bpftrace)

(defface bpftrace-positional-parameter-face '((t :inherit font-lock-constant-face))
  "Face for positional parameters such as `$1' and `$#'."
  :group 'bpftrace)

(defface bpftrace-macro-call-face '((t :inherit font-lock-preprocessor-face))
  "Face for explicit macro calls such as `greet!()'."
  :group 'bpftrace)

(defface bpftrace-config-variable-face '((t :inherit font-lock-variable-name-face))
  "Face for config variables inside a `config = { ... }' block."
  :group 'bpftrace)

(defface bpftrace-number-face '((t :inherit font-lock-constant-face))
  "Face for integer and duration literals."
  :group 'bpftrace)

;;; Vocabulary

(defconst bpftrace-keywords
  '("break" "config" "continue" "else" "for" "if" "import" "let" "macro"
    "offsetof" "return" "sizeof" "typeinfo" "typeof" "unroll"
    ;; `while' is deprecated
    "while")
  "Reserved words of the bpftrace language.")

(defconst bpftrace-constants
  '("true" "false")
  "Literal constants of the bpftrace language.")

(defconst bpftrace-types
  '("bool" "int8" "uint8" "int16" "uint16" "int32" "uint32" "int64" "uint64"
    "string" "buffer" "inet" "void"
    "struct" "union" "enum")
  "Fundamental and parameterised bpftrace types.")

(defconst bpftrace-map-types
  '("hash" "lruhash" "percpuhash" "percpulruhash")
  "BPF map types usable in map declarations, e.g. `let @a = lruhash(100);'.")

(defconst bpftrace-probe-providers
  '(;; Full names
    "bench" "test" "self" "hardware" "interval" "iter" "fentry" "fexit"
    "kfunc" "kretfunc" "kprobe" "kretprobe" "profile" "rawtracepoint" "software"
    "tracepoint" "uprobe" "uretprobe" "usdt" "watchpoint"
    ;; Short names
    "h" "i" "it" "f" "fr" "k" "kr" "p" "rt" "s" "t" "u" "ur" "U" "w")
  "Probe providers that are followed by a `:' separated list of options.")

(defconst bpftrace-special-probes
  '("begin" "end"
    ;; Pre-0.24 spelling
    "BEGIN" "END")
  "Probes that take no options.")

(defconst bpftrace-builtin-variables
  '("args" "cgroup" "comm" "cpid" "cpu" "ctx" "curtask" "default_str_length"
    "dw_ustack" "elapsed" "func" "gid" "has_cpid" "jiffies" "kstack"
    "leader_comm" "leader_tid" "ncpus" "nsecs" "numaid" "pcomm" "pid" "ppid"
    "probe" "probetype" "rand" "retval" "tid" "uid" "usermode" "username"
    "ustack")
  "Builtins that may be used with or without call syntax.
`argN' is matched separately.  `config' is highlighted as a keyword.")

(defconst bpftrace-builtin-functions
  '(;; Helpers
    "assert" "assert_str" "bswap" "buf" "cat" "cgroup_path" "cgroupid" "clear"
    "container_of" "delete" "errorf" "exit" "fail" "find" "getopt" "has_key"
    "is_array" "is_err" "is_integer" "is_literal" "is_ptr" "is_str"
    "is_unsigned_integer" "join" "kaddr" "kfunc_allowed" "kfunc_exist" "kptr"
    "ksym" "len" "macaddr" "memcmp" "ntop" "override" "path" "percpu_kaddr"
    "print" "printf" "pton" "reg" "signal" "signal_name" "signal_thread"
    "skboutput" "socket_cookie" "static_assert" "str" "str_concat" "strcap"
    "strcontains" "strerror" "strftime" "strlen" "strncmp" "strstr"
    "syscall_name" "system" "time" "uaddr" "unwatch" "uptr" "usym" "warnf"
    "write_user" "zero"
    ;; Map value functions
    "avg" "count" "hist" "lhist" "max" "min" "stats" "sum" "tseries")
  "Standard library functions, highlighted only when followed by `('.")

(defconst bpftrace-config-variables
  '("cache_user_symbols" "cpp_demangle" "lazy_symbolication" "license"
    "log_size" "max_bpf_progs" "max_cat_bytes" "max_map_keys" "max_probes"
    "max_strlen" "missing_probes" "on_stack_limit" "perf_rb_pages"
    "print_maps_on_exit" "show_debug_info" "stack_mode" "str_trunc_trailer"
    "unstable_dw_ustack" "unstable_map_decl" "unstable_tseries")
  "Variables that may be set in a `config = { ... }' block.")

;;; Regexps

(defconst bpftrace--ident-re "[_[:alpha:]][_[:alnum:]]*"
  "Regexp matching a bpftrace identifier.")

(defun bpftrace--words-re (words)
  "Return a regexp matching any of WORDS."
  (regexp-opt words))

(defconst bpftrace--probe-re
  (rx-to-string
   `(seq (or line-start (any " \t,"))
         (? (group (regexp ,bpftrace--ident-re)) "=")
         (group (regexp ,(bpftrace--words-re bpftrace-probe-providers)))
         ":"
         (group (* (not (any " \t\n,{")))))
   t)
  "Regexp matching a probe with options.
Group 1 is the optional name, 2 the provider, 3 the options.")

(defconst bpftrace--special-probe-re
  (rx-to-string
   `(seq (or line-start (any " \t,"))
         (? (group (regexp ,bpftrace--ident-re)) "=")
         (group (regexp ,(bpftrace--words-re bpftrace-special-probes)))
         symbol-end
         (* (any " \t"))
         (or "{" "," "/" line-end))
   t)
  "Regexp matching `begin' and `end' probes.
Group 1 is the optional name, 2 the probe.")

(defconst bpftrace--number-re
  (rx symbol-start
      (or (seq "0" (any "xX") (+ (any "0-9a-fA-F_")))
          (seq (any "0-9") (* (any "0-9_")) (? (any "eE") (+ (any "0-9")))))
      (? (or "ns" "us" "ms" "s" "m" "h" "d"
             (seq (any "uU") (? (any "lL") (? (any "lL"))))
             (seq (any "lL") (? (any "lL")) (? (any "uU")))))
      symbol-end)
  "Regexp matching integer literals, with optional C or duration suffix.")

;;; Matching helpers

(defun bpftrace--top-level-p (pos)
  "Return non-nil if POS is outside any braces, strings and comments."
  (let ((ppss (save-excursion (syntax-ppss pos))))
    (and (<= (car ppss) 0)
         (not (nth 8 ppss)))))

(defun bpftrace--member-access-p (pos)
  "Return non-nil if the identifier at POS follows `.' or `->'.
A `..' range operator does not count as member access."
  (save-excursion
    (goto-char pos)
    (skip-chars-backward " \t")
    (let ((c1 (char-before))
          (c2 (and (> (point) (1+ (point-min))) (char-before (1- (point))))))
      (or (and (eq c1 ?.) (not (eq c2 ?.)))
          (and (eq c1 ?>) (eq c2 ?-))))))

(defun bpftrace--matcher (regexp predicate)
  "Return a font-lock matcher searching for REGEXP.
Matches for which PREDICATE, called with no arguments and the
match data set, returns nil are skipped."
  (lambda (limit)
    (let (found)
      (while (and (not found) (re-search-forward regexp limit t))
        (when (save-match-data (funcall predicate))
          (setq found t)))
      found)))

(defun bpftrace--probe-ok-p ()
  "Return non-nil if the current probe match is at the top level."
  (bpftrace--top-level-p (match-beginning 2)))

(defun bpftrace--not-member-p ()
  "Return non-nil if match group 1 is not a struct or record field."
  (not (bpftrace--member-access-p (match-beginning 1))))

(defun bpftrace--code-p ()
  "Return non-nil if the current match is not in a string or comment."
  (not (nth 8 (save-excursion (syntax-ppss (match-beginning 0))))))

;;; Syntax table

(defvar bpftrace-mode-syntax-table
  (let ((table (make-syntax-table c-mode-syntax-table)))
    ;; `$x' and `@x' are single symbols, so that e.g. `pid' is not
    ;; highlighted inside `$pid' and `count' not inside `@count'.
    (modify-syntax-entry ?$ "_" table)
    (modify-syntax-entry ?@ "_" table)
    table)
  "Syntax table for `bpftrace-mode'.")

;;; Font lock

(defvar bpftrace-mode-font-lock-keywords
  (append
   `(
     ;; Shebang line
     (,(rx buffer-start "#!" (* nonl)) 0 font-lock-comment-face t)

     ;; Probes: [name=]provider:options  and  [name=]begin / end
     (,(bpftrace--matcher bpftrace--probe-re #'bpftrace--probe-ok-p)
      (1 'bpftrace-probe-name-face nil t)
      (2 'bpftrace-probe-face)
      (3 'bpftrace-probe-target-face nil t))
     (,(bpftrace--matcher bpftrace--special-probe-re #'bpftrace--probe-ok-p)
      (1 'bpftrace-probe-name-face nil t)
      (2 'bpftrace-probe-face))

     ;; Macro definitions: macro name(...) { ... }
     (,(rx-to-string `(seq symbol-start "macro" symbol-end (+ space)
                           (group (regexp ,bpftrace--ident-re)))
                     t)
      1 font-lock-function-name-face)

     ;; Explicit macro calls: name!(...)
     (,(rx-to-string `(seq symbol-start (group (regexp ,bpftrace--ident-re) "!")
                           (* space) "(")
                     t)
      1 'bpftrace-macro-call-face)

     ;; Config variables: config = { stack_mode=perf; ... }
     (,(rx-to-string `(seq symbol-start
                           (group (? "BPFTRACE_")
                                  (regexp ,(bpftrace--words-re
                                            (append bpftrace-config-variables
                                                    (mapcar #'upcase bpftrace-config-variables)))))
                           symbol-end (* space) "=" (not (any "=")))
                     t)
      1 'bpftrace-config-variable-face)

     ;; Map declarations: let @a = lruhash(100);
     (,(rx-to-string `(seq symbol-start
                           (group (regexp ,(bpftrace--words-re bpftrace-map-types)))
                           symbol-end (* space) "(")
                     t)
      1 font-lock-type-face)

     (,(regexp-opt bpftrace-constants 'symbols) . font-lock-constant-face)

     ;; Types
     (,(regexp-opt bpftrace-types 'symbols) . font-lock-type-face)
     (,(rx symbol-start (? "u") "int" (or "8" "16" "32" "64") "_t" symbol-end)
      . font-lock-type-face)

     ;; Positional parameters: $1, $2, ..., $#
     (,(rx (or (seq symbol-start "$" (+ digit) symbol-end) "$#"))
      . 'bpftrace-positional-parameter-face)

     ;; Scratch variables: $name
     (,(rx symbol-start "$" (any "_" alpha) (* (any "_" alnum)) symbol-end)
      . 'bpftrace-scratch-variable-face)

     ;; Maps: @name, @
     (,(rx symbol-start "@" (* (any "_" alnum)) symbol-end)
      . 'bpftrace-map-face)

     ;; Standard library functions (call syntax)
     (,(bpftrace--matcher
        (rx-to-string `(seq symbol-start
                            (group (regexp ,(bpftrace--words-re bpftrace-builtin-functions)))
                            symbol-end (* space) "(")
                      t)
        #'bpftrace--not-member-p)
      1 'bpftrace-builtin-face)

     ;; Builtins usable without call syntax, and argN
     (,(bpftrace--matcher
        (rx-to-string `(seq symbol-start
                            (group (or (regexp ,(bpftrace--words-re bpftrace-builtin-variables))
                                       (seq "arg" (+ digit))))
                            symbol-end)
                      t)
        #'bpftrace--not-member-p)
      1 'bpftrace-builtin-face)

     ;; Integer literals
     (,bpftrace--number-re . 'bpftrace-number-face))

   ;; Also add normal C highlighting (preprocessor, structs, strings...)
   c-font-lock-keywords
   ;; Keywords come last and override cc-mode, which would otherwise
   ;; take e.g. `macro' in `macro name(...) {' for a type name.
   `((,(bpftrace--matcher (regexp-opt bpftrace-keywords 'symbols)
                          #'bpftrace--code-p)
      0 font-lock-keyword-face t)))
  "Font lock keywords for `bpftrace-mode'.")

;;; Imenu

(defvar bpftrace-imenu-generic-expression
  `(("Macros"
     ,(rx-to-string `(seq line-start (* space) "macro" (+ space)
                          (group (regexp ,bpftrace--ident-re)))
                    t)
     1)
    ("Maps"
     ,(rx line-start (* space) "let" (+ space)
          (group "@" (* (any "_" alnum))) (* space) "=")
     1)
    ("Probes"
     ,(rx-to-string
       `(seq line-start (* space)
             (group (? (regexp ,bpftrace--ident-re) "=")
                    (or (seq (regexp ,(bpftrace--words-re bpftrace-probe-providers))
                             ":" (* (not (any " \t\n{"))))
                        (seq (regexp ,(bpftrace--words-re bpftrace-special-probes))
                             symbol-end))))
       t)
     1))
  "Imenu index expressions for `bpftrace-mode'.")

;;; Indentation

(defun bpftrace--indent-top-level ()
  "Keep top-level lines of probes, predicates and braces at column 0.
cc-mode treats the second probe of a multi-line probe list as a
statement continuation and indents it; this undoes that.  Run from
`c-special-indent-hook'."
  (let ((ppss (save-excursion (syntax-ppss (line-beginning-position)))))
    (when (and (<= (car ppss) 0)
               (not (nth 8 ppss))
               ;; Leave preprocessor lines and their continuations to cc-mode.
               (save-excursion (back-to-indentation) (not (eq (char-after) ?#)))
               (save-excursion
                 (or (bobp)
                     (progn (forward-line -1)
                            (not (looking-at-p ".*\\\\$"))))))
      (if (<= (current-column) (current-indentation))
          (indent-line-to 0)
        (save-excursion (indent-line-to 0))))))

;;; Mode

(defvar bpftrace-mode-map (make-sparse-keymap)
  "Keymap for `bpftrace-mode' buffers.")

;;;###autoload
(define-derived-mode bpftrace-mode c-mode "bpftrace"
  "Major mode for editing bpftrace script files.

\\{bpftrace-mode-map}"
  (setq font-lock-defaults '(bpftrace-mode-font-lock-keywords nil nil))
  (c-toggle-comment-style -1) ; bpftrace scripts conventionally use // comments.
  (setq-local imenu-generic-expression bpftrace-imenu-generic-expression
              imenu-case-fold-search nil)
  (add-hook 'c-special-indent-hook #'bpftrace--indent-top-level nil t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.bt\\'" . bpftrace-mode))

;;;###autoload
(add-to-list 'interpreter-mode-alist '("bpftrace" . bpftrace-mode))

(provide 'bpftrace-mode)

;;; bpftrace-mode.el ends here

;; Local Variables:
;; time-stamp-pattern: "^;; Modified: %%$"
;; time-stamp-format: "%B %d, %Y"
;; End:
