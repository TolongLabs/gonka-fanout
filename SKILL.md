---
name: gonka-fanout
description: "Use when bulk mechanical work splits into independent chunks suitable for headless Claude Code workers through CLIProxyAPI and GonkaRouter, especially when validating model callability, diagnosing provider errors, or comparing Gonka models."
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

### The 200k Ceiling Means Fan Out Wide, Not Deep

One worker has a hard ceiling of roughly 200,000 tokens on `input + max_tokens` combined, and the gateway rejects
anything larger (`accepts up to about 200000 tokens (input plus max_tokens)`). So a single Gonka worker cannot be asked
to wade through a large corpus, a long file, or a sprawling task in one run — it will hit the ceiling mid-task and fail
with an opaque rejection that looks like a harness bug.

**Prefer many small workers over one big one.** When a task is large enough that you are weighing how to split it,
that is already the signal to split it further than feels natural. The practical guidance:

- **Slice by unit of work, not by convenience.** One file, one function, one record type, one page — however small it
  makes the brief. A brief that takes two minutes to write is cheaper than a failed 200k run.
- **Budget each worker's input explicitly.** If a worker is reading a big file, tell it which lines or which section,
  or have it read incrementally. Do not hand it a 300KB file and let it decide.
- **Raise the worker count before the brief size.** Six parallel workers at a small brief each beats one worker with a
  large brief; the ceiling is per-request, so breadth is what buys you room.
- **Keep `max_tokens` modest.** Every output token is charged against the same 200000. A worker that only has to write a
  small file does not need a 32k output budget, and an oversized one eats headroom the input needed.
- **When a dispatch fails near the ceiling, do not raise `max_tokens`.** That is backwards. Split the task and
  re-dispatch each half.

This is the inverse of the usual instinct. With a local model the advice is "give the worker everything"; here the
constraint makes that advice wrong. Reach for more workers, not longer briefs.

---

## Preflight, In Order

**0. One command for the whole setup.** [`setup.sh`](setup.sh) does steps 1–4 in one go: it adds the `gonkarouter` block
to `config.yaml` (reading the key interactively via `read -s`, so it never reaches argv or the environment), starts the
proxy if the port is closed, reads the local proxy token, and runs the callability canary. Run it after first installing
CLIProxyAPI:

```bash
set +x
bash setup.sh     # prints the alias to pass as --model on dispatch when the canary passes
```

Steps 1–4 below are what the script does, spelled out, so you can do it by hand or audit the script.

**1. Bring the proxy up and get its token.** No shell alias is involved; these are the raw pieces.

