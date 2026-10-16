---
name: check-app-behaviour-claim
description: Verify that behaviour a module change asserts about the Masterly application images exists in a released image tag. Use when an alert query, variable description, output or doc names application log lines, commands, endpoints or env names.
---

# Check a claim about application behaviour

The module and the application images version apart. Self-hosted ships three independently versioned
artifacts: `masterly-application-backend`, `masterly-application-frontend` and this module. The owner
decision of 2026-09-09 (an amendment to ADR 0062) makes the module version the one customer-facing
version ("I am on Masterly 0.15.0" means module 0.15.0); the other two stay pipeline-computed build
identities.

`MANIFEST.json` records which image pair each published module version was released against. That is
what the reference install had applied at tagging, not what any install runs now: the module seeds a
new app and then ignores image drift, so CD owns the running tag. `releases` has no entries before
0.15.0, because the pair was never recorded at the time, and none should be invented: that would be
the retyped-value failure the manifest exists to end.

A change here can describe behaviour that exists only on the apps' `main`. This has caught a release
already: a 0.16.0 preparation carried an alert searching logs for a line no published image writes,
and a variable description telling operators to mint a credential with a module absent from the
released `api`. Both plan and apply cleanly and then do nothing, or arm a credential that can never
authenticate.

Before asserting anything about application behaviour:

```bash
git tag --contains <commit>   # run in the app repository; empty output = in NO tag
```

Empty output means unreleased, however green the PR. Check the alert's actual search string, or the
documented command, against the released tag's tree (`git show <tag>:<path>`), not against `main`.

If you change the shape of `MANIFEST.json`, you change a contract (`docs/release-manifest.md`) that
other repositories and the public docs read.
