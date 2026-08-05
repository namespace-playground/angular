# Namespace RBE optimization summary

## Outcome

The optimized recursive Angular package build now averages **41.22 seconds** on the Namespace S
devbox, down from the **90.10-second** average in reports 8–10.

| Scenario                                   |          Wall time |
| ------------------------------------------ | -----------------: |
| Historical small RBE average, reports 8–10 |             90.10s |
| Optimized RBE average, five runs           |         **41.22s** |
| Optimized RBE range                        |   **39.70–43.55s** |
| Publishable-package-only graph             | **17.26s** average |

The optimized recursive build is:

- **54.2% faster** than reports 8–10.
- **50.0% faster** than the 82.49s XL RBE run in report 7.
- **87.0% faster** than report 1's 315.99s empty-cache build.
- **7.67x faster** than report 1.
- Free of recurring remote executions: **70 → 0**.

## Bottlenecks found and fixed

### 1. Uncacheable `TextReplace` actions

All 70 recurring remote executions were `TextReplace` actions. The upstream rule always consumed
Bazel's volatile and stable workspace-status files, including in normal unstamped builds that did
not use status substitutions. Consuming the volatile status file forced Bazel to execute those
actions on every invocation rather than accepting remote cache results.

The patched rule now has an explicit `stamp` attribute:

- Normal builds omit workspace-status inputs and are remotely cacheable.
- Release and snapshot builds retain workspace-status inputs and continue to substitute
  `{{STABLE_PROJECT_VERSION}}`.

This eliminated all 70 recurring executions and increased remote cache hits from 19,141 to 19,211.

### 2. Insufficient remote concurrency

Namespace's generated configuration used `--jobs=32`. This was too conservative for a graph with
approximately 35,000 progress actions and 19,000 remote cache hits. The client serialized many
cache lookups even though the actual work was remote.

The new `namespace-rbe` config uses **128 jobs**, which was the best tested setting:

| Jobs |  Patched wall time |
| ---: | -----------------: |
|   32 |             93.40s |
|   64 |             61.35s |
|  128 | **41.22s average** |
|  200 |             44.94s |

Raising concurrency from 32 to 128 reduced the patched build by **55.9%**. Increasing it further to
200 jobs did not help.

### 3. Namespace worker compatibility was machine-local

The benchmark originally depended on a local patch that taught the `rules_angular` worker to
recognize Namespace's `/var/lib/namespace-bazel/` sandbox and a `.bazelrc.user` override that
allowed `JsRunBinary` actions to execute remotely.

Both settings are now checked in through the `rules_angular` module patch and the named
`namespace-rbe` config. A clean build without `.bazelrc.user` completed in **40.01s**, confirming
that the branch contains all required Namespace compatibility settings.

## Run the optimized recursive build

```shell
bazelisk --bazelrc=/home/devbox/.bazelrc clean

bazelisk --bazelrc=/home/devbox/.bazelrc build \
  --config=namespace-rbe \
  packages/...
```

This uses the same recursive `packages/...` target set as the original benchmark. It uses minimal
output downloading, so remotely produced artifacts remain in the CAS. If a later local process
needs top-level artifacts, add:

```shell
--remote_download_outputs=toplevel
```

## Faster package-artifact-only option

If only publishable Angular packages are required, building the 16 tagged `npm_package` targets
reduces the action graph from 38,590 to 7,239 actions—an **81.2% reduction**.

After the remote cache was populated, this narrower graph averaged **17.26s**, which is **58.1%
faster** than the optimized recursive build.

This is not output-equivalent to `bazel build packages/...`: it omits tests, compliance fixtures,
examples, helpers, and other non-package targets. Use `pnpm build` when stamped packages, copied
`dist` output, Zone.js, and `angular-in-memory-web-api` are required.

## Validation

- Five final 128-job recursive builds: **39.70–43.55s**, averaging **41.22s**.
- Final branch-only build without `.bazelrc.user`: **40.01s**.
- Final process disposition: **19,211 remote cache hits, 12,069 internal, 0 remote executions**.
- Unstamped action query: no volatile or stable status-file inputs.
- Release action query: volatile and stable status-file inputs retained.
- Release build of `//packages/core:npm_package`: succeeded with version `22.2.0-next.0`.
- Repository formatter and patch-application checks: passed.

The implementation is on branch `perf/faster-namespace-rbe`, starting with commit `81c180225f`.
The complete investigation, raw benchmark table, methodology, and narrower target command are in
[`tools/bazel/namespace-rbe-performance.md`](tools/bazel/namespace-rbe-performance.md).