```bash
set +x  # never run secret-bearing preflight commands with shell tracing enabled
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

**3. Pick the model.** `glm-5.3-flash-gonka` is the default: dispatch on it without asking. Use `AskUserQuestion`
only when the user asked for a choice or the default is missing from step 2. A model the user named earlier in the same
session is a standing answer: state it back and dispatch.

| Alias                     | GonkaRouter id                       | Context | Status                                                                          |
| ------------------------- | ------------------------------------ | ------- | ------------------------------------------------------------------------------ |
| `glm-5.3-flash-gonka`     | `zai-org/GLM-5.3-Flash`              | —       | **The default, and the only usable one.** Usable, but verify every worker's output |
| `deepseek-v4-flash-gonka` | `deepseek-ai/DeepSeek-V4-Flash-0731` | 1M      | **Broken — do not dispatch.** Degenerate-loops on trivial prompts                |
| `minimax-m2.7`            | `MiniMaxAI/MiniMax-M2.7`             | 192k    | **Broken — do not dispatch.** Reasoning inlined as literal `<think>` text         |

**Reasoning effort is inert on all three.** GonkaRouter accepts `reasoning_effort` and ignores it, measured, so do not
sweep it or promise it in a brief.

**Only GLM works.** Dispatch on `glm-5.3-flash-gonka`. DeepSeek and MiniMax fail *upstream at GonkaRouter* — they
misbehave identically when called directly, with no proxy in the path, so no proxy config can rescue them. If a user
explicitly names either, say it is known-broken, offer GLM, and dispatch on their answer.

**GLM needs a large output budget.** At `max_tokens: 64` it returns HTTP 200 with an empty text block and
`stop_reason: "max_tokens"` — a canary that only checks the status code passes on a response with no answer in it. The
step 4 canary raises the budget to 1024 for GLM for this reason.

**CLIProxyAPI must be 7.3.5 or newer — this is necessary but NOT sufficient.** On 7.2.x and older, GLM's own reasoning
leaks into the visible text on `/v1/messages` prefixed with `</arg_value><arg_key>.model="">`, which reads as a thinking log
and burns output budget. Commit `77820cb2` (issue #5872) fixed that on 7.3.5. Check with `cli-proxy-api --help | head -1`.

**But on 7.3.15 the text block is still contaminated often enough to distrust a single response.** The upgrade moved GLM's
reasoning into a proper `thinking` block, which is the right shape, but the `text` block still picks up fragments of it
plus stray tool-call framing. Measured on a trivial `Reply with exactly: 4` at 1024 output tokens:

- Upstream direct (`/v1/chat/completions`, no proxy): **8/8 clean**
- Through the proxy on `/v1/messages` (the path workers use): **7/19 clean** — roughly a third of responses leak

So this is a proxy-side translation defect, not a model defect, and it is not fixed by any config key. Both
`is-compat: true` (1/10 clean) and `is-compat: false` were measured and make it worse or no better. `thinking: levels`
breaks Claude Code outright, because Claude Code sends `level: "high"` and the proxy rejects levels it was not told
about. `max-context-length` is Codex metadata and never reaches the Messages path.

**Practical consequence: treat GLM as the only usable Gonka model, but verify each worker's output rather than assuming
it.** Because the leak is intermittent, a worker can look correct on one dispatch and corrupt on the next. Read the
files it wrote. If a worker's output contains reasoning prose, `<arg_value>`/`<arg_key>` fragments, or text the brief
never asked for, re-dispatch that chunk on a different model or do it yourself — and do not let a corrupted worker
result reach a commit.

**Adding the provider, once per machine.** If step 2 prints nothing, append this under `openai-compatibility:` in
`config.yaml`. The proxy hot-reloads on save; re-run step 2 to confirm.

```yaml
  - name: "gonkarouter"
    base-url: "https://api.gonkarouter.io/v1"
    api-key-entries:
      - api-key: "sk-..."
    models:
      - name: "zai-org/GLM-5.3-Flash"
        alias: "glm-5.3-flash-gonka"
        display-name: "GLM 5.3 Flash (Gonka)"
      - name: "deepseek-ai/DeepSeek-V4-Flash-0731"
        alias: "deepseek-v4-flash-gonka"
        display-name: "DeepSeek V4 Flash (Gonka)"
      - name: "MiniMaxAI/MiniMax-M2.7"
        alias: "minimax-m2.7"
        display-name: "MiniMax M2.7 (Gonka)"
```

The live catalogue is `GET https://api.gonkarouter.io/v1/models` with the key as a bearer token. Names on the marketing
pages lag it: models announced there are not necessarily served. The catalogue returns only `id` and `object` — no
context or pricing metadata — so a context figure in the table above has to come from the model vendor, and GLM's is
recorded as unknown rather than guessed.

**Hard request ceiling: ~200,000 tokens, input plus `max_tokens` combined.** The gateway rejects anything larger:

> `accepts up to about 200000 tokens (input plus max_tokens)`

This is the gateway's own limit, not a model window, and it is enforced on `/v1/messages` before the request reaches
the model. Claude Code sizes any non-Claude model at 200k and reserves part of it for output, so a long session can
trip this ceiling while the harness still believes it has room — the failure surfaces as an opaque
`prompt is too long`-style rejection rather than an autocompact.

Budget for it: keep `input + max_tokens` under 200000 on every request, and if a dispatch fails near the ceiling,
shrink the brief and re-dispatch rather than raising `max_tokens`. Because leaked reasoning is billed as
`output_tokens` (see the GLM failure mode below), a corrupt model can also reach this ceiling without the prompt
ever growing — the reasoning is what consumed the budget.

