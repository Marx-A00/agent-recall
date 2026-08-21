# Agent Recall

[![MELPA](https://melpa.org/packages/agent-recall-badge.svg)](https://melpa.org/#/agent-recall)

Search, browse, and resume [agent-shell](https://github.com/xenodium/agent-shell) conversation transcripts.

![total-recall](total-recall.png)

## agent-recall

[agent-shell](https://github.com/xenodium/agent-shell) automatically saves full conversation transcripts as Markdown or Org-mode files in `.agent-shell/transcripts/` within your projects (or in a separate directory via `agent-shell-org-transcript`). Over time these accumulate into a rich knowledge base of AI interactions, but there's no built-in way to search across them or resume past conversations.

agent-recall maintains a persistent index of all transcripts, provides fast full-text search, and can resume past agent-shell sessions from any transcript.

Features:

- **Search** all transcripts with built-in grep (no external dependencies) or optional [ripgrep](https://github.com/BurntSushi/ripgrep) backends
- **Live search** with real-time filtering via counsel-rg or consult-ripgrep
- **Aggregated Consult search** with one result per matching transcript
- **Browse** transcripts by project and date with live preview (consult or ivy/counsel)
- **Resume** past agent-shell sessions directly from a transcript
- **Track** session IDs automatically via hook
- **Backfill** session IDs into old transcripts retroactively
- **Stats** about your transcript collection

## Setup

### Dependencies

- **agent-shell** — required for session resume and automatic session tracking. Search and browse work without it.
- **ripgrep** (optional) — needed for the deadgrep, counsel-rg, and consult-ripgrep search backends. The default grep backend uses standard grep and requires no extra installation.

### Installation

#### MELPA (recommended)

agent-recall is available on [MELPA](https://melpa.org/#/agent-recall). Make sure MELPA is in your `package-archives`, then:

```
M-x package-install RET agent-recall RET
```

Or with `use-package`:

```elisp
(use-package agent-recall
  :ensure t
  :config
  (setq agent-recall-search-paths '("~/projects" "~/work")))
```

#### Elpaca

```elisp
(elpaca agent-recall
  (setq agent-recall-search-paths '("~/projects" "~/work")))
```

Or with use-package integration:

```elisp
(use-package agent-recall
  :ensure t
  :config
  (setq agent-recall-search-paths '("~/projects" "~/work")))
```

#### straight.el

```elisp
(use-package agent-recall
  :straight (:host github :repo "Marx-A00/agent-recall")
  :config
  (setq agent-recall-search-paths '("~/projects" "~/work")))
```

#### Doom Emacs

In `packages.el`:

```elisp
(package! agent-recall)
```

In `config.el`:

```elisp
(use-package! agent-recall
  :config
  (setq agent-recall-search-paths '("~/projects" "~/work")))
```

#### Manual

```bash
git clone https://github.com/Marx-A00/agent-recall.git ~/.emacs.d/agent-recall
```

```elisp
(use-package agent-recall
  :load-path "~/.emacs.d/agent-recall"
  :config
  (setq agent-recall-search-paths '("~/projects" "~/work")))
```

### Configuration

#### Search paths

Tell agent-recall where your projects live. These directories are scanned recursively for `.agent-shell/transcripts/` subdirectories:

```elisp
(setq agent-recall-search-paths '("~/projects" "~/work" "~/personal"))

;; Or scan everything (slow on large home directories):
;; (setq agent-recall-search-paths '("~"))
```

#### Org-mode transcripts

If you use [agent-shell-org-transcript](https://github.com/lllShamanlll/agent-shell-org-transcript) to save transcripts as Org files outside the conventional `.agent-shell/transcripts/` layout, add those directories directly:

```elisp
(setq agent-recall-extra-transcript-dirs
      '((:dir "~/org/agent-shell/")))
```

Then run `M-x agent-recall-reindex` to pick them up.

#### Search backend

Choose how search results are displayed. The default `grep` backend works everywhere with no extra dependencies; the others require [ripgrep](https://github.com/BurntSushi/ripgrep) and provide live-filtering:

```elisp
;; Built-in grep (default, no external dependencies)
(setq agent-recall-search-function 'grep)

;; deadgrep (requires ripgrep + deadgrep package)
(setq agent-recall-search-function 'deadgrep)

;; counsel-rg (requires ripgrep + ivy/counsel)
(setq agent-recall-search-function 'counsel-rg)

;; consult-ripgrep (requires ripgrep + vertico/consult)
(setq agent-recall-search-function 'consult-ripgrep)
```

#### Session tracking

To automatically embed session IDs in new transcripts (enabling instant resume):

```elisp
(add-hook 'agent-shell-mode-hook #'agent-recall-track-sessions)
```

#### Browse sort order

```elisp
;; Newest first by creation date (default)
(setq agent-recall-browse-sort 'date-desc)

;; Oldest first by creation date
(setq agent-recall-browse-sort 'date-asc)

;; Most recently modified first (recommended — resumed sessions float to top)
(setq agent-recall-browse-sort 'modified-desc)

;; Least recently modified first
(setq agent-recall-browse-sort 'modified-asc)

;; Group by project
(setq agent-recall-browse-sort 'project)
```

#### Full example

```elisp
(use-package agent-recall
  :ensure t
  :hook (agent-shell-mode . agent-recall-track-sessions)
  :config
  (setq agent-recall-search-paths '("~/projects" "~/work")
        agent-recall-search-function 'consult-ripgrep
        agent-recall-browse-sort 'modified-desc))
```

## Usage

### Quick start

```elisp
;; 1. Set your search paths
(setq agent-recall-search-paths '("~/projects"))

;; 2. Build the index (one-time, scans filesystem)
;; M-x agent-recall-reindex

;; 3. Search, browse, or resume
;; M-x agent-recall-search
;; M-x agent-recall-browse
;; M-x agent-recall-resume
```

### Searching transcripts

`M-x agent-recall-search` prompts for a query and searches all indexed transcripts. The display depends on `agent-recall-search-function`.

`M-x agent-recall-search-live` opens a live-filtering search. It auto-selects the best available backend (`counsel-rg` or `consult-ripgrep`); falls back to a one-shot search if neither is installed.

`M-x agent-recall-consult-search` provides a richer Consult interface when `consult` and `ripgrep` are installed. It groups matches by transcript and shows candidates in `[project] [match-count] date first-match` format, then jumps to the first match in the selected transcript.

### Browsing transcripts

`M-x agent-recall-browse` shows a completion list of all transcripts in `[project] timestamp` format with preview annotations. Selecting a transcript opens it in `agent-recall-transcript-mode`.

When `agent-recall-browse-preview` is non-nil (the default), browse provides live preview of transcripts as you navigate candidates:

- **consult** users get preview via `consult--read` (vertico ecosystem)
- **ivy/counsel** users get preview via `ivy-read` with `:update-fn` (ivy ecosystem)
- Without either, falls back to plain `completing-read`

#### Embark integration

If you use [embark](https://github.com/oantolin/embark), agent-recall registers actions for browse candidates automatically:

| Key | Action |
|-----|--------|
| `o` | Open transcript in other window |
| `r` | Resume session (switches to existing buffer if already running) |
| `R` | Force resume session (always starts a new buffer) |

### Transcript mode

When you open a transcript via `agent-recall-browse`, `agent-recall-search`, or `agent-recall-search-live`, `agent-recall-transcript-mode` activates automatically. The buffer becomes read-only and shows a header line with available actions.

To disable auto-activation:

```elisp
(setq agent-recall-auto-transcript-mode nil)
```

You can always toggle it manually with `M-x agent-recall-transcript-mode`, or enable it globally for all transcript files (including those opened outside of agent-recall):

```elisp
(global-agent-recall-transcript-mode 1)
```

### Resuming sessions

There are two ways to resume a past session:

- Press `r` in transcript mode to resume that transcript's session
- `M-x agent-recall-resume` to pick from all resumable transcripts

If the session is already running in an agent-shell buffer, `r` will switch to that buffer instead of starting a new one. Press `R` to force a fresh resume regardless.

Requires agent-shell to be loaded.

#### Transcript continuity

When you resume a session, agent-recall defaults to appending new messages to the **original transcript file** rather than creating a new one. This keeps the full conversation history in a single file.

agent-recall uses the transcript's `**Agent:**` header to resume with the same agent configuration when possible. If the header is missing, it falls back to your `agent-shell` preferred/default selection.

> **Note:** Transcripts created by older versions of agent-shell may have a shortened agent name in the header (e.g., `Claude` instead of `Claude Code`). These won't auto-match a config and will prompt you to select one manually.

If you would like to create new transcripts instead:

```elisp
(setq agent-recall-resume-continue-transcript nil)
```

#### Restoring session preferences

While a tracked session runs, agent-recall snapshots its preferences — model, thought level (effort), and permission mode — into a sidecar metadata store (`agent-recall-metadata-file`), keyed by session ID. Snapshots happen after every completed turn and when the shell buffer is killed, so the stored values always reflect the session's **last** state, even if you switched models mid-conversation. Transcript files themselves are never touched.

On resume, those preferences are re-applied: model and permission mode during agent-shell's session bootstrap, effort right after initialization. Saved values are validated against what the live session actually offers — a model that no longer exists is skipped with a message, never an error.

Control this with:

```elisp
(setq agent-recall-resume-restore-preferences t)   ; always restore (default)
(setq agent-recall-resume-restore-preferences 'ask) ; prompt each time
(setq agent-recall-resume-restore-preferences nil) ; never restore
```

The store is extensible: packages (or your config) can persist arbitrary per-session data and restore it on resume. Each capture function returns an alist to merge into the session's metadata (nil values remove keys); each restore function receives the saved metadata and the new shell buffer. For example, to preserve a custom buffer label across resumes:

```elisp
(add-hook 'agent-recall-capture-functions
          (lambda () `((label . ,(my-app-get-label (current-buffer))))))

(add-hook 'agent-recall-restore-functions
          (lambda (metadata shell-buffer)
            (when-let ((label (alist-get 'label metadata)))
              (my-app-set-label shell-buffer label))))
```

Preferences only exist for sessions tracked by `agent-recall-track-sessions` from v0.7.0 onward; older sessions simply resume with agent-shell's defaults.

#### Session load vs resume

agent-shell supports two ACP methods for resuming sessions:

- **`session/resume`** — reconnects to the session server-side but does **not** return previous messages to the buffer
- **`session/load`** — reconnects and **returns previous messages**, so you can see the full conversation history in the buffer

To get previous messages when resuming, set:

```elisp
;; Note that this is an agent-shell variable, NOT a part of agent-recall
(setq agent-shell-prefer-session-resume nil)
```

This tells agent-shell to use `session/load` instead of `session/resume` when both are available.

### Backfilling session IDs

If you have existing transcripts from before you set up session tracking, you can retroactively match them to sessions:

```
;; Dry-run (preview matches, no changes)
M-x agent-recall-backfill

;; Actually write session IDs to transcript headers
C-u C-u M-x agent-recall-backfill
```

An undo log is saved alongside the index file so you can reverse the changes if needed.

Note: In my experience, Claude chats get offloaded, so there's a good chance that older conversations won't be able to be matched.

### Key bindings

In `agent-recall-transcript-mode`:

| Key | Command |
|-----|---------|
| `r` | Resume session — switches to existing buffer if already running |
| `R` | Force resume — always starts a new agent-shell buffer |
| `c` | Open clean view (strip tool calls) |
| `b` | Return to browse list |
| `C-c C-n` | Jump to next user message |
| `C-c C-p` | Jump to previous user message |
| `q` | Quit window (evil) |

#### Evil

Evil users get additional bindings in normal state:

| Key | Command |
|-----|---------|
| `]]` | Next user message |
| `[[` | Previous user message |
| `gj` | Next user message |
| `gk` | Previous user message |
| `C-j` | Next user message |
| `C-k` | Previous user message |
| `q` | Quit window |

## Customizations

| Custom variable | Description |
|-----------------|-------------|
| `agent-recall-search-paths` | Root directories to scan for transcripts |
| `agent-recall-max-depth` | Maximum directory depth when scanning (default: 6) |
| `agent-recall-transcript-dir-name` | Relative path identifying transcript dirs |
| `agent-recall-file-patterns` | Glob patterns for transcript files (default: `*.md`, `*.org`) |
| `agent-recall-extra-transcript-dirs` | Extra transcript directories indexed directly (e.g. org-mode output) |
| `agent-recall-rg-executable` | Path to ripgrep executable for rg-based backends (default: `rg`) |
| `agent-recall-search-extra-args` | Extra arguments passed to ripgrep (rg-based backends only) |
| `agent-recall-search-context-lines` | Context lines around search matches (default: 2) |
| `agent-recall-search-function` | Search backend: grep, deadgrep, counsel-rg, consult-ripgrep |
| `agent-recall-index-file` | Path to persistent index file |
| `agent-recall-browse-sort` | Sort order: date-desc, date-asc, modified-desc, modified-asc, project |
| `agent-recall-browse-preview` | Live preview in browse via consult or ivy (default: t) |
| `agent-recall-auto-transcript-mode` | Auto-activate transcript-mode from agent-recall commands (default: t) |
| `agent-recall-resume-continue-transcript` | Append to original transcript on resume (default: t) |
| `agent-recall-claude-config-dir` | Claude CLI config directory for session matching |
| `agent-recall-session-match-window` | Max seconds for timestamp matching (default: 120) |

## Commands

| Command | Description |
|---------|-------------|
| `agent-recall-reindex` | Rebuild transcript index from filesystem |
| `agent-recall-search` | Search all transcripts for a query |
| `agent-recall-search-live` | Live-filtering search with auto backend selection |
| `agent-recall-consult-search` | Aggregated Consult search grouped by transcript |
| `agent-recall-browse` | Browse transcripts by project with previews |
| `agent-recall-resume` | Resume a past session (pick from all resumable) |
| `agent-recall-resume-current` | Resume session from current transcript (smart — switches to existing buffer) |
| `agent-recall-force-resume-current` | Force resume, always starting a new agent-shell buffer |
| `agent-recall-clean-view` | Strip tool calls, show clean user/agent messages |
| `agent-recall-next-user-message` | Jump to next user message in transcript |
| `agent-recall-prev-user-message` | Jump to previous user message in transcript |
| `agent-recall-stats` | Display transcript collection statistics |
| `agent-recall-track-sessions` | Hook: auto-embed session IDs in new transcripts |
| `agent-recall-backfill` | Retroactively match old transcripts to session IDs |
| `agent-recall-invalidate-cache` | Clear in-memory caches |

## How it works

### Index

agent-recall maintains a persistent index (default: `<user-emacs-directory>/agent-recall/index.el`, or under `no-littering-var-directory` if available). The index is a hash-table mapping file paths to metadata (project, timestamp, session ID, preview).

The index is built by `agent-recall-reindex` (scans the filesystem) and grows automatically via the `agent-recall-track-sessions` hook.

### Session ID resolution

Session IDs are resolved in order:

1. **Embedded header** — a `**Session ID:** UUID` line written natively by agent-shell, or `**Session:** UUID` / `#+PROPERTY: Session UUID` written by `agent-recall-track-sessions` or `agent-recall-backfill`
2. **Retroactive matching** — hybrid approach: narrows candidates by comparing the transcript's `**Started:**` timestamp (markdown) or `#+DATE:` (org-mode) against Claude session data in `~/.claude/projects/` (within `agent-recall-session-match-window` seconds), then confirms by comparing the first user message in the transcript against the first message in the Claude JSONL file

The main index is persisted to disk and loads automatically. Retroactive matching results are cached in memory to avoid re-running the expensive JSONL comparison on every access.

### Search directory

For search backends that need a single root directory (deadgrep, counsel-rg, consult-ripgrep), agent-recall creates a temporary symlink directory alongside the index file pointing to all indexed transcript directories.

## Contributing

Issues and pull requests welcome at https://github.com/Marx-A00/agent-recall.
