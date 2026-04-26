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

(require 'cl-lib)
(require 'gptel)
(require 'subr-x)
(require 'vc-git)

(defgroup gptel-commit-message nil
  "Generate git commit messages using gptel."
  :group 'gptel
  :prefix "gptel-commit-message-")

(defface gptel-commit-message-streaming-face '((t :inherit shadow))
  "Face used for streamed text before generation completes."
  :group 'gptel-commit-message)

(defconst gptel-commit-message-generation-indicator
  '("⣷" "⣯" "⣟" "⡿" "⢿" "⣻" "⣽" "⣾")
  "Frames used for the streaming generation indicator.")

(defconst gptel-commit-message-generation-indicator-interval 0.1
  "Seconds between animation frames for the generation indicator.")

(defconst gptel-commit-message-conventional-prompt
  "Analyze this git diff and generate a concise, well-formatted commit message following conventional commits. Return ONLY the commit message without any explanation or code blocks.

FORMAT:
<format>
[type]: {description}

{commit body if necessary}

{breaking change section}
</format>

- Description should be less than 50 charactors as possible.
- Each line of commit message body should be less than 72 charactors each line as possible.

RULES:
Do not add too descriptive message. Each description and message should be simple as possible.

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
             (position (copy-marker (point) t)))
        (setq gptel-commit-message-last-error nil)
        (gptel-commit-message--request
         :prompt
         (concat
          gptel-commit-message-prompt
          "\n\n---Git diff---\n"
          (gptel-commit-message--get-diff))
         :backend
         (or gptel-commit-message-backend
             gptel-backend
             (error "No gptel backend configured"))
         :buffer buffer
         :position position))
    (error
     (gptel-commit-message--handle-error err))))

(defun gptel-commit-message--get-diff ()
  "Get the git diff for the current repository.

Return the diff as a string.

Respect `gptel-commit-message-use-staged-changes'."
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

(cl-defun
 gptel-commit-message--request
 (&key prompt backend buffer position)
 "Send PROMPT to BACKEND for BUFFER at POSITION."
 (let ((state (gptel-commit-message--make-request-state position))
       (gptel-backend backend)
       (gptel-stream t))
   (gptel-request
    prompt
    :buffer buffer
    :stream t
    :callback
    (lambda (response info)
      (setq state
            (gptel-commit-message--request-handler
             state response info))
      (gptel-commit-message--handle-response
       response info buffer state)))))

(defun gptel-commit-message--make-request-state (position)
  "Create request state beginning at POSITION."
  (let ((state
         (list
          :chunks nil
          :start (copy-marker position)
          :content-end (copy-marker position)
          :indicator-end (copy-marker position t)
          :indicator-index 0
          :timer nil)))
    (gptel-commit-message--start-indicator state)
    state))

(defun gptel-commit-message--request-handler (state response _info)
  "Update STATE with streamed RESPONSE content.

Responses containing reasoning or control messages are ignored."
  (pcase response
    ((pred stringp)
     (gptel-commit-message--append-chunk state response))
    (`(reasoning . ,_) state)
    (_ state)))

