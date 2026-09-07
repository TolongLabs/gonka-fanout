---
name: gonka-fanout
description: "Fan work out to headless Claude Code workers running a GonkaRouter model through CLIProxyAPI, up to 6 at once, to spend a GonkaRouter token grant instead of the Claude plan on bulk mechanical work. Use when a task splits into independent chunks that need a capable model but not your judgement. Requires the proxy to be up with a gonkarouter block configured before dispatching."
---

# Gonka Fan-Out

Dispatch headless Claude Code runs as background workers, pointed at CLIProxyAPI so they spend GonkaRouter tokens
instead of the Claude plan. Each worker is the full Claude Code agent in one directory; you write the brief, it writes
the files, you review.

**Why GonkaRouter.** Inference on the Gonka network is priced around $0.0012 per million tokens, and a hackathon or
grant account carries a monthly token allowance that expires unused. Workers are the way to spend it on something
useful.

**Why Headless Claude Code.** The harness gives you `--max-turns`, a real exit code, JSON output, and it reads
`AGENTS.md` and `CLAUDE.md` on its own, so briefs carry the task and not the house rules.

**Six concurrent workers is the ceiling.** Past that they contend for the same files and the review cost exceeds the
saving. GonkaRouter itself allows about 1000 requests a minute, so the proxy is never the limit.

---

## When This Pays, And When It Does Not

| Delegate                                                          | Keep                                                    |
| ----------------------------------------------------------------- | ------------------------------------------------------- |
| Converting a dump into structured Markdown                        | Deciding what the structure should be                   |
| The same transformation across many files                         | Anything where being wrong is expensive and quiet       |
| Drafting from a spec you have already written                     | Writing the spec                                        |
| Per-file summaries, inventories, mechanical extraction            | Architecture, naming, API shape, security               |
| A code change whose exact diff and tests are already in the brief | Work needing conversation context the worker cannot see |

**A worker has none of your context.** Everything it needs goes in the brief. If the brief takes longer to write than
the task takes to do, do the task.

---

## Preflight, In Order

**1. Bring the proxy up and get its token.** No shell alias is involved; these are the raw pieces.

```bash
CLIPROXY_DIR="${CLIPROXY_DIR:-$HOME/.cli-proxy-api}"
CLIPROXY_PORT="${CLIPROXY_PORT:-8317}"
CLIPROXY_TOKEN=$(grep -A1 '^api-keys:' "$CLIPROXY_DIR/config.yaml" | tail -1 | tr -d '" -')
(exec 3<>"/dev/tcp/127.0.0.1/$CLIPROXY_PORT") 2>/dev/null || {
  nohup "${CLIPROXY_BIN:-$HOME/.local/opt/cliproxyapi/cli-proxy-api}" -config "$CLIPROXY_DIR/config.yaml" \
    >> "$CLIPROXY_DIR/proxy.log" 2>&1 & sleep 3
}
```

Never print the token. It is a local secret and it leaks into transcripts.

**2. List the GonkaRouter models the proxy serves.** Only the `gonkarouter` block of `config.yaml` counts. The proxy
also serves OAuth logins and other API-key providers, and those are not what this skill spends: a dead login fails every
call, and another provider bills another account.

```bash
sed -n '/name: "gonkarouter"/,/^  - name: "/p' "$CLIPROXY_DIR/config.yaml" | grep -E '^\s+alias:' | tr -d '" ' | cut -d: -f2
```

**3. Pick the model.** `deepseek-v4-flash-gonka` is the default: dispatch on it without asking. Use `AskUserQuestion`
only when the user asked for a choice or the default is missing from step 2. A model the user named earlier in the same
session is a standing answer: state it back and dispatch.

| Alias                     | GonkaRouter id                       | Context | Notes                                                        |
| ------------------------- | ------------------------------------ | ------- | ------------------------------------------------------------ |
| `deepseek-v4-flash-gonka` | `deepseek-ai/DeepSeek-V4-Flash-0731` | 1M      | **The default.** Clean text, clean tool calls                |
| `minimax-m2.7`            | `MiniMaxAI/MiniMax-M2.7`             | 192k    | Reasoning arrives as literal `<think>` text inside every reply |

**Reasoning effort is inert on both.** GonkaRouter accepts `reasoning_effort` and ignores it, measured, so do not sweep
it or promise it in a brief.

