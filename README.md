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

Enforce a minimum score in CI:

```shell
rebar3 mutate -s 80.0
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
| `--min-score` | `-s` | Minimum mutation score (0-100), fail if below | none |
| `--format` | | Output format: `console` or `json` | console |
| `--workers` | `-w` | Number of parallel workers | scheduler count |
| `--diff` | `-d` | Only mutate lines changed since a base ref (e.g. `origin/main`) | none |

## Mutation Operators

| Operator | Mutations |
|----------|-----------|
| `op_arithmetic` | `+` <-> `-`, `*` <-> `div`, `rem` <-> `div` |
| `op_relational` | `>` <-> `<`, `>=` <-> `=<`, `=:=` <-> `=/=`, `==` <-> `/=` |
| `op_boolean` | `andalso` <-> `orelse`, `true` <-> `false` |
| `op_return_value` | `ok` <-> `error` atoms and tuples |
| `op_statement_delete` | Replace function calls with `ok` |
| `op_constant` | Integer N -> N+1, N-1, 0 |
| `op_negate_condition` | Wrap `andalso`/`orelse` with `not`, remove existing `not` |
| `op_list` | `++` <-> `--`, `hd` <-> `tl` |

## Progress Indicator

During execution, a per-mutant progress indicator is printed to stderr:

- `.` -- killed
- `S` -- survived
- `T` -- timed out
- `E` -- compile error

## Interpreting Results

The plugin reports:

- **Killed** -- tests caught the mutation (good)
- **Survived** -- tests did not catch the mutation (indicates a gap)
- **Timed out** -- tests hung on the mutation
- **Compile error** -- mutation produced invalid code

The **mutation score** is the percentage of mutants killed. A higher score means your tests are more effective at catching regressions.

## Known Limitations

If your eunit tests live outside the `<module>_tests.erl` convention (e.g. one central `myapp_tests.erl` for the whole app), the runner won't find them and every mutant will read as survived. Tracked in [#13](https://github.com/Taure/rebar3_mutate/issues/13). Colocated `<module>_tests.erl` files and Common Test suites are unaffected.

## License

MIT -- see [LICENSE](LICENSE).
