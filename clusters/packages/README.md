Third-party and first-party packages this cluster consumes, vendored in-tree.

`layer-zero` was a git submodule and is now committed here directly. Nothing about
how Flux reads it changed: the `platform-foundation` `GitRepository` in each
entrypoint's `bootstrap.yaml` points at this repo, and the package is found at
`PLATFORM_PATH_PREFIX: ./clusters/packages/layer-zero`. Vendoring it in means a
change to the platform and a change to the cluster that consumes it land in one
commit, rather than needing a push here and a submodule pointer bump.

Its upstream is https://github.com/TilakMaddy/layer-zero — this copy is a fork in
practice, so changes made here do not flow back on their own.

To serve it from a different repo later, change only these, in every entrypoint's
`bootstrap.yaml`:

- the `platform-foundation` `GitRepository` `url` and `ref.branch`
- `PLATFORM_PATH_PREFIX` — the package's path inside that repo, or `.` when the
  package is the repo root

`PLATFORM_SOURCE` stays `platform-foundation`, and no manifest inside the package
changes: every Kustomization it declares already resolves its source and path
through those two variables. If that repo carries submodules of its own, the
`recurseSubmodules: true` already on the GitRepository covers them.