**Adding the provider, once per machine.** If step 2 prints nothing, append this under `openai-compatibility:` in
`config.yaml`. The proxy hot-reloads on save; re-run step 2 to confirm.

```yaml
  - name: "gonkarouter"
    base-url: "https://api.gonkarouter.io/v1"
    api-key-entries:
      - api-key: "sk-..."
    models:
      - name: "deepseek-ai/DeepSeek-V4-Flash-0731"
        alias: "deepseek-v4-flash-gonka"
        display-name: "DeepSeek V4 Flash (Gonka)"
      - name: "MiniMaxAI/MiniMax-M2.7"
        alias: "minimax-m2.7"
        display-name: "MiniMax M2.7 (Gonka)"
```

The live catalogue is `GET https://api.gonkarouter.io/v1/models` with the key as a bearer token. Names on the marketing
pages lag it: models announced there are not necessarily served.

**4. Give workers their own config dir, once per machine.** A worker under your normal `~/.claude` loads every plugin
and hook you have: measured 105,726 input tokens per turn against 19,027 with an empty config dir, and twice the wall
time. DKM and claude-mem also fire inside the worker, which you do not want.

```bash
export CLAUDE_FANOUT_CONFIG="$HOME/.claude-fanout"
mkdir -p "$CLAUDE_FANOUT_CONFIG"
```

An empty directory is a complete config: no plugins, no hooks, no memory. The worker still reads the repository's
`CLAUDE.md` and `AGENTS.md` from the working directory.

---

## Dispatch

### The Command

```bash
env -u ANTHROPIC_API_KEY \
  CLAUDE_CONFIG_DIR="$CLAUDE_FANOUT_CONFIG" \
  ANTHROPIC_BASE_URL="http://127.0.0.1:$CLIPROXY_PORT" \
  ANTHROPIC_AUTH_TOKEN="$CLIPROXY_TOKEN" \
  timeout 1500 claude -p \
    --model "${MODEL:-deepseek-v4-flash-gonka}" \
    --permission-mode acceptEdits \
    --max-turns 40 \
    --output-format json \
    < "<path to the brief>" \
    > "<log path>" 2>&1
echo "exit=$?"
```

- **`-p` reads the brief from stdin.** Put the brief in a file; an inline prompt of any length is shell-quoting
  archaeology
- **`cd` into the working directory first.** The worker's world is its cwd: that is where it reads `AGENTS.md` and where
  relative paths in the brief resolve
- **Always redirect to a log file.** The JSON result is the last line, several kilobytes long; stderr warnings come
  before it. Read it with `tail -n 1`, never `tail -c`
- **Always wrap in `timeout`.** On a proxy error Claude Code retries for about three minutes before giving up, and a
  looping worker burns `--max-turns` worth of tokens. Exit 124 means the timeout fired
- **`--max-turns`** is the budget. Forty is enough for a multi-file edit with tests; ten for a single-file rewrite

### Choosing `--permission-mode`

| Mode                | Auto-approves                   | Use When                                                                  |
| ------------------- | ------------------------------- | ------------------------------------------------------------------------- |
| `acceptEdits`       | Reads and edits in the cwd      | **The default.** Files only; every Bash command is refused unless allowed |
| `bypassPermissions` | Everything                      | Only in a scratch directory or worktree you will throw away               |
| `default`           | Nothing; every prompt is denied | Read-only analysis. Anything not allowed is refused, and it carries on    |

`acceptEdits` refuses every Bash command. Add `--allowedTools "Bash(bun test:*)"` for the commands a brief asks the
worker to run, and nothing wider.

**Give a worker a `git worktree`, never your checkout.** A half-done or looping run then costs one worktree removal, not
a reconstruction, and two workers never share a working tree:

```bash
git worktree add -b <branch> <scratch>/wt-<chunk> main
```

### Parallel, Up To Six

Launch each with `run_in_background: true`, one per call in a single message so they start together. Each gets its own
brief file, its own log, its own worktree or output paths. **Never let two workers write the same file.**

Wait for the task notifications. Do not poll.

### Sequential

Chain in one background call when later chunks depend on earlier output, or when workers touch overlapping files. One
log per stage, `&&` between them, so a failure stops the chain.

