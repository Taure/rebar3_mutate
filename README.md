# rebar3_mutate

Mutation testing plugin for rebar3. Systematically introduces small code changes (mutants) and verifies your tests catch them. A higher mutation score means your tests are more effective at preventing regressions.

## Quick Start

Add to `project_plugins` in your `rebar.config`:

```erlang
{project_plugins, [rebar3_mutate]}.
```

Run mutation testing:

```shell
$ rebar3 mutate
===> Running baseline tests...
===>   my_module: baseline passed (42ms)
===> my_module: 37 mutation points found
..S..S....T........
============================================================
Module: my_module (37 mutants, 34 killed, 2 survived, 1 timed out)
Score:  94.4%

Surviving mutants:
  line 25 [op_arithmetic] A + 1 -> A - 1
  line 48 [op_boolean] true -> false
============================================================

Overall: 34/37 mutants killed
```

## How It Works

1. **Baseline check** -- runs your tests unmutated to ensure they pass
2. **Mutation** -- applies small code changes (one at a time) via AST transformation
3. **Testing** -- runs your test suite against each mutant
4. **Reporting** -- shows which mutations survived (test gaps) and your mutation score

A **killed** mutant means your tests caught the change. A **survived** mutant means your tests would still pass even with a bug -- that's a gap you should fix.

## Local Development

### Basic usage

```shell
# Test all modules
rebar3 mutate

# Target specific modules
rebar3 mutate -m my_module,my_other_module

# Target specific functions
rebar3 mutate --function my_module:handle_call/3

# Exclude generated code
rebar3 mutate -x my_generated_module

# Use only specific operators
rebar3 mutate -o op_arithmetic,op_boolean,op_return_value
```

### Faster local iteration

```shell
# Only mutate code you changed (vs main branch)
rebar3 mutate --diff main

# Use result caching -- killed mutants are remembered across runs
rebar3 mutate --cache

# Combine both for fastest iteration
rebar3 mutate --diff main --cache

# Target just the function you're working on
rebar3 mutate --function my_module:process/2 --cache
```

### Output formats

```shell
# Console output (default) -- human-readable
rebar3 mutate

# JSON -- custom format for scripting
rebar3 mutate --format json

# MTE -- mutation-testing-elements standard (language-agnostic schema)
rebar3 mutate --format mte

# HTML -- interactive report you can open in a browser
rebar3 mutate --format html
rebar3 mutate --format html --html-out report.html
```