**4. Prove the selected alias is callable through the same Messages path workers use.** Config entries and either
`/v1/models` catalogue only advertise routing; they do not prove this account can run inference. Launch no workers until
one real canary returns HTTP 200, a normal stop, and exactly `READY` as its last non-empty text line:

```bash
MODEL="${MODEL:-glm-5.3-flash-gonka}"
PROBE_MAX_TOKENS=64
[ "$MODEL" = "minimax-m2.7" ] && PROBE_MAX_TOKENS=512
[ "$MODEL" = "glm-5.3-flash-gonka" ] && PROBE_MAX_TOKENS=1024
PROBE_BODY=$(mktemp)
# Claude Code uses ANTHROPIC_AUTH_TOKEN as Bearer auth. Feed the same header to curl
# on a dynamically allocated fd so the expanded token is absent from curl's argv.
exec {PROBE_HEADER_FD}<<<"header = \"Authorization: Bearer $CLIPROXY_TOKEN\""
PROBE_STATUS=$(
  jq -n --arg model "$MODEL" --argjson max_tokens "$PROBE_MAX_TOKENS" \
    '{model:$model,max_tokens:$max_tokens,messages:[{role:"user",content:"Reply only: READY"}]}' \
    | curl -sS --config "/dev/fd/$PROBE_HEADER_FD" -o "$PROBE_BODY" -w '%{http_code}' \
        -H 'accept: application/json' -H 'content-type: application/json' \
        --data-binary @- "http://127.0.0.1:$CLIPROXY_PORT/v1/messages"
)
exec {PROBE_HEADER_FD}<&-
PROBE_OK=false
if [ "$PROBE_STATUS" = 200 ] \
  && jq -e '
       .type == "message" and .stop_reason == "end_turn"
       and ([.content[]? | select(.type == "text") | .text] | join("\n")
           | test("(^|\\n)[[:space:]]*READY[[:space:]]*$"))
     ' "$PROBE_BODY" >/dev/null; then
  PROBE_OK=true
  echo "Gonka canary passed: $MODEL"
else
  echo "Gonka canary failed (HTTP $PROBE_STATUS); launch no workers" >&2
  if grep -Eqi '(error|code)[^0-9]{0,20}1010' "$PROBE_BODY"; then
    echo "Inconclusive Cloudflare 1010 client/edge rejection; repeat the identical request with another client" >&2
  else
    jq -r '.error.message? // .error? // "invalid response"' "$PROBE_BODY" 2>/dev/null \
      || echo "Gonka canary returned a non-JSON response" >&2
  fi
  echo "Failed response retained at $PROBE_BODY" >&2
fi
$PROBE_OK && rm -f "$PROBE_BODY"
$PROBE_OK
```

For GLM, the 1024-token budget is deliberate: at 64 it returns an empty text block with `stop_reason: "max_tokens"`.
The canary proves one call, not six-way capacity; a reliability assessment still needs the smoke sequence below.

**5. Give workers their own config dir, once per machine.** A worker under your normal `~/.claude` loads every plugin
and hook you have: measured 105,726 input tokens per turn against 19,027 with an empty config dir, and twice the wall
time. DKM and claude-mem also fire inside the worker, which you do not want.

```bash
export CLAUDE_FANOUT_CONFIG="$HOME/.claude-fanout"
mkdir -p "$CLAUDE_FANOUT_CONFIG"
```

An empty directory is a complete config: no plugins, no hooks, no memory. The worker still reads the repository's
`CLAUDE.md` and `AGENTS.md` from the working directory.

### Repeatable Reliability Smoke

Use this sequence when assessing a key, provider, or model rather than merely dispatching known-good workers:

1. Run the mandatory Messages canary above for each alias
2. Run 8 identical non-streaming calls per model at concurrency 4; record HTTP success count, final-marker count, p50,
   p95, maximum latency, stop reason, and literal `<think>` occurrences. The final marker is the last non-empty line, so
   a model that prepends reasoning does not make every answer mismatch — but a looping or tag-leaking answer still fails
   the marker check, which is the point: DeepSeek and MiniMax both fail it