**Prefer parallel.** Sequential is for real dependencies, not for tidiness.

---

## Writing The Brief

A worker prompt is a work order. Six things, and the first two are what actually prevent damage:

1. **Name every file to create or edit, and say "and nothing else".** Without it you get stray scratch files
2. **State inputs as paths inside the working directory**, and if the output is committed, say "read them, never mention
   their paths in your output" - otherwise machine paths leak into the deliverable
3. **Give the output format concretely.** Heading levels, table columns, casing. "Well structured" produces whatever the
   model likes today
4. **Carry in the house rules the repository does not already state.** The worker reads `AGENTS.md` itself; repeat only
   what is specific to this job
5. **Say what must be preserved verbatim** when the task is a transformation. Models summarise by reflex
6. **Ask for a short report** - what it wrote, what it could not do, what it guessed at. It arrives as the `result`
   field of the JSON line at the end of the log

Say **"do not run git"** in every brief. The worker can, and a commit from a worker is a commit nobody reviewed.

---

## Verifying, Which Is Not Optional

The JSON result reports `total_cost_usd` as if Anthropic served the model. **It is fictional.** Real usage is on the
GonkaRouter dashboard, drawn from the monthly allowance first. Never quote the JSON figure.

Check, in this order:

```bash
tail -n 1 "$LOG" | jq -r '.result, .num_turns, .permission_denials'      # its report, turns, refusals
git -C <worktree> status --porcelain                                   # what actually changed, including strays
grep -c "<structural marker>" <output>                                 # right shape, right count
grep -rn "/home/\|C:\\\\Users\|/tmp/" <output>                         # no machine paths leaked
grep -rn "<think>" <output>                                            # no leaked reasoning (MiniMax)
```

Then **read the parts that carry risk**, run the tests yourself, and mutation-test any test the worker wrote. A green
run from a worker proves the worker's tests agree with the worker's code and nothing else.

Fix small defects yourself. Re-dispatch only if a chunk is broadly wrong, with the defect named in the new brief.

---

## Failure Modes Seen In The Wild

| Symptom                                                  | Cause And Fix                                                                                       |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `auth_unavailable: no auth available (providers=...)`    | You named a model outside the `gonkarouter` block, and its login is dead. Use a GonkaRouter alias   |
| `'<model>' is not served` or model id rejected           | The `gonkarouter` block is missing or the alias is misspelt. Re-run preflight step 2                 |
| `<think>...</think>` in files or in the report           | MiniMax through GonkaRouter puts reasoning in the text stream. Use `deepseek-v4-flash-gonka`        |
| `<think>` comes out as ` thinking` in worker output      | DeepSeek on GonkaRouter rewrites the literal tag. Write it as `&lt;think&gt;` in briefs, or fix by hand   |
| `400 ... schema pattern is not a valid regular expression` or `"$defs" is not allowed` | GonkaRouter validates tool schemas with Go RE2 and forbids `$defs`. Pass `--disallowedTools Artifact mcp__stitch`, or run under the empty config dir where no MCP tools load |
| `429` from the proxy                                     | Over 1500 requests a minute sustained at GonkaRouter. Fewer workers, not retries; 429s are not billed |
| Exit 124, `terminal_reason":"api_error`, nothing written | The proxy rejected every call and the harness retried until the timeout. Fix the proxy first        |
| `[claude-code:unrecognized_model]` on stderr             | Harmless. Claude Code does not know the proxy model's name; the call still goes through             |
| `claude.ai connectors are disabled` on stderr            | Harmless. `ANTHROPIC_AUTH_TOKEN` takes precedence over the login, which is the point                |
| Every turn costs ~100k input tokens                      | The worker ran under your normal config dir. Set `CLAUDE_CONFIG_DIR` to the empty one               |
| Stray files or a commit in the repo                      | The brief did not say "and nothing else" or "do not run git". `git status` after every run          |
| `permission_denials` is non-empty                        | `acceptEdits` refused a command. Either allow it with `--allowedTools` or do that step yourself     |

---

## Reporting Back

Say which model ran, how many workers, what each produced, **and what you corrected**. The corrections are the useful
part - they tell the user whether the next fan-out should use a tighter brief or a different model.

Never present a worker's output as verified when you only checked that the file exists.
