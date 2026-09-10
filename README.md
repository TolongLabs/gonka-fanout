![Gonka Fan-Out](assets/gonka-fanout-banner.png)

# Gonka Fan-Out

![Claude Code skill](https://img.shields.io/badge/Claude_Code_skill-D97757?style=for-the-badge&logo=claude&logoColor=white)
![GonkaRouter](https://img.shields.io/badge/GonkaRouter-1B1F3B?style=for-the-badge)
![CLIProxyAPI](https://img.shields.io/badge/CLIProxyAPI-000000?style=for-the-badge)
![MIT licence](https://img.shields.io/badge/MIT_licence-blue?style=for-the-badge)

**Fan work out to headless Claude Code workers on GonkaRouter through CLIProxyAPI, up to six at once.**

> The worker does the bulk, you keep the judgement.

_Fan-out_ is dispatching many independent workers at once and reviewing what comes back.

## Table of Contents

<details>
  <summary>Expand</summary>
  <ol>
    <li><a href="#what-it-does">What It Does</a></li>
    <li><a href="#quick-start">Quick Start</a></li>
    <li><a href="#which-model-to-use">Which Model to Use</a></li>
    <li><a href="#how-it-stays-safe">How It Stays Safe</a></li>
    <li><a href="#what-it-cannot-do">What It Cannot Do</a></li>
    <li><a href="#under-the-hood">Under the Hood</a></li>
    <li><a href="#go-deeper">Go Deeper</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#licence">Licence</a></li>
  </ol>
</details>

## What It Does

- **Headless Claude Code Workers on a Cheap GonkaRouter Model.** Each worker is the full Claude Code agent in one
  directory, pointed at CLIProxyAPI so it spends a GonkaRouter monthly token allowance instead of the Claude plan. The
  idea is the same as Claude Fan-Out, but the allowance is drawn down instead of the plan.
- **You Write the Brief, It Writes the Files, You Review.** The worker reads the repository's `AGENTS.md` and
  `CLAUDE.md` on its own, so the brief carries the task and not the house rules.
- **Up to Six at Once.** Launch them in parallel, each with its own brief, log and worktree, and never let two workers
  write the same file.
- **A Real Harness.** It gives you `--max-turns`, a real exit code and JSON output, and it reads `AGENTS.md` and
  `CLAUDE.md` on its own.

If a task needs your judgement or your conversation context, you do not need this skill.

## Quick Start

1. **Check the Prerequisites.** You need Claude Code, CLIProxyAPI installed and configured with a `gonkarouter` block,
   and `curl` and `jq`.

1. **Clone Into the Global Skills Directory**, then restart Claude Code so the skill loads. It is available as
   `/gonka-fanout` from then on.

   ```bash
   git clone https://github.com/TolongLabs/gonka-fanout ~/.claude/skills/gonka-fanout
   ```

1. **Wire It All Up With One Command.** [`setup.sh`](setup.sh) adds the `gonkarouter` block (reading the key via
   `read -s`, never into argv or the environment), starts the proxy, and runs the callability canary. Skip the next two
   steps if it prints your alias.

   ```bash
   set +x
   bash setup.sh
   ```

1. **Bring the Proxy Up and Choose a Model.** Start the proxy if its port is closed, then list the GonkaRouter models
   it serves. Only the `gonkarouter` block of its config counts. Never print the token, which is a local secret and
   leaks into transcripts.

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

   ```bash
   sed -n '/name: "gonkarouter"/,/^  - name: "/p' "$CLIPROXY_DIR/config.yaml" | grep -E '^\s+alias:' | tr -d '" ' | cut -d: -f2
   ```

1. **Add the Provider, Once per Machine.** If the previous step prints nothing, append this under
   `openai-compatibility:` in `config.yaml`. The proxy hot-reloads on save; re-run the previous step to confirm. The
   live catalogue is `GET https://api.gonkarouter.io/v1/models` with the key as a bearer token.

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

1. **Prove the Selected Alias Is Callable.** A config entry or either `/v1/models` catalogue only advertises routing;
   neither proves the account can run inference. Run the real Messages canary in
   [`SKILL.md`, preflight step 4](SKILL.md#preflight-in-order), using 512 output tokens for MiniMax. Launch no workers
   unless it returns HTTP 200, `stop_reason: end_turn`, and `READY` as the last non-empty text line.

1. **Dispatch Your First Worker.** Export `CLAUDE_FANOUT_CONFIG` to an empty directory once per machine, so the worker
   does not load your plugins, hooks or memory. Then `cd` into the working directory, put the brief in a file, pick a
   model from the previous step, and dispatch:

   ```bash
   export CLAUDE_FANOUT_CONFIG="$HOME/.claude-fanout"
   mkdir -p "$CLAUDE_FANOUT_CONFIG"

   env -u ANTHROPIC_API_KEY \
     CLAUDE_CONFIG_DIR="$CLAUDE_FANOUT_CONFIG" \
     ANTHROPIC_BASE_URL="http://127.0.0.1:$CLIPROXY_PORT" \
     ANTHROPIC_AUTH_TOKEN="$CLIPROXY_TOKEN" \
     timeout 1500 claude -p \
       --model "${MODEL:-deepseek-v4-flash-gonka}" \
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

1. **Verify.** The `total_cost_usd` in the JSON result is fictional, because the proxy served the model, so never quote
   it. Real usage is on the GonkaRouter dashboard. Read the report, then run the tests yourself, because a green run
   from a worker proves the worker's tests agree with the worker's code and nothing else:

   ```bash
   (
     set -e
     [ "$(cat "$EXIT_FILE")" = 0 ]                                   # saved exit code, not the trailing echo
     RESULT=$(tail -n 1 "$LOG")
     jq -e '.is_error == false and ((.permission_denials // []) | length == 0)' <<<"$RESULT" >/dev/null
     jq -r '.result, .num_turns, .permission_denials' <<<"$RESULT"
     git -C "$WORKTREE" status --porcelain | cmp -s "$EXPECTED_STATUS" -   # exact file set, no strays
     [ "$(grep -cF "$STRUCTURAL_MARKER" "$OUTPUT")" -eq "$EXPECTED_COUNT" ]
     cmp -s "$EXPECTED_FILE" "$OUTPUT"                                 # exact bytes, including final newline
     if grep -rnE '/home/|C:\\Users|/tmp/' "$OUTPUT"; then exit 1; fi
     if grep -rnF '<think>' "$OUTPUT"; then exit 1; fi
   )
   ```

   Create `EXPECTED_FILE` from the required fixture, including its intended newline bytes, and `EXPECTED_STATUS` as the
   exact `git status --porcelain` you expect. The full reusable verifier is in
   [`SKILL.md`](SKILL.md#verifying-which-is-not-optional).

## Which Model to Use

Only models in the `gonkarouter` block of the proxy config are offered, and `deepseek-v4-flash-gonka` is the default:
dispatch on it without asking. Reasoning effort is inert on both: GonkaRouter accepts `reasoning_effort` and ignores
it, measured. `SKILL.md` shows the lines that add a model to the proxy.

| Alias                     | GonkaRouter id                       | Context | Notes                                                        |
| ------------------------- | ------------------------------------ | ------- | ------------------------------------------------------------ |
| `deepseek-v4-flash-gonka` | `deepseek-ai/DeepSeek-V4-Flash-0731` | 1M      | **The default.** Clean text, clean tool calls                |
| `minimax-m2.7`            | `MiniMaxAI/MiniMax-M2.7`             | 192k    | Literal `<think>` in every reply; low output limits may contain no final answer |

Inference on the Gonka network is priced around $0.0012 per million tokens, and it floats with network utilisation. A
monthly token allowance, where one exists, is drawn down before paid credit and expires unused.

## How It Stays Safe

A worker writes files under one of three permission modes:

| Mode                | Auto-Approves                   | Use When                                                                  |
| ------------------- | ------------------------------- | ------------------------------------------------------------------------- |
| `acceptEdits`       | Reads and edits in the cwd      | **The default.** Files only; every Bash command is refused unless allowed |
| `bypassPermissions` | Everything                      | Only in a scratch directory or worktree you will throw away               |
| `default`           | Nothing; every prompt is denied | Read-only analysis. Anything not allowed is refused, and it carries on    |

- **Give a Worker a `git worktree`, Never Your Checkout.** A half-done or looping run then costs one worktree removal,
  not a reconstruction, and two workers never share a working tree.
- **Say `do not run git` in Every Brief.** The worker can, and a commit from a worker is a commit nobody reviewed.

## What It Cannot Do

- **The Cost Figure Is Fictional.** The JSON result reports `total_cost_usd` as if Anthropic served the model, and the
  real usage is on the GonkaRouter dashboard, drawn from the monthly allowance first. Never quote the JSON figure.
- **The System Prompt Is Not Free.** A worker under your normal config dir costs 105,726 input tokens per turn against
  19,027 with an empty one, at twice the wall time, because it loads every plugin and hook you have.
- **Six Concurrent Workers Is the Ceiling.** Past that they contend for the same files and the review cost exceeds the
  saving.
- **A Proxy Error Costs About Three Minutes.** On one, Claude Code retries until it gives up, and a looping worker burns
  `--max-turns` worth of credit, which is why every dispatch wraps in `timeout`.
- **A Worker Has None of Your Context.** Everything it needs goes in the brief, and if the brief takes longer to write
  than the task takes to do, do the task.
- **MiniMax Leaks Its `<think>` Text.** Reasoning arrives as literal `<think>` text inside every reply. A low output
  limit can end at `length`/`max_tokens` before any final answer; retry with at least 512 tokens before calling that a
  reliability failure. Prefer `deepseek-v4-flash-gonka` when the leak matters.

## Under the Hood

Every worker is one command, and every failure shows up around it:

<details>
<summary><b>The Dispatch Command</b></summary>

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
    --disallowedTools Artifact mcp__stitch \
    < "<path to the brief>" \
    > "<log path>" 2>&1
rc=$?
printf '%s' "$rc" > "<exit code path>"
echo "exit=$rc"
exit "$rc"
```

- **`-p` Reads the Brief From stdin.** Put the brief in a file; an inline prompt of any length is shell-quoting
  archaeology
- **`cd` Into the Working Directory First.** The worker's world is its cwd: that is where it reads `AGENTS.md` and where
  relative paths in the brief resolve
- **Always Redirect to a Log File.** The JSON result is the last line, several kilobytes long, and stderr warnings come
  before it. Read it with `tail -n 1`, never `tail -c`
- **Always Wrap in `timeout`.** On a proxy error Claude Code retries for about three minutes before giving up, and a
  looping worker burns `--max-turns` worth of credit. Exit 124 means the timeout fired
- **`--max-turns` Is the Budget.** Forty is enough for a multi-file edit with tests; ten for a single-file rewrite
- **The Bearer Token Lands in the Worker's Environment.** `ANTHROPIC_AUTH_TOKEN="$CLIPROXY_TOKEN"` is visible in the
  child's `/proc/<pid>/environ` (root always, same-user via `ps eww`). On a shared box, run the dispatch through a scoped
  wrapper that unsets the token after `claude` exits, or drop the worker into its own user account

</details>

<details>
<summary><b>Failure Modes</b></summary>

| Symptom                                                  | Cause And Fix                                                                                       |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `auth_unavailable: no auth available (providers=...)`    | You named a model outside the `gonkarouter` block, and its login is dead. Use a GonkaRouter alias   |
| `'<model>' is not served` or model id rejected           | The `gonkarouter` block is missing or the alias is misspelt. Re-run preflight step 2                 |
| Config and `/v1/models` look good, but inference fails   | Catalogues advertise routing, not callability. Run the real Messages canary; launch none unless it passes |
| Python `urllib` gets `403` with `error code: 1010`       | Treat it as an inconclusive Cloudflare client/edge rejection, not a key verdict. Repeat the same request and credential from the same host with `curl`, `requests`, or `httpx`; call it client-specific only after one succeeds |
| `<think>...</think>` in files or in the report           | MiniMax through GonkaRouter puts reasoning in the text stream. Use `deepseek-v4-flash-gonka`        |
| HTTP 200 ends at `length`/`max_tokens` inside `<think>`  | The output was truncated before MiniMax's final answer. Retry with at least 512 output tokens and require a normal stop |
| `<think>` comes out as ` thinking` in worker output      | DeepSeek on GonkaRouter rewrites the literal tag. Write it as `&lt;think&gt;` in briefs, or fix by hand   |
| `400 ... schema pattern is not a valid regular expression` or `"$defs" is not allowed` | GonkaRouter validates tool schemas with Go RE2 and forbids `$defs`. Six tools trip it: `Artifact` (a `{1,4096}` repeat the parser rejects) plus five `mcp__stitch` tools (apply_design_system, create_design_system, create_design_system_from_design_md, generate_variants, update_design_system) that use `$defs`/`$ref`. Disallow all six with `--disallowedTools Artifact mcp__stitch`, or run under the empty config dir where no MCP tools load. The set is version-fragile: re-derive it when a Claude Code or plugin update adds a tool |
| `429` from the proxy                                     | Over 1500 requests a minute sustained at GonkaRouter. Fewer workers, not retries; 429s are not billed |
| Exit 124, `terminal_reason":"api_error`, nothing written | The proxy rejected every call and the harness retried until the timeout. Fix the proxy first        |
| `[claude-code:unrecognized_model]` on stderr             | Harmless. Claude Code does not know the proxy model's name; the call still goes through             |
| `claude.ai connectors are disabled` on stderr            | Harmless. `ANTHROPIC_AUTH_TOKEN` takes precedence over the login, which is the point                |
| Every turn costs ~100k input tokens                      | The worker ran under your normal config dir. Set `CLAUDE_CONFIG_DIR` to the empty one               |
| Stray files or a commit in the repo                      | The brief did not say "and nothing else" or "do not run git". `git status` after every run          |
| Report says success, but exact content differs           | Reports are not byte verification. Compare an expected fixture file with the output using `cmp -s`, and test its exit status |
| Worker created extra files                               | The brief did not say "and nothing else", and the verifier never asserted the file set. Save the exit code and compare `git status --porcelain` against an `EXPECTED_STATUS` fixture |
| Saved worker exit code is not 0                          | A `timeout`, a proxy error-then-give-up, or a refused command. Trust the saved code, not the trailing `echo` |
| `permission_denials` is non-empty                        | `acceptEdits` refused a command. Either allow it with `--allowedTools` or do that step yourself     |

</details>

## Go Deeper

| Read                   | When                                                                                     |
| ---------------------- | ---------------------------------------------------------------------------------------- |
| [`SKILL.md`](SKILL.md) | You are writing a brief or a report: preflight, dispatch, verification and failure modes |

## Contributing

Issues and pull requests are welcome.

## Licence

[MIT](LICENSE). Copyright 2026 TolongLabs.
