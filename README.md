# gptel-commit-message

Generate git commit messages automatically using gptel, the LLM endpoint utility for Emacs.

This package integrates [gptel](https://github.com/karthink/gptel) with git to automatically generate meaningful commit messages based on the staged changes (diff) without requiring user interaction.

## Features

- 🤖 Automatic commit message generation from git diffs
- 🚀 Zero-prompt interface - generates messages without user interaction
- 📏 Respects gptel configuration and model selection
- 🛡️ Configurable diff size limits to manage API usage
- 🔄 Support for both staged changes and committed diffs
- ✨ Follows conventional commits format

## Installation

### Manual

1. Clone this repository or download `gptel-commit-message.el`
2. Add to your Emacs configuration:

```elisp
(use-package gptel-commit-message
  :load-path "/path/to/gptel-commit-message"
  :after gptel)
```

### Requirements

- Emacs 27.1 or later
- [gptel](https://github.com/karthink/gptel) - must be installed and configured

## Usage

### Interactive Commands

#### `gptel-commit-message-generate`

Generate a commit message and return it. Can be called with a callback for async operation.

```elisp
;; Sync call
(let ((message (gptel-commit-message-generate)))
  (message "Generated: %s" message))

;; Async call with callback
(gptel-commit-message-generate
  (lambda (message)
    (message "Generated: %s" message)))
```

#### `gptel-commit-message-insert`

Generate and insert a commit message at the current point.

```elisp
(gptel-commit-message-insert)
```

#### `gptel-commit-message-fill-buffer`

Replace the entire buffer with a generated commit message. Useful in a commit message buffer or git hook.

```elisp
(gptel-commit-message-fill-buffer)
```

### Git Hook Integration

Use in a `prepare-commit-msg` hook to automatically generate commit messages:

```bash
#!/bin/bash
# .git/hooks/prepare-commit-msg

emacs --batch -l ~/.emacs.d/init.el \
  --eval '(gptel-commit-message-fill-buffer)' \
  "$1"
```

### Customization

#### `gptel-commit-message-prompt`

Customize the prompt sent to the LLM:

```elisp
(setq gptel-commit-message-prompt
      "Generate a concise git commit message following conventional commits format. 
       Consider the changes and write ONLY the commit message.")
```

#### `gptel-commit-message-max-diff-size`

Limit diff size to manage API costs (default: 50000 characters):

```elisp
(setq gptel-commit-message-max-diff-size 30000)
```

#### `gptel-commit-message-use-staged-changes`

Use staged changes (default: t) or already-committed changes:

```elisp
;; Use staged changes
(setq gptel-commit-message-use-staged-changes t)

;; Use HEAD~1..HEAD instead
(setq gptel-commit-message-use-staged-changes nil)
```

#### `gptel-commit-message-backend`

Specify a particular gptel backend (optional). If not set, uses `gptel-default-model`:

```elisp
(setq gptel-commit-message-backend
      (gptel-make-openai "ChatGPT"
        :key "your-api-key"
        :models '(gpt-4)))
```

## How It Works

1. **Fetch Diff**: Retrieves the git diff from staged changes (or committed changes if configured)
2. **Truncate if Needed**: Respects size limits to avoid excessive API usage
3. **Send to LLM**: Sends the diff and prompt to gptel's configured backend
4. **Extract Message**: Cleans up the response (removes markdown formatting, etc.)
5. **Return/Insert**: Either returns the message, inserts it at point, or fills the buffer

## Example Workflow

```elisp
;; 1. Stage your changes
;; $ git add src/feature.el

;; 2. In Emacs, call the command
(call-interactively 'gptel-commit-message-insert)

;; 3. Or fill a commit message buffer
(call-interactively 'gptel-commit-message-fill-buffer)

;; 4. Review and commit
;; $ git commit -m "feat: add new feature based on user feedback"
```

## Troubleshooting

### "No gptel backend configured"

Ensure gptel is installed and configured:

```elisp
(use-package gptel
  :config
  (setq gptel-model "gpt-4"
        gptel-default-model "gpt-4"))
```

### Large diffs being truncated

Adjust the limit:

```elisp
(setq gptel-commit-message-max-diff-size 100000)
```

### Generated messages are too verbose

Customize the prompt:

```elisp
(setq gptel-commit-message-prompt
      "Generate a VERY SHORT commit message (max 50 chars). Format: type: subject")
```

## License

See LICENSE file for details.

## Contributing

Contributions are welcome! Please submit issues or pull requests.
