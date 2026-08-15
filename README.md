# rebar3_mutate

<p align="center">
  <a href="https://github.com/Taure/rebar3_mutate/actions/workflows/ci.yml"><img src="https://github.com/Taure/rebar3_mutate/actions/workflows/ci.yml/badge.svg" alt="Build Status"></a>
  <a href="https://hex.pm/packages/rebar3_mutate"><img src="https://img.shields.io/hexpm/v/rebar3_mutate.svg" alt="Hex.pm"></a>
  <a href="https://hexdocs.pm/rebar3_mutate/"><img src="https://img.shields.io/badge/docs-hexdocs-blue.svg" alt="Docs"></a>
  <a href="https://erlef.org/slack-invite/erlanger"><img src="https://img.shields.io/badge/chat-Erlang%20Slack-4A154B.svg" alt="Slack"></a>
</p>

Mutation testing plugin for rebar3. Systematically applies small code transformations (mutants) and runs your tests to verify they catch them.

## Installation

Add to `project_plugins` in your `rebar.config`:

```erlang
{project_plugins, [rebar3_mutate]}.
```

## Usage

Run against all modules:

```shell
rebar3 mutate
```

Target specific modules:

```shell
rebar3 mutate -m my_module,my_other_module
```

Exclude modules:

```shell
rebar3 mutate -x generated_module,test_helper
```

Select specific operators:

```shell
rebar3 mutate -o op_arithmetic,op_boolean
```

Set a per-mutant timeout:

```shell
rebar3 mutate -t 10000
```

Use Common Test instead of EUnit:

```shell
rebar3 mutate -f ct
```

Each module runs `<module>_SUITE` by default. Override it with `--suite`:

```shell
rebar3 mutate -f ct --suite my_integration_SUITE
```

Enforce a minimum score in CI:

```shell
rebar3 mutate -s 80
```

Output JSON for CI integration:

```shell
rebar3 mutate --format json
```

Control parallelism:

```shell
rebar3 mutate -w 4
```

Only mutate lines changed since a base ref (fast enough to run on every PR):

```shell
rebar3 mutate --diff origin/main
```

## In CI

[`Taure/erlang-ci`](https://github.com/Taure/erlang-ci) ships a ready-made action:

```yaml
- uses: Taure/erlang-ci/mutate@v2.1.1
  with:
    min-score: '80'
    diff: 'true'
    diff-base: 'origin/main'
```

## Options

| Flag | Short | Description | Default |
|------|-------|-------------|---------|
| `--module` | `-m` | Target module(s), comma-separated | all |
| `--exclude` | `-x` | Modules to exclude, comma-separated | none |
| `--operators` | `-o` | Mutation operators to use, comma-separated | all |
| `--timeout` | `-t` | Per-mutant timeout in milliseconds | 5000 |
| `--test-framework` | `-f` | Test framework: `eunit` or `ct` | eunit |
| `--suite` | | Common Test suite to run | `<module>_SUITE` |
| `--min-score` | `-s` | Minimum mutation score (0-100), fail if below | none |
| `--format` | | Output format: `console` or `json` | console |
| `--workers` | `-w` | Workers used to compile mutants in parallel | scheduler count |
| `--diff` | `-d` | Only mutate lines changed since a base ref (e.g. `origin/main`) | none |

`--workers` parallelises mutant *compilation* only. Mutants are loaded and tested one at a time, because the code server holds at most two versions of a module.

## Mutation Operators

| Operator | Mutations |
|----------|-----------|
| `op_arithmetic` | `+` <-> `-`, `*` <-> `div`, `rem` -> `div` |
| `op_relational` | `>` <-> `<`, `>=` <-> `=<`, `=:=` <-> `=/=`, `==` <-> `/=` |
| `op_boolean` | `andalso` <-> `orelse`, `true` <-> `false` |
| `op_return_value` | `ok` <-> `error` atoms and tuples |
| `op_statement_delete` | Replace function calls with `ok` |
| `op_constant` | Integer N -> N+1, N-1, 0 |
| `op_negate_condition` | Wrap `andalso`/`orelse` with `not`, remove existing `not` |
| `op_list` | `++` <-> `--`, `hd` <-> `tl` (including `erlang:hd/1` and `erlang:tl/1`) |

Only function bodies defined in the module's own source are mutated. Attributes carry no runtime behaviour, so mutating a `-spec` type atom or an `-export` arity produces a mutant that is either inert or a guaranteed compile error. Test functions (`*_test/0`, `*_test_/0`) and anything pulled in from an include are skipped for the same reason.

## Baseline

Before mutating a module, the plugin runs its tests unmutated:

- **green** -- proceed, and use the measured suite time to sanity-check `--timeout`
- **red** -- fail the run; a mutation score computed against a failing suite is meaningless, because every mutant reads as killed
- **no tests** -- skip the module and report it as skipped rather than scoring it 0%

## Progress Indicator

During execution, a per-mutant progress indicator is printed to stderr:

- `.` -- killed
- `S` -- survived
- `T` -- timed out
- `E` -- compile error
- `-` -- skipped

## Interpreting Results

The plugin reports:

- **Killed** -- tests caught the mutation (good)
- **Survived** -- tests did not catch the mutation (indicates a gap)
- **Timed out** -- tests hung on the mutation
- **Compile error** -- mutation produced invalid code
- **Skipped** -- the mutant could not be evaluated (for example a worker crashed)

The **mutation score** is `killed / (killed + survived + timed out)`. Compile errors and skipped mutants never ran a test, so they are excluded from the denominator. This is the same number `--min-score` gates on.

## Known Limitations

The plugin cannot mutate itself. It swaps modules in the one code server it
shares with the code under test, so a mutant of one of its own modules would
replace code the run is executing; restoring the original then has to purge a
version a live process is using, which kills that process. Its own modules are
reported as skipped with the reason `self_mutation`.

If your EUnit tests live outside the `<module>_tests.erl` convention (for example one central `myapp_tests.erl` for the whole app), the plugin cannot associate them with the module under test. Such modules are reported as skipped rather than scored, so the number stays honest, but they are not covered. Tracked in [#13](https://github.com/Taure/rebar3_mutate/issues/13); coverage-guided test selection is the fix. Colocated `<module>_tests.erl` files and Common Test suites are unaffected.

## License

MIT -- see [LICENSE](LICENSE).