3. Run one streaming call, then require a normal stop (`message_stop` through the proxy or `[DONE]` direct, never
   `length`/`max_tokens`), the reconstructed final marker, and no terminal event arriving mid-reasoning
4. Run one tool-call round trip and verify both the arguments and final answer
5. Run 6 concurrent isolated headless workers, then verify the saved exit code, JSON result, turns, permission denials,
   the exact file set from `git status --porcelain`, and exact output bytes. Use all 6 on one alias to establish per-model
   capacity; a 3+3 split establishes only mixed-model capacity

The transport/output pass threshold is exact: 8/8 HTTP 200 with normal stops and final markers, one streaming call with a
normal stop and its final marker, a correct tool round trip, and 6/6 workers with exit 0, no permission denials, an exact
file set, and exact output bytes. Any miss is
a reported reliability defect, not a passing run. Report p95 and maximum latency separately against the user's SLA;
without an SLA, latency is a measurement rather than a pass/fail claim. One slow cold call does not establish steady-state
latency.

**Measured baselines** (8 non-streaming canary calls per alias, concurrency 4, through the local proxy):

| Alias                     | p50     | max      | Status                                                                         |
| ------------------------- | ------- | -------- | ------------------------------------------------------------------------------ |
| `glm-5.3-flash-gonka`     | 85 ms   | 88 ms    | 2026-09-24, 8/8 `end_turn`, marker intact, no reasoning in text                |
| `deepseek-v4-flash-gonka` | 173 ms  | 769 ms   | Latency is fine; output is not. Degenerate-loops (`4 4 4 …`) on trivial prompts |
| `minimax-m2.7`            | 143 ms  | 9.1 s    | Latency is fine; output is not. Every reply opens with literal `<think>` text  |

The DeepSeek and MiniMax latency figures are stale-but-harmless: both models respond fast and both return unusable text.
GLM's p50 is flattered by the tiny canary prompt; real work turns grow the ceiling. Treat these as order-of-magnitude
expectations, not SLAs, and re-derive them when a provider or harness updates.

---

## Dispatch

### The Command

```bash
env -u ANTHROPIC_API_KEY \
  CLAUDE_CONFIG_DIR="$CLAUDE_FANOUT_CONFIG" \
  ANTHROPIC_BASE_URL="http://127.0.0.1:$CLIPROXY_PORT" \
  ANTHROPIC_AUTH_TOKEN="$CLIPROXY_TOKEN" \
  timeout 1500 claude -p \
    --model "${MODEL:-glm-5.3-flash-gonka}" \
    --permission-mode acceptEdits \
    --max-turns 40 \
    --output-format json \
    --disallowedTools Artifact mcp__stitch \
    < "<path to the brief>" \
    > "<log path>" 2>&1
rc=$?
printf '%s' "$rc" > "<exit code path>"
echo "exit=$rc"
exit "$rc"
```

- **`-p` reads the brief from stdin.** Put the brief in a file; an inline prompt of any length is shell-quoting
  archaeology
- **`cd` into the working directory first.** The worker's world is its cwd: that is where it reads `AGENTS.md` and where
  relative paths in the brief resolve
- **Always redirect to a log file.** The JSON result is the last line, several kilobytes long; stderr warnings come
  before it. Read it with `tail -n 1`, never `tail -c`
- **Always wrap in `timeout`.** On a proxy error Claude Code retries for about three minutes before giving up, and a
  looping worker burns `--max-turns` worth of tokens. Exit 124 means the timeout fired. The `1500` is `--max-turns` tuned:
  ~40 turns × ~30 s per turn plus retry margin; raise it when you raise the turn budget, or a slow worker gets cut off
  mid-task without a result
