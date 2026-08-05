# Namespace RBE performance investigation

## Summary

Two independent bottlenecks limited a clean local Bazel state backed by a warm Namespace remote
cache:

1. All 70 `TextReplace` actions consumed Bazel's volatile workspace status file, even for normal
   unstamped builds that did not use status substitutions. Bazel therefore executed those actions
   on every invocation instead of accepting cached results.
2. Namespace's generated configuration used `--jobs=32`. The recursive `packages/...` build has
   enough cache lookups for this limit to serialize much of the build, despite the client having
   only four vCPUs.

The changes on this branch make workspace status inputs opt-in for `TextReplace`, recognize
Namespace's remote worker path, and provide a `namespace-rbe` configuration with 128 concurrent
jobs, remote `JsRunBinary` execution, and minimal output downloading.

Use the same-target-set configuration with:

```shell
bazelisk --bazelrc=/home/devbox/.bazelrc clean
bazelisk --bazelrc=/home/devbox/.bazelrc build --config=namespace-rbe packages/...
```

This still builds the same recursive `packages/...` target pattern. Minimal output downloading
leaves remotely produced artifacts in the CAS; override it with `--remote_download_outputs=toplevel`
when a later local process needs the top-level artifacts. The first build after changing the
`TextReplace` action keys may execute those actions once to populate the remote cache. Later builds,
including builds after `bazel clean`, can reuse them.

## Test environment

- Angular commit: `337053ef1ab6400c3641984511b45c341d306e87`
- Bazel: 8.7.0
- Namespace S devbox: 4 vCPUs and 8 GB RAM
- Remote cache: warm
- Local Bazel state: removed with `bazelisk clean` before every measured build
- Output policy: `--remote_download_outputs=minimal`
- `JsRunBinary` actions: allowed to execute remotely after recognizing Namespace's worker path
- Recursive build graph: 3,887 requested targets, 72,074 configured targets, and 35,261 progress
  actions (31,280 processes)

The measured wall time includes the Bazel client process. Profiles and BEP JSON files were written
outside the repository under `/tmp/angular-rbe-bench`.

## Same-target-set results

| Configuration                             | Wall time | Critical path | Remote cache hits | Remote executions |
| ----------------------------------------- | --------: | ------------: | ----------------: | ----------------: |
| Original behavior, 32 jobs                |   122.94s |        25.02s |            19,141 |                70 |
| Cacheable `TextReplace`, 32 jobs          |    93.40s |        11.74s |            19,211 |                 0 |
| Original volatile `TextReplace`, 128 jobs |    55.10s |        23.33s |            19,141 |                70 |
| Cacheable `TextReplace`, 64 jobs          |    61.35s |        17.69s |            19,211 |                 0 |
| Cacheable `TextReplace`, 128 jobs, run 1  |    40.49s |        11.85s |            19,211 |                 0 |
| Cacheable `TextReplace`, 128 jobs, run 2  |    42.37s |        15.98s |            19,211 |                 0 |
| Cacheable `TextReplace`, 128 jobs, run 3  |    39.70s |        12.57s |            19,211 |                 0 |
| Checked-in `namespace-rbe` config, run 4  |    43.55s |        12.62s |            19,211 |                 0 |
| Config without `.bazelrc.user`, run 5     |    40.01s |        11.95s |            19,211 |                 0 |
| Cacheable `TextReplace`, 200 jobs         |    44.94s |        16.96s |            19,211 |                 0 |

The five final 128-job runs averaged **41.22s**, with a **39.70–43.55s** range. Their critical path
averaged **12.99s**. Run 5 excluded `.bazelrc.user` to verify that the checked-in config and module
patch contain all required Namespace compatibility settings.

### Improvements

- Making `TextReplace` cacheable reduced the same-session 32-job result by **24.0%** and eliminated
  all 70 recurring remote executions.
- At 128 jobs, eliminating those 70 executions reduced wall time from 55.10s to the 41.22s final
  average, a **25.2%** improvement. This control isolates the rule change from concurrency.
- Raising concurrency from 32 to 128 jobs reduced the patched result from 93.40s to 41.22s, a
  **55.9%** improvement.
- The combined result was **54.2% faster** than the 90.104s average from reports 8–10 and doubled
  the speed of the 82.49s warm XL RBE result from report 7 (**50.0% less wall time**).
- Compared with report 1's 315.987s empty-cache local build, the final RBE result used **87.0% less
  wall time**, a **7.67x speedup**.
- Compared with the 135.675s remote-cache-only average from reports 3–5, it used **69.6% less wall
  time**, a **3.29x speedup**.

The 200-job result did not improve on 128 jobs. More concurrency increases pressure on the Bazel
client and remote service, so 128 is the measured choice for this graph rather than an assumption
that the highest possible value is best.

## Why `TextReplace` missed the cache

The upstream `text_replace` rule unconditionally declared both `ctx.version_file` and
`ctx.info_file` as action inputs. `ctx.version_file` is Bazel's volatile workspace status file;
actions that consume it are intentionally rerun. A normal Angular package build substitutes the
literal version `0.0.0` and does not read any status variable, so the dependency was unnecessary.

The patched rule has an explicit `stamp` attribute:

- Normal builds pass `stamp = False`, omit both status files, and are remotely cacheable.
- `--config=release` and `--config=snapshot-build` pass `stamp = True`, retain both status files,
  and preserve `{{STABLE_PROJECT_VERSION}}` substitution.

An action-query validation found no status-file references in normal `TextReplace` actions and both
status files in release actions. A release build of `//packages/core:npm_package` also succeeded and
produced version `22.2.0-next.0`.

## Narrower package-artifact graph

If the required output is only Angular's publishable package artifacts, recursively building every
target beneath `packages/` does substantially more work than necessary. Angular's package build
query selects 16 `npm_package` targets, including the language server:

```shell
mapfile -t package_targets < <(
  pnpm --silent bazel query --output=label \
    "filter(':npm_package$', attr('tags', '\[.*release-with-framework.*\]', \
      //packages/... + //vscode-ng-language-service/...))"
)

bazelisk --bazelrc=/home/devbox/.bazelrc clean
bazelisk --bazelrc=/home/devbox/.bazelrc build --config=namespace-rbe \
  "${package_targets[@]}"
```

After one cache-populating run for language-server actions, two clean-state runs took **16.49s** and
**18.03s**, averaging **17.26s** with zero remote executions. An `aquery --output=summary` reported
7,239 actions for this graph versus 38,590 for recursive `packages/...`, an **81.2% reduction**.
The measured wall time is **58.1% below** the optimized recursive build average.

This command is **not output-equivalent** to `bazel build packages/...`: it intentionally omits
tests, compliance fixtures, examples, helpers, and other non-package targets. `pnpm build` remains
the repository's distribution-building entry point when stamped packages, copied `dist` output,
Zone.js, and `angular-in-memory-web-api` are required.

## Fresh-machine setup remains separate

Report 11 fetched 1,231 Bazel-managed repositories even after `pnpm install`. The pnpm store and
Bazel repository cache are separate. A prewarmed devbox image or a persistent
`--repository_cache` can remove that fresh-machine setup cost, but it does not improve the warm
action graph measured above. A local `--disk_cache` could also reduce remote traffic after its first
run, but it was deliberately excluded here so the measurements continue to represent Namespace's
remote cache and RBE benefits.
