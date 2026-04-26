;;; gptel-commit-message.el --- Generate git commit messages using gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Your Name <your.email@example.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (gptel "0.99"))
;; Keywords: tools, gptel, git
;; URL: https://github.com/derui/gptel-commit-message

;;; Commentary:

;; This package integrates gptel with git to automatically generate
;; commit messages based on the staged changes (diff) without prompting
;; the user. It uses gptel to analyze the commit diff
;; and create a meaningful commit message.

;;; Code:

(require 'gptel)
(require 'vc-git)

(defgroup gptel-commit-message nil
  "Generate git commit messages using gptel."
  :group 'gptel
  :prefix "gptel-commit-message-")

(defconst gptel-commit-message-conventional-prompt
  "Analyze this git diff and generate a concise, well-formatted commit message following conventional commits. Return ONLY the commit message without any explanation or code blocks.

The commit message must describe WHY the change come.

RULES:
Use conventional commit message. Must prefix <type>: with follows:

- feat :: making feature
- fix :: fix some bug
- perf :: performance concerns
- refactor :: change design, or architecture
- docs :: changes only document
- chore :: some works not in category
- ci :: changes for CI
- build :: changes for build

FORMAT:
When changes are simple or only one function, generate only single line, with type and description.
When changes are complex or large, generate more detailed comment.

BERAKING CHANGE:
When the changes contained breaking change, it must be in footer under `BREAKING CHANGE:' section.
"
  "Default prompt for generating conventional commit messages.")

(defcustom gptel-commit-message-prompt
  gptel-commit-message-conventional-prompt
  "The prompt template used to generate commit messages.
This is sent to gptel along with the git diff."
  :type 'string
  :group 'gptel-commit-message)

(defcustom gptel-commit-message-max-diff-size 50000
  "Maximum size in characters for the diff to send to gptel.
Larger diffs are truncated to prevent excessive API usage."
  :type 'integer
  :group 'gptel-commit-message)

(defcustom gptel-commit-message-use-staged-changes t
  "If t, use staged changes (git add). If nil, use HEAD~1..HEAD changes.
Set to nil to generate messages for already committed changes."
  :type 'boolean
  :group 'gptel-commit-message)

(defcustom gptel-commit-message-excluded-globs '("*.lock" "*-lock.*")
  "List of file globs to exclude from the diff sent to gptel.

Each entry is converted to a git pathspec with `glob' and `exclude'
magic, so patterns are matched relative to the repository root."
  :type '(repeat string)
  :group 'gptel-commit-message)

(defvar gptel-commit-message-backend nil
  "The gptel backend used for generating commit messages.
If nil, uses the current value of `gptel-backend'.")

(defvar gptel-commit-message-last-error nil
  "Last error message produced by gptel-commit-message.

Public entrypoints set this when generation fails instead of
signaling an error to callers.")

;;;###autoload
(defun gptel-commit-message-generate ()
  "Generate a commit message for the current repository using gptel.

The function analyzes the git diff and sends it to the LLM to generate
 a commit message. The generated message is inserted into the current
 buffer at point without user interaction.

 Returns non-nil if generation starts successfully, or nil if it fails.  See
 `gptel-commit-message-last-error' for details."
  (interactive)
  (condition-case err
      (let* ((buffer (current-buffer))
             (position (copy-marker (point) t))
             (diff (gptel-commit-message--get-diff))
             (backend
              (or gptel-commit-message-backend
                  gptel-backend
                  (error "No gptel backend configured")))
              (prompt
               (concat
                gptel-commit-message-prompt "\n\nGit diff:\n" diff)))
         (setq gptel-commit-message-last-error nil)
         (gptel-commit-message--request prompt backend buffer position)
         t)
    (error
     (gptel-commit-message--handle-error err))))

(defun gptel-commit-message--get-diff ()
  "Get the git diff for the current repository.

Returns the diff as a string, respecting `gptel-commit-message-use-staged-changes'."
  (gptel-commit-message--truncate-diff
   (with-temp-buffer
     (apply #'vc-git-command
            t
            nil
            (vc-git-root (or (buffer-file-name) default-directory))
            (gptel-commit-message--diff-args))
     (buffer-string))))

(defun gptel-commit-message--diff-args ()
  "Build git diff arguments for the current configuration."
  (let ((base-args
         (if gptel-commit-message-use-staged-changes
             '("diff" "--cached")
           '("diff" "HEAD~1" "HEAD"))))
    (if gptel-commit-message-excluded-globs
        (append
         base-args '("--" ".")
         (mapcar
          #'gptel-commit-message--exclude-pathspec
          gptel-commit-message-excluded-globs))
      base-args)))

(defun gptel-commit-message--exclude-pathspec (glob)
  "Convert GLOB into a git pathspec exclusion."
  (format ":(glob,exclude)%s" glob))

(defun gptel-commit-message--request (prompt backend buffer position)
  "Send PROMPT to BACKEND for BUFFER at POSITION."
  (let ((chunks nil))
    (let ((gptel-backend backend)
          (gptel-stream t))
      (gptel-request
       prompt
       :buffer buffer
       :stream t
       :callback
       (lambda (response info)
         (setq chunks
               (gptel-commit-message--request-handler
                chunks response info))
         (gptel-commit-message--handle-response
          response info buffer position chunks))))))

(defun gptel-commit-message--request-handler (chunks response _info)
  "Update CHUNKS with streamed RESPONSE content.

Responses containing reasoning or control messages are ignored."
  (pcase response
    ((pred stringp) (push response chunks))
    (`(reasoning . ,_) chunks)
    (_ chunks)))

(defun gptel-commit-message--handle-response
    (response info buffer position chunks)
   "Handle streamed RESPONSE and INFO for BUFFER at POSITION using CHUNKS."
   (condition-case err
       (cond
        ((not (buffer-live-p buffer))
         nil)
        ((stringp response)
         nil)
       ((eq response t)
        (gptel-commit-message--finish-request buffer position chunks))
       ((eq response 'abort)
        (gptel-commit-message--fail-request
         buffer "gptel request aborted"))
       ((null response)
        (gptel-commit-message--fail-request
         buffer
         (or (plist-get info :status) "gptel request failed"))))
    (error
     (gptel-commit-message--fail-request
      buffer (error-message-string err)))))

(defun gptel-commit-message--finish-request (buffer position chunks)
  "Insert CHUNKS into BUFFER at POSITION."
  (let ((message
         (gptel-commit-message--extract-message
          (apply #'concat (nreverse chunks)))))
    (when (string-empty-p message)
      (error "gptel returned an empty response"))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (goto-char position)
          (insert message))))))

(defun gptel-commit-message--fail-request (buffer message)
  "Record MESSAGE as a request failure for BUFFER."
  (setq gptel-commit-message-last-error message)
  (message "gptel-commit-message: %s" message))

(defun gptel-commit-message--handle-error (err)
  "Record and report ERR, then return nil."
  (setq gptel-commit-message-last-error (error-message-string err))
  (message "gptel-commit-message: %s" gptel-commit-message-last-error)
  nil)

(defun gptel-commit-message--truncate-diff (diff)
  "Truncate DIFF if it exceeds `gptel-commit-message-max-diff-size'."
  (if (> (length diff) gptel-commit-message-max-diff-size)
      (concat
       (substring diff 0 gptel-commit-message-max-diff-size)
       "\n[... diff truncated ...]")
    diff))

(provide 'gptel-commit-message)

;;; gptel-commit-message.el ends here