- **`--max-turns`** is the budget. Forty is enough for a multi-file edit with tests; ten for a single-file rewrite
- **The bearer token lands in the worker's environment.** `ANTHROPIC_AUTH_TOKEN="$CLIPROXY_TOKEN"` is visible in the
  child's `/proc/<pid>/environ` (root always, same-user via `ps eww`). On a shared box, run the dispatch through a scoped
  wrapper that unsets the token after `claude` exits, or drop the worker into its own user account

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
GonkaRouter dashboard, drawn from the monthly allowance first. Never quote the JSON figure. There is no local meter to
read instead: the proxy logs status and latency, not token counts, and GonkaRouter bills the grant with no per-model
breakdown exposed locally. To answer "was this cheaper than the plan", count dispatch attempts — each proxy error
retry, `count_tokens` call, and worker turn is still a request against the grant even when no `total_cost_usd` appears.

Check, in this order:

**Expect the worker's `result` text to contain a thinking log, and ignore it.** Measured across dispatches of a
one-line file-write task, the written file was byte-exact every time while `.result` came back prefixed with a
`<think>...` monologue **3 out of 3 times**. That string is the GLM text-block contamination described in the model
section, and it is the single most visible symptom of it. Consequences:

- **Never treat `.result` as the deliverable.** It is a status string, not output. Judge the worker on the files it
  wrote and on `.is_error`, never on what it says it did — it will narrate a thinking log and then still have done
  the work correctly.
- **Do not paste `.result` into your report to the user.** It will surface the leaked reasoning verbatim. Summarise
  the outcome in your own words.
- **Do not re-dispatch a worker over a dirty `.result` alone.** Check the actual output files first; a dirty
  `result` with correct files is the common case, and re-running wastes a dispatch.

```bash
verify_worker() {
  local log=$1 worktree=$2 exit_file=$3 expected_status=$4 expected=$5 output=$6 marker=$7 expected_count=$8 result
  result=$(tail -n 1 "$log") || return 1
  jq -e '.is_error == false and ((.permission_denials // []) | length == 0)' <<<"$result" >/dev/null \
    || { echo "worker JSON reports an error or permission denial" >&2; return 1; }
  jq -r '.result, .num_turns, .permission_denials' <<<"$result"
  [ "$(cat "$exit_file")" = 0 ] \
    || { echo "worker exit status is $(cat "$exit_file"), expected 0" >&2; return 1; }
  [ -f "$expected_status" ] \
    || { echo "expected-status fixture is missing" >&2; return 1; }
  git -C "$worktree" status --porcelain | cmp -s "$expected_status" - \
    || { echo "file set differs; expected:" >&2; cat "$expected_status" >&2; \
         echo "actual:" >&2; git -C "$worktree" status --porcelain >&2; return 1; }
  [ -f "$expected" ] && [ -f "$output" ] \
    || { echo "expected fixture or worker output is missing" >&2; return 1; }
  [ "$(grep -cF "$marker" "$output")" -eq "$expected_count" ] \
    || { echo "structural marker count differs" >&2; return 1; }
  cmp -s "$expected" "$output" \
    || { echo "exact bytes differ" >&2; return 1; }
  if grep -rnE '/home/|C:\\Users|/tmp/' "$output"; then
    echo "machine path leaked" >&2; return 1
  fi
  if grep -rnF '<think>' "$output"; then
    echo "reasoning leaked" >&2; return 1
  fi
}
verify_worker "$LOG" "$WORKTREE" "$EXIT_FILE" "$EXPECTED_STATUS" "$EXPECTED_FILE" "$OUTPUT" "$STRUCTURAL_MARKER" "$EXPECTED_COUNT"
```

Create `EXPECTED_FILE` from the required fixture, including its intended newline bytes, and `EXPECTED_STATUS` as the exact
`git status --porcelain` you expect (an empty file for a worker that must change nothing). Save the dispatch exit code to
`EXIT_FILE`; never infer it from the trailing `echo`. Workers can report success while omitting a required trailing
newline, so never synthesize the expected side inside the comparison. Then **read the parts
that carry risk**, run the tests yourself, and mutation-test any test the worker wrote. A green run from a worker proves
the worker's tests agree with the worker's code and nothing else.

Fix small defects yourself. Re-dispatch only if a chunk is broadly wrong, with the defect named in the new brief.

---

## Failure Modes Seen In The Wild