(defun gptel-commit-message--append-chunk (state chunk)
  "Append CHUNK to STATE and insert it with a temporary face."
  (when-let* ((content-end (plist-get state :content-end))
              (buf (marker-buffer content-end)))
    (with-current-buffer buf
      (save-excursion
        (gptel-commit-message--delete-indicator state)
        (goto-char content-end)
        (insert
         (propertize chunk
                     'font-lock-face
                     'gptel-commit-message-streaming-face))
        (set-marker content-end (point) buf)
        (gptel-commit-message--render-indicator state))))
  (setf (plist-get state :chunks)
        (cons chunk (plist-get state :chunks)))
  state)

(defun gptel-commit-message--handle-response
    (response info buffer state)
  "Handle streamed RESPONSE and INFO for BUFFER using STATE."
  (condition-case err
      (cond
       ((not (buffer-live-p buffer))
        (gptel-commit-message--release-state state)
        nil)
       ((stringp response)
        nil)
       ((eq response t)
        (gptel-commit-message--finish-request buffer state))
       ((eq response 'abort)
        (gptel-commit-message--fail-request
         :buffer buffer
         :message "gptel request aborted"
         :state state))
       ((null response)
        (gptel-commit-message--fail-request
         :buffer buffer
         :message
         (or (plist-get info :status) "gptel request failed")
         :state state)))
    (error
     (gptel-commit-message--fail-request
      :buffer buffer
      :message (error-message-string err)
      :state state))))

(defun gptel-commit-message--finish-request (buffer state)
  "Finalize BUFFER contents using streamed STATE."
  (unwind-protect
      (let ((message
             (string-trim
              (apply #'concat (nreverse (plist-get state :chunks))))))
        (when (string-empty-p message)
          (error "gptel returned an empty response"))
        (when (buffer-live-p buffer)
          (gptel-commit-message--replace-streamed-text
           state message)))
    (gptel-commit-message--release-state state)))

(defun gptel-commit-message--replace-streamed-text (state message)
  "Replace text tracked by STATE with finalized MESSAGE."
  (when-let* ((start (plist-get state :start))
              (buf (marker-buffer start)))
    (with-current-buffer buf
      (save-excursion
        (goto-char start)
        (delete-region start (plist-get state :indicator-end))
        (insert message)))))

(defun gptel-commit-message--clear-streamed-text (state)
  "Delete any streamed text tracked by STATE."
  (when-let* ((start (plist-get state :start))
              (buf (marker-buffer start)))
    (with-current-buffer buf
      (save-excursion
        (delete-region start (plist-get state :indicator-end))))))

(defun gptel-commit-message--start-indicator (state)
  "Start the generation indicator for STATE."
  (gptel-commit-message--render-indicator state)
  (setf (plist-get state :timer)
        (run-with-timer
         gptel-commit-message-generation-indicator-interval
         gptel-commit-message-generation-indicator-interval
         (lambda () (gptel-commit-message--tick-indicator state)))))

(defun gptel-commit-message--tick-indicator (state)
  "Advance and redraw the generation indicator for STATE."
  (when-let* ((content-end (plist-get state :content-end))
              (buf (marker-buffer content-end)))
    (setf (plist-get state :indicator-index)
          (mod
           (1+ (plist-get state :indicator-index))
           (length gptel-commit-message-generation-indicator)))
    (with-current-buffer buf
      (save-excursion
        (gptel-commit-message--render-indicator state)))))

(defun gptel-commit-message--render-indicator (state)
  "Render the current generation indicator frame for STATE."
  (when-let* ((content-end (plist-get state :content-end))
              (buf (marker-buffer content-end)))
    (gptel-commit-message--delete-indicator state)
    (with-current-buffer buf
      (save-excursion
        (goto-char content-end)
        (insert
         (propertize (gptel-commit-message--indicator-frame state)
                     'font-lock-face
                     'gptel-commit-message-streaming-face))
        (set-marker (plist-get state :indicator-end) (point) buf)))))

(defun gptel-commit-message--delete-indicator (state)
  "Delete the current generation indicator for STATE."
  (when-let* ((content-end (plist-get state :content-end))
              (indicator-end (plist-get state :indicator-end))
              (buf (marker-buffer content-end)))
    (with-current-buffer buf
      (save-excursion
        (delete-region content-end indicator-end)
        (set-marker indicator-end content-end buf)))))

(defun gptel-commit-message--indicator-frame (state)
  "Return the current indicator frame for STATE."
  (nth
   (plist-get state :indicator-index)
   gptel-commit-message-generation-indicator))

(defun gptel-commit-message--release-state (state)
  "Release markers held by STATE."
  (when-let ((timer (plist-get state :timer)))
    (cancel-timer timer)
    (setf (plist-get state :timer) nil))
  (set-marker (plist-get state :start) nil)
  (set-marker (plist-get state :content-end) nil)
  (set-marker (plist-get state :indicator-end) nil))

(cl-defun
 gptel-commit-message--fail-request
 (&key buffer message state)
 "Record MESSAGE as a request failure for BUFFER.

Clear partial STATE when present."
 (when state
   (unwind-protect
       (when (buffer-live-p buffer)
         (gptel-commit-message--clear-streamed-text state))
     (gptel-commit-message--release-state state)))
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
