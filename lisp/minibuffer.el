;;; minibuffer.el --- Minibuffer completion functions

;; Copyright (C) 2008  Free Software Foundation, Inc.

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Names starting with "minibuffer--" are for functions and variables that
;; are meant to be for internal use only.

;; TODO:
;; - merge do-completion and complete-word
;; - move all I/O out of do-completion

;;; Code:

(eval-when-compile (require 'cl))

(defgroup minibuffer nil
  "Controlling the behavior of the minibuffer."
  :link '(custom-manual "(emacs)Minibuffer")
  :group 'environment)

(defun minibuffer-message (message &rest args)
  "Temporarily display MESSAGE at the end of the minibuffer.
The text is displayed for `minibuffer-message-timeout' seconds,
or until the next input event arrives, whichever comes first.
Enclose MESSAGE in [...] if this is not yet the case.
If ARGS are provided, then pass MESSAGE through `format'."
  ;; Clear out any old echo-area message to make way for our new thing.
  (message nil)
  (unless (and (null args) (string-match "\\[.+\\]" message))
    (setq message (concat " [" message "]")))
  (when args (setq message (apply 'format message args)))
  (let ((ol (make-overlay (point-max) (point-max) nil t t)))
    (unwind-protect
        (progn
          (overlay-put ol 'after-string message)
          (sit-for (or minibuffer-message-timeout 1000000)))
      (delete-overlay ol))))

(defun minibuffer-completion-contents ()
  "Return the user input in a minibuffer before point as a string.
That is what completion commands operate on."
  (buffer-substring (field-beginning) (point)))

(defun delete-minibuffer-contents ()
  "Delete all user input in a minibuffer.
If the current buffer is not a minibuffer, erase its entire contents."
  (delete-field))

(defcustom completion-auto-help t
  "Non-nil means automatically provide help for invalid completion input.
If the value is t the *Completion* buffer is displayed whenever completion
is requested but cannot be done.
If the value is `lazy', the *Completions* buffer is only displayed after
the second failed attempt to complete."
  :type '(choice (const nil) (const t) (const lazy))
  :group 'minibuffer)

(defun minibuffer--bitset (modified completions exact)
  (logior (if modified    4 0)
          (if completions 2 0)
          (if exact       1 0)))

(defun minibuffer--do-completion (&optional try-completion-function)
  "Do the completion and return a summary of what happened.
M = completion was performed, the text was Modified.
C = there were available Completions.
E = after completion we now have an Exact match.

 MCE
 000  0 no possible completion
 001  1 was already an exact and unique completion
 010  2 no completion happened
 011  3 was already an exact completion
 100  4 ??? impossible
 101  5 ??? impossible
 110  6 some completion happened
 111  7 completed to an exact completion"
  (let* ((beg (field-beginning))
         (string (buffer-substring beg (point)))
         (completion (funcall (or try-completion-function 'try-completion)
                              string
                              minibuffer-completion-table
                              minibuffer-completion-predicate)))
    (cond
     ((null completion)
      (ding) (minibuffer-message "No match") (minibuffer--bitset nil nil nil))
     ((eq t completion) (minibuffer--bitset nil nil t)) ;Exact and unique match.
     (t
      ;; `completed' should be t if some completion was done, which doesn't
      ;; include simply changing the case of the entered string.  However,
      ;; for appearance, the string is rewritten if the case changes.
      (let ((completed (not (eq t (compare-strings completion nil nil
                                                   string nil nil t))))
            (unchanged (eq t (compare-strings completion nil nil
                                              string nil nil nil))))
        (unless unchanged
          ;; Merge a trailing / in completion with a / after point.
          ;; We used to only do it for word completion, but it seems to make
          ;; sense for all completions.
          (if (and (eq ?/ (aref completion (1- (length completion))))
                   (< (point) (field-end))
                   (eq ?/ (char-after)))
              (setq completion (substring completion 0 -1)))

          ;; Insert in minibuffer the chars we got.
          (let ((end (point)))
            (insert completion)
            (delete-region beg end)))

        (if (not (or unchanged completed))
	   ;; The case of the string changed, but that's all.  We're not sure
	   ;; whether this is a unique completion or not, so try again using
	   ;; the real case (this shouldn't recurse again, because the next
	   ;; time try-completion will return either t or the exact string).
           (minibuffer--do-completion try-completion-function)

          ;; It did find a match.  Do we match some possibility exactly now?
          (let ((exact (test-completion (field-string)
					minibuffer-completion-table
					minibuffer-completion-predicate)))
            (unless completed
              ;; Show the completion table, if requested.
              (cond
               ((not exact)
                (if (case completion-auto-help
                      (lazy (eq this-command last-command))
                      (t completion-auto-help))
                    (minibuffer-completion-help)
                  (minibuffer-message "Next char not unique")))
               ;; If the last exact completion and this one were the same,
               ;; it means we've already given a "Complete but not unique"
               ;; message and the user's hit TAB again, so now we give him help.
               ((eq this-command last-command)
                (if completion-auto-help (minibuffer-completion-help)))))

            (minibuffer--bitset completed t exact))))))))

(defun minibuffer-complete ()
  "Complete the minibuffer contents as far as possible.
Return nil if there is no valid completion, else t.
If no characters can be completed, display a list of possible completions.
If you repeat this command after it displayed such a list,
scroll the window of possible completions."
  (interactive)
  ;; If the previous command was not this,
  ;; mark the completion buffer obsolete.
  (unless (eq this-command last-command)
    (setq minibuffer-scroll-window nil))

  (let ((window minibuffer-scroll-window))
    ;; If there's a fresh completion window with a live buffer,
    ;; and this command is repeated, scroll that window.
    (if (window-live-p window)
        (with-current-buffer (window-buffer window)
          (if (pos-visible-in-window-p (point-max) window)
	      ;; If end is in view, scroll up to the beginning.
	      (set-window-start window (point-min) nil)
	    ;; Else scroll down one screen.
	    (scroll-other-window))
	  nil)

      (case (minibuffer--do-completion)
        (0 nil)
        (1 (goto-char (field-end))
           (minibuffer-message "Sole completion")
           t)
        (3 (goto-char (field-end))
           (minibuffer-message "Complete, but not unique")
           t)
        (t t)))))

(defun minibuffer-complete-and-exit ()
  "If the minibuffer contents is a valid completion then exit.
Otherwise try to complete it.  If completion leads to a valid completion,
a repetition of this command will exit."
  (interactive)
  (cond
   ;; Allow user to specify null string
   ((= (field-beginning) (field-end)) (exit-minibuffer))
   ((test-completion (field-string)
                     minibuffer-completion-table
                     minibuffer-completion-predicate)
    (when completion-ignore-case
      ;; Fixup case of the field, if necessary.
      (let* ((string (field-string))
	     (compl (try-completion string
				    minibuffer-completion-table
				    minibuffer-completion-predicate)))
	(when (and (stringp compl)
                   ;; If it weren't for this piece of paranoia, I'd replace
                   ;; the whole thing with a call to complete-do-completion.
                   (= (length string) (length compl)))
          (let ((beg (field-beginning))
                (end (field-end)))
            (goto-char end)
            (insert compl)
            (delete-region beg end)))))
    (exit-minibuffer))

   ((eq minibuffer-completion-confirm 'confirm-only)
    ;; The user is permitted to exit with an input that's rejected
    ;; by test-completion, but at the condition to confirm her choice.
    (if (eq last-command this-command)
	(exit-minibuffer)
      (minibuffer-message "Confirm")
      nil))

   (t
    ;; Call do-completion, but ignore errors.
    (case (condition-case nil
              (minibuffer--do-completion)
            (error 1))
      ((1 3) (exit-minibuffer))
      (7 (if (not minibuffer-completion-confirm)
             (exit-minibuffer)
           (minibuffer-message "Confirm")
           nil))
      (t nil)))))

(defun minibuffer-try-word-completion (string table predicate)
  (let ((completion (try-completion string table predicate)))
    (if (not (stringp completion))
        completion

      ;; Completing a single word is actually more difficult than completing
      ;; as much as possible, because we first have to find the "current
      ;; position" in `completion' in order to find the end of the word
      ;; we're completing.  Normally, `string' is a prefix of `completion',
      ;; which makes it trivial to find the position, but with fancier
      ;; completion (plus env-var expansion, ...) `completion' might not
      ;; look anything like `string' at all.

      (when minibuffer-completing-file-name
	;; In order to minimize the problem mentioned above, let's try to
	;; reduce the different between `string' and `completion' by
	;; mirroring some of the work done in read-file-name-internal.
	(let ((substituted (condition-case nil
			       ;; Might fail when completing an env-var.
			       (substitute-in-file-name string)
			     (error string))))
	  (unless (eq string substituted)
	    (setq string substituted))))

      ;; Make buffer (before point) contain the longest match
      ;; of `string's tail and `completion's head.
      (let* ((startpos (max 0 (- (length string) (length completion))))
             (length (- (length string) startpos)))
        (while (and (> length 0)
                    (not (eq t (compare-strings string startpos nil
                                                completion 0 length
                                                completion-ignore-case))))
          (setq startpos (1+ startpos))
          (setq length (1- length)))

        (setq string (substring string startpos)))

      ;; Now `string' is a prefix of `completion'.

      ;; If completion finds next char not unique,
      ;; consider adding a space or a hyphen.
      (when (= (length string) (length completion))
        (let ((exts '(" " "-"))
              tem)
          (while (and exts (not (stringp tem)))
            (setq tem (try-completion (concat string (pop exts))
                                      table predicate)))
          (if (stringp tem) (setq completion tem))))

      ;; Otherwise cut after the first word.
      (if (string-match "\\W" completion (length string))
          ;; First find first word-break in the stuff found by completion.
          ;; i gets index in string of where to stop completing.
          (substring completion 0 (match-end 0))
        completion))))


(defun minibuffer-complete-word ()
  "Complete the minibuffer contents at most a single word.
After one word is completed as much as possible, a space or hyphen
is added, provided that matches some possible completion.
Return nil if there is no valid completion, else t."
  (interactive)
  (case (minibuffer--do-completion 'minibuffer-try-word-completion)
    (0 nil)
    (1 (goto-char (field-end))
       (minibuffer-message "Sole completion")
       t)
    (3 (goto-char (field-end))
       (minibuffer-message "Complete, but not unique")
       t)
    (t t)))

(defun minibuffer--insert-strings (strings)
  "Insert a list of STRINGS into the current buffer.
Uses columns to keep the listing readable but compact.
It also eliminates runs of equal strings."
  (when (consp strings)
    (let* ((length (apply 'max
			  (mapcar (lambda (s)
				    (if (consp s)
					(+ (length (car s)) (length (cadr s)))
				      (length s)))
				  strings)))
	   (window (get-buffer-window (current-buffer) 0))
	   (wwidth (if window (1- (window-width window)) 79))
	   (columns (min
		     ;; At least 2 columns; at least 2 spaces between columns.
		     (max 2 (/ wwidth (+ 2 length)))
		     ;; Don't allocate more columns than we can fill.
		     ;; Windows can't show less than 3 lines anyway.
		     (max 1 (/ (length strings) 2))))
	   (colwidth (/ wwidth columns))
           (column 0)
	   (laststring nil))
      ;; The insertion should be "sensible" no matter what choices were made
      ;; for the parameters above.
      (dolist (str strings)
	(unless (equal laststring str)  ; Remove (consecutive) duplicates.
	  (setq laststring str)
	  (unless (bolp)
            (insert " \t")
            (setq column (+ column colwidth))
            ;; Leave the space unpropertized so that in the case we're
            ;; already past the goal column, there is still
            ;; a space displayed.
            (set-text-properties (- (point) 1) (point)
                                 ;; We can't just set tab-width, because
                                 ;; completion-setup-function will kill all
                                 ;; local variables :-(
                                 `(display (space :align-to ,column))))
	  (when (< wwidth (+ (max colwidth
				  (if (consp str)
				      (+ (length (car str)) (length (cadr str)))
				    (length str)))
			     column))
	    (delete-char -2) (insert "\n") (setq column 0))
	  (if (not (consp str))
	      (put-text-property (point) (progn (insert str) (point))
				 'mouse-face 'highlight)
	    (put-text-property (point) (progn (insert (car str)) (point))
			       'mouse-face 'highlight)
	    (put-text-property (point) (progn (insert (cadr str)) (point))
                               'mouse-face nil)))))))

(defvar completion-common-substring)

(defun display-completion-list (completions &optional common-substring)
  "Display the list of completions, COMPLETIONS, using `standard-output'.
Each element may be just a symbol or string
or may be a list of two strings to be printed as if concatenated.
If it is a list of two strings, the first is the actual completion
alternative, the second serves as annotation.
`standard-output' must be a buffer.
The actual completion alternatives, as inserted, are given `mouse-face'
properties of `highlight'.
At the end, this runs the normal hook `completion-setup-hook'.
It can find the completion buffer in `standard-output'.
The optional second arg COMMON-SUBSTRING is a string.
It is used to put faces, `completions-first-difference' and
`completions-common-part' on the completion buffer. The
`completions-common-part' face is put on the common substring
specified by COMMON-SUBSTRING.  If COMMON-SUBSTRING is nil
and the current buffer is not the minibuffer, the faces are not put.
Internally, COMMON-SUBSTRING is bound to `completion-common-substring'
during running `completion-setup-hook'."
  (if (not (bufferp standard-output))
      ;; This *never* (ever) happens, so there's no point trying to be clever.
      (with-temp-buffer
	(let ((standard-output (current-buffer))
	      (completion-setup-hook nil))
	  (display-completion-list completions))
	(princ (buffer-string)))

    (with-current-buffer standard-output
      (goto-char (point-max))
      (if (null completions)
	  (insert "There are no possible completions of what you have typed.")

	(insert "Possible completions are:\n")
	(minibuffer--insert-strings completions))))
  (let ((completion-common-substring common-substring))
    (run-hooks 'completion-setup-hook))
  nil)

(defun minibuffer-completion-help ()
  "Display a list of possible completions of the current minibuffer contents."
  (interactive)
  (message "Making completion list...")
  (let* ((string (field-string))
         (completions (all-completions
                       string
                       minibuffer-completion-table
                       minibuffer-completion-predicate
                       t)))
    (message nil)
    (if (and completions
             (or (cdr completions) (not (equal (car completions) string))))
        (with-output-to-temp-buffer "*Completions*"
          (display-completion-list (sort completions 'string-lessp)))

      ;; If there are no completions, or if the current input is already the
      ;; only possible completion, then hide (previous&stale) completions.
      (let ((window (and (get-buffer "*Completions*")
                         (get-buffer-window "*Completions*" 0))))
        (when (and (window-live-p window) (window-dedicated-p window))
          (condition-case ()
              (delete-window window)
            (error (iconify-frame (window-frame window))))))
      (ding)
      (minibuffer-message
       (if completions "Sole completion" "No completions")))
    nil))

(defun exit-minibuffer ()
  "Terminate this minibuffer argument."
  (interactive)
  ;; If the command that uses this has made modifications in the minibuffer,
  ;; we don't want them to cause deactivation of the mark in the original
  ;; buffer.
  ;; A better solution would be to make deactivate-mark buffer-local
  ;; (or to turn it into a list of buffers, ...), but in the mean time,
  ;; this should do the trick in most cases.
  (setq deactivate-mark nil)
  (throw 'exit nil))

(defun self-insert-and-exit ()
  "Terminate minibuffer input."
  (interactive)
  (if (characterp last-command-char)
      (call-interactively 'self-insert-command)
    (ding))
  (exit-minibuffer))

(defun minibuffer--double-dollars (str)
  (replace-regexp-in-string "\\$" "$$" str))

(defun read-file-name-internal (string dir action)
  "Internal subroutine for read-file-name.  Do not call this."
  (setq dir (expand-file-name dir))
  (if (and (zerop (length string)) (eq 'lambda action))
      nil                               ; FIXME: why?
    (let* ((str (substitute-in-file-name string))
           (name (file-name-nondirectory str))
           (specdir (file-name-directory str))
           (realdir (if specdir (expand-file-name specdir dir)
                      (file-name-as-directory dir))))
      
      (cond
       ((null action)
        (let ((comp (file-name-completion name realdir
                                          read-file-name-predicate)))
          (if (stringp comp)
              ;; Requote the $s before returning the completion.
              (minibuffer--double-dollars (concat specdir comp))
            ;; Requote the $s before checking for changes.
            (setq str (minibuffer--double-dollars str))
            (if (string-equal string str)
                comp
              ;; If there's no real completion, but substitute-in-file-name
              ;; changed the string, then return the new string.
              str))))
       
       ((eq action t)
        (let ((all (file-name-all-completions name realdir)))
          (if (memq read-file-name-predicate '(nil file-exists-p))
              all
            (let ((comp ())
                  (pred
                   (if (eq read-file-name-predicate 'file-directory-p)
                       ;; Brute-force speed up for directory checking:
                       ;; Discard strings which don't end in a slash.
                       (lambda (s)
                         (let ((len (length s)))
                           (and (> len 0) (eq (aref s (1- len)) ?/))))
                     ;; Must do it the hard (and slow) way.
                     read-file-name-predicate)))
              (let ((default-directory realdir))
                (dolist (tem all)
                  (if (funcall pred tem) (push tem comp))))
              (nreverse comp)))))

       (t
        ;; Only other case actually used is ACTION = lambda.
        (let ((default-directory dir))
          (funcall (or read-file-name-predicate 'file-exists-p) str)))))))


(provide 'minibuffer)
;;; minibuffer.el ends here