| Symptom                                                  | Cause And Fix                                                                                       |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `auth_unavailable: no auth available (providers=...)`    | You named a model outside the `gonkarouter` block, and its login is dead. Use a GonkaRouter alias   |
| `'<model>' is not served` or model id rejected           | The `gonkarouter` block is missing or the alias is misspelt. Re-run preflight step 2                 |
| Config and `/v1/models` look good, but inference fails   | Catalogues advertise routing, not account callability. Run the step 4 Messages canary; launch none unless it passes |
| Python `urllib` gets `403` with `error code: 1010`       | Treat it as an inconclusive Cloudflare client/edge rejection, not a key verdict. Keep origin, key, method, URL, body, and application headers fixed; change only the client to `curl`, `requests`, or `httpx`. Call it client-specific only after one succeeds |
| `<think>...</think>` in files or in the report           | MiniMax inlines reasoning in the text stream. Use `glm-5.3-flash-gonka`; MiniMax is not repairable by config |
| Output repeats one token over and over (`4 4 4 …`)     | DeepSeek degenerate-loops on GonkaRouter, upstream. Use `glm-5.3-flash-gonka`; not repairable by config      |
| GLM canary passes the status check but the text is empty | GLM spent the whole budget before answering. At 64 output tokens it returns HTTP 200, `stop_reason: "max_tokens"`, and no text — a status-only check passes an empty response. Require `stop_reason == "end_turn"` *and* the `READY` marker, and budget 1024 for GLM |
| Reasoning text appears in the answer with no `<think>`   | Below 7.3.5 GLM's reasoning leaks wholesale. Upgrade, then still expect ~2-in-3 leaks; re-dispatch the chunk |
| Worker exits 0 but its output is prose, `<arg_value>`, or off-brief text | GLM's text block is contaminated ~2 in 3 on 7.3.15. Not a worker bug — verify and re-dispatch            |
| `accepts up to about 200000 tokens (input plus max_tokens)` | Gateway ceiling. Split into more, smaller workers — do NOT raise `max_tokens`. See the 200k section       |
| `400 ... schema pattern is not a valid regular expression` or `"$defs" is not allowed` | GonkaRouter validates tool schemas with Go RE2 and forbids `$defs`. Six tools trip it: `Artifact` (a `{1,4096}` repeat the parser rejects) plus five `mcp__stitch` tools (apply_design_system, create_design_system, create_design_system_from_design_md, generate_variants, update_design_system) that use `$defs`/`$ref`. Disallow all six with `--disallowedTools Artifact mcp__stitch` (prefix match strips the five stitch tools at once), or run under the empty config dir where no MCP tools load. The set is version-fragile: re-derive it when a Claude Code or plugin update adds a tool |
| `429` from the proxy                                     | Over 1500 requests a minute sustained at GonkaRouter. Fewer workers, not retries; 429s are not billed |
| Exit 124, `terminal_reason":"api_error`, nothing written | The proxy rejected every call and the harness retried until the timeout. Fix the proxy first        |
| Saved worker exit code is not 0                          | A `timeout`, a proxy error-then-give-up, or a refused command. Trust the saved code, not the trailing `echo` |
| `[claude-code:unrecognized_model]` on stderr             | Harmless. Claude Code does not know the proxy model's name; the call still goes through             |
| `claude.ai connectors are disabled` on stderr            | Harmless. `ANTHROPIC_AUTH_TOKEN` takes precedence over the login, which is the point                |
| Every turn costs ~100k input tokens                      | The worker ran under your normal config dir. Set `CLAUDE_CONFIG_DIR` to the empty one               |
| Stray files or a commit in the repo                      | The brief did not say "and nothing else" or "do not run git". `git status` after every run          |
| Report says success, but exact content differs           | Reports are not byte verification. Compare an expected fixture file with the output using `cmp -s`, and test its exit status |
| `permission_denials` is non-empty                        | `acceptEdits` refused a command. Either allow it with `--allowedTools` or do that step yourself     |

---

## Reporting Back

Say which model ran, how many workers, what each produced, **and what you corrected**. The corrections are the useful
part - they tell the user whether the next fan-out should use a tighter brief or a different model.

Never present a worker's output as verified when you only checked that the file exists.
