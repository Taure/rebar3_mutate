# rebar3_mutate

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

Select specific operators:

```shell
rebar3 mutate -o op_arithmetic,op_boolean
```

Set a per-mutant timeout:

```shell
rebar3 mutate -t 10000
```

## Options

| Flag | Short | Description | Default |
|------|-------|-------------|---------|
| `--module` | `-m` | Target module(s), comma-separated | all |
| `--operators` | `-o` | Mutation operators to use, comma-separated | all |
| `--timeout` | `-t` | Per-mutant timeout in milliseconds | 5000 |

## Mutation Operators

| Operator | Mutations |
|----------|-----------|
| `op_arithmetic` | `+` <-> `-`, `*` <-> `div`, `rem` <-> `div` |
| `op_relational` | `>` <-> `<`, `>=` <-> `=<`, `=:=` <-> `=/=`, `==` <-> `/=` |
| `op_boolean` | `andalso` <-> `orelse`, `true` <-> `false` |
| `op_return_value` | `ok` <-> `error` atoms and tuples |

## Interpreting Results

The plugin reports:

- **Killed** -- tests caught the mutation (good)
- **Survived** -- tests did not catch the mutation (indicates a gap)
- **Timed out** -- tests hung on the mutation
- **Compile error** -- mutation produced invalid code

The **mutation score** is the percentage of mutants killed. A higher score means your tests are more effective at catching regressions.

## License

MIT -- see [LICENSE](LICENSE).
