---
name: agent-recall
description: >
  Search past agent-shell conversation transcripts as a knowledge base.
  Use when the user asks to recall past conversations, look up how something
  was done before, find previous solutions, search transcript history,
  or when you need context from earlier AI interactions. Triggers on:
  "recall", "search transcripts", "past conversations", "how did we",
  "previously", "last time", "search history", "knowledge base",
  "find in transcripts", "agent-recall".
tools: Bash
---

# Agent Recall -- Transcript Knowledge Base

Search past agent-shell conversation transcripts to find how similar
problems were solved, recall previous decisions, or retrieve context
from earlier AI interactions.

All commands use `emacsclient --eval` since we run inside Emacs.

## Step 1: Orient -- List indexed projects

Get an overview of what's available:

```bash
emacsclient --eval '(agent-recall-list-projects-string)'
```

## Step 2: Search

### Search summaries first (preferred)

If the user has run `M-x agent-recall-summarize`, structured summaries
exist alongside transcripts. These are concise and semantic -- search
them first:

```bash
emacsclient --eval '(agent-recall-search-summaries-string "your query")'
```

### Fall back to raw transcript search

If summaries return no results, search the full transcripts:

```bash
emacsclient --eval '(agent-recall-search-string "your query")'
```

Both functions accept an optional second argument to limit results
(default 20):

```bash
emacsclient --eval '(agent-recall-search-string "your query" 10)'
```

## Step 3: Read full transcripts

When search results point to a relevant file, read the full transcript
using the Read tool to get complete context. Transcript file paths
appear in ripgrep output as the first component of each match line.

## Step 4: Synthesize and apply

After finding relevant past conversations:
1. Summarize what was found and which transcripts it came from
2. Note the project context (from the Working Directory in the header)
3. Apply the relevant knowledge to the current task
4. Cite the source transcript file when referencing past solutions

## Transcript structure

Transcripts are markdown files with this structure:

```
# Agent Shell Transcript

**Agent:** Claude
**Started:** YYYY-MM-DD HH:MM:SS
**Working Directory:** /path/to/project
**Session:** UUID

---

## User (timestamp)
<user message>

## Agent (timestamp)
<agent response>

### Tool Call [tool-name]
<tool invocation details>
```

## Search tips

- Search summaries first -- they contain Topic, Problem, Outcome, and Tags
- Start with broad queries and narrow down
- For error messages, search distinctive parts only
- Results are sorted by most recently modified first
- Use the Read tool on matching files to get the full conversation context
- File paths encode the project and timestamp:
  `/path/to/project/.agent-shell/transcripts/2026-04-12T10:30:15.123.md`

## If no transcripts are indexed

Tell the user to run `M-x agent-recall-reindex` in Emacs first.

## If summaries are not available

Tell the user they can improve search quality by running
`M-x agent-recall-summarize` in Emacs, which generates structured
summaries of all transcripts using an LLM.

## Rules

- Always use `emacsclient --eval` to call agent-recall functions.
- Always search summaries first, fall back to raw transcripts.
- Always read the full transcript file when a match looks relevant.
- Never guess transcript content -- read the actual file.
- Cite the source transcript path when applying knowledge from past sessions.