The HTML report uses the [mutation-testing-elements](https://github.com/stryker-mutator/mutation-testing-elements) web component, giving you an interactive view with inline source diffs, filtering by status, and per-file drill-down.

### Common Test support

```shell
rebar3 mutate -f ct
```

## CI Integration

### GitHub Actions

```yaml
name: Mutation Testing
on: [pull_request]

jobs:
  mutate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # needed for --diff

      - uses: erlef/setup-beam@v1
        with:
          otp-version: '28'
          rebar3-version: '3.24'

      - name: Compile
        run: rebar3 compile

      - name: Mutation testing (diff only)
        run: rebar3 mutate --diff main --min-score 80.0 --format html

      - name: Upload report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: mutation-report
          path: mutate_report.html
```

Surviving mutants automatically appear as **inline annotations** on the PR diff when running in GitHub Actions.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | All mutants caught (or above `--min-score` threshold) |
| 1 | Usage error |
| 2 | Mutation score below `--min-score` threshold |
| 3 | Mutants timed out (none survived, but timeouts occurred) |
| 4 | Baseline tests failed (tests don't pass without mutations) |

### Profiles

Define CI and local profiles in `rebar.config`:

```erlang
{mutate, [
    {profiles, #{
        ci => #{
            min_score => 80.0,
            diff => "main",
            format => "mte",
            skip_baseline => false
        },
        local => #{
            format => "console",
            cache => true
        },
        strict => #{
            min_score => 95.0,
            format => "html"
        }
    }}
]}.
```

Use a profile:

```shell
rebar3 mutate --profile ci
rebar3 mutate --profile local
```

CLI flags override profile values.

### Sharding for parallel CI

Split mutation testing across CI matrix jobs:

```yaml
jobs:
  mutate:
    strategy:
      matrix:
        shard: [0, 1, 2, 3]
    steps:
      # ... setup steps ...
      - run: rebar3 mutate --shard ${{ matrix.shard }}/4 --skip-baseline --min-score 80.0
```

### Performance tips for CI

| Technique | Flag | Speedup |
|-----------|------|---------|
| Diff-only | `--diff main` | Only mutate changed code |
| Skip baseline | `--skip-baseline` | Skip if CI already ran tests |
| Sharding | `--shard k/n` | Split across matrix jobs |
| Caching | `--cache` | Reuse killed results across runs |
| Fewer operators | `-o op_arithmetic,...` | Reduce mutation count |

### Timeout handling

By default, per-mutant timeout is calculated automatically:

- **With baseline**: `max(2s, baseline_duration * 5)`
- **Without baseline** (skip-baseline): falls back to 5 seconds
- **Explicit**: `--timeout 10000` overrides everything

When using `--skip-baseline`, set `--timeout` explicitly if your tests are slow.

## Options Reference

| Flag | Short | Description | Default |
|------|-------|-------------|---------|
| `--module` | `-m` | Target module(s), comma-separated | all |
| `--exclude` | `-x` | Modules to exclude, comma-separated | none |
| `--function` | | Target function(s), e.g. `mod:fun/arity` | all |
| `--operators` | `-o` | Mutation operators to use | all |
| `--timeout` | `-t` | Per-mutant timeout in ms | auto |
| `--test-framework` | `-f` | `eunit` or `ct` | eunit |
| `--min-score` | `-s` | Minimum score (0-100), fail if below | none |
| `--format` | | `console`, `json`, `mte`, or `html` | console |
| `--html-out` | | HTML report output path | mutate_report.html |
| `--workers` | `-w` | Parallel workers | scheduler count |
| `--diff` | `-d` | Only mutate lines changed vs base branch | disabled |
| `--skip-baseline` | | Skip baseline test run | false |
| `--profile` | `-p` | Use named profile from rebar.config | none |
| `--cache` | | Cache results across runs | false |
| `--shard` | | Shard spec `k/n` (0-indexed) | disabled |

## Mutation Operators

### Core operators

| Operator | What it does | Example |
|----------|-------------|---------|
| `op_arithmetic` | Swap arithmetic operators | `A + B` -> `A - B` |
| `op_relational` | Swap comparison operators | `X > Y` -> `X < Y` |
| `op_boolean` | Swap boolean logic | `andalso` -> `orelse`, `true` -> `false` |
| `op_return_value` | Swap ok/error returns | `{ok, V}` -> `{error, V}` |
| `op_statement_delete` | Remove function calls | `foo(X)` -> `ok` |
| `op_constant` | Modify integer literals | `5` -> `6`, `0`, `4` |
| `op_negate_condition` | Negate/unwrap conditions | `not X` -> `X`, `A andalso B` -> `not (A andalso B)` |
| `op_list` | Swap list operations | `++` -> `--`, `hd` -> `tl` |

### BEAM-specific operators

| Operator | What it does | Example |
|----------|-------------|---------|
| `op_guard` | Remove guard BIF checks | `is_integer(X)` -> `true` |
| `op_exception` | Swap exception types | `throw(R)` -> `error(R)` |
| `op_map` | Remove map fields | `#{a => 1, b => 2}` -> `#{b => 2}` |
| `op_binary` | Mutate binary field sizes | `<<X:8>>` -> `<<X:9>>` |
| `op_clause_swap` | Reorder case clauses | `case X of a -> 1; b -> 2 end` -> `case X of b -> 2; a -> 1 end` |
| `op_receive` | Mutate receive timeouts | `after 1000 ->` -> `after 1001 ->` |

## Understanding Results

### Progress indicator

During execution, per-mutant progress prints to stderr:

```
...SS..T....E.......
```

- `.` killed (test caught the mutation)
- `S` survived (test gap -- needs attention)
- `T` timed out (mutation caused infinite loop/hang)
- `E` compile error (mutation produced invalid code, excluded from score)

### Score calculation

```
mutation_score = killed / (total - compile_errors) * 100
```

Compile errors are excluded since they represent invalid mutations, not test gaps.

### What to do with surviving mutants

1. **Read the mutation description** -- it tells you what changed and where
2. **Ask: should my tests catch this?** -- not every mutation is worth killing
3. **Write a test** that would fail with the mutation applied
4. **Re-run with caching** -- `rebar3 mutate --cache` skips already-killed mutants

### Typical scores

- **< 60%** -- significant test gaps, tests mostly check happy paths
- **60-80%** -- reasonable coverage, common in production codebases
- **80-90%** -- strong test suite, good confidence in regression detection
- **> 90%** -- excellent, typical only for core/critical modules

## Caching

Enable caching to speed up repeated runs:

```shell
rebar3 mutate --cache
```

Results are stored in `.mutate_cache/results.term`. Cache entries are keyed by `{module, operator, line, source_hash}` -- when you change a source file, its cache entries automatically invalidate.

Add `.mutate_cache/` to `.gitignore`.

## Architecture

rebar3_mutate operates entirely at the Erlang AST level with no external dependencies:

1. Parse source files with `epp:parse_file/2`
2. Walk the AST with `erl_syntax_lib:fold/3` to discover mutation points
3. Apply mutations with `erl_syntax_lib:mapfold/3`
4. Compile mutated forms in-memory with `compile:forms/2`
5. Hot-load the mutant binary with `code:load_binary/3`
6. Run tests against the mutant
7. Restore the original module

No files are written to disk during mutation. The BEAM's hot code loading makes this fast.

## License

MIT -- see [LICENSE](LICENSE).
