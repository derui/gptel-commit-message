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

(defcustom gptel-commit-message-prompt
  "Analyze this git diff and generate a concise, well-formatted commit message following conventional commits. Return ONLY the commit message without any explanation or code blocks.

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
"
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

(defvar gptel-commit-message-backend nil
  "The gptel backend used for generating commit messages.
If nil, uses the current gptel-default-model.")

;;;###autoload
(defun gptel-commit-message-generate (&optional callback)
  "Generate a commit message for the current repository using gptel.

If CALLBACK is provided, it will be called with the generated message.
Otherwise, returns the message as a string (blocking call).

The function analyzes the git diff and sends it to the LLM to generate
a commit message. The message is generated without user interaction."
  (interactive)
  (let* ((diff (gptel-commit-message--get-diff))
         (backend
          (or gptel-commit-message-backend
              gptel-default-model
              (error "No gptel backend configured")))
         (prompt
          (concat
           gptel-commit-message-prompt "\n\nGit diff:\n" diff)))

    (if callback
        (gptel-request
         prompt
         :backend backend
         :callback
         (lambda (response info)
           (funcall
            callback
            (gptel-commit-message--extract-message response))))
      (let ((response (gptel--sync-request prompt :backend backend)))
        (gptel-commit-message--extract-message response)))))

;;;###autoload
(defun gptel-commit-message-insert (&optional buffer point)
  "Generate and insert a commit message at point.

BUFFER and POINT default to current buffer and point.
The generated message is inserted without any prompting."
  (interactive)
  (let* ((buf (or buffer (current-buffer)))
         (pos
          (or point
              (with-current-buffer buf
                (point))))
         (message (gptel-commit-message-generate)))
    (with-current-buffer buf
      (goto-char pos)
      (insert message))))

;;;###autoload
(defun gptel-commit-message-fill-buffer ()
  "Fill the current commit message buffer with a generated message.

Useful in a `git commit` hook or when called from a commit message buffer.
Replaces the entire buffer content with the generated commit message."
  (interactive)
  (let ((message (gptel-commit-message-generate)))
    (erase-buffer)
    (insert message)))

(defun gptel-commit-message--get-diff ()
  "Get the git diff for the current repository.

Returns the diff as a string, respecting `gptel-commit-message-use-staged-changes'."
  (let* ((repo-root
          (vc-git-root (or (buffer-file-name) default-directory)))
         (diff-args
          (if gptel-commit-message-use-staged-changes
              '("diff" "--cached")
            '("diff" "HEAD~1" "HEAD")))
         (raw-diff
          (with-temp-buffer
            (apply #'vc-git-command t nil repo-root diff-args)
            (buffer-string))))

    (gptel-commit-message--truncate-diff raw-diff)))

(defun gptel-commit-message--truncate-diff (diff)
  "Truncate DIFF if it exceeds `gptel-commit-message-max-diff-size'."
  (if (> (length diff) gptel-commit-message-max-diff-size)
      (concat
       (substring diff 0 gptel-commit-message-max-diff-size)
       "\n[... diff truncated ...]")
    diff))

(defun gptel-commit-message--extract-message (response)
  "Extract the commit message from RESPONSE.

Removes common wrapper patterns like markdown code blocks."
  (let ((trimmed (string-trim response)))
    ;; Remove markdown code blocks if present
    (if (string-match "^```.*?\n\\(\\(.\\|\n\\)*?\\)\n```$" trimmed)
        (match-string 1 trimmed)
      trimmed)))

(provide 'gptel-commit-message)

;;; gptel-commit-message.el ends here
