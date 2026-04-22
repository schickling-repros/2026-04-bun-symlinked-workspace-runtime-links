# Bun - Explicit Symlinked Workspace Member Installs, Then Fails at Runtime

`bun install` succeeds for an explicitly listed workspace member under a symlinked directory, but the installed tree is not runnable: Bun writes a broken package-local dependency symlink for the real workspace path.

## Reproduction

```bash
bash repro.sh
```

The script creates a tiny workspace in a temporary directory and verifies:

1. `bun install` succeeds when the workspace member is listed explicitly under a symlinked directory.
2. Running the app then fails with `ENOENT` because the workspace member's package-local dependency symlink is broken from the member's real path.
3. The same Bun workspace shape works when the workspace member lives under a real directory instead of a symlink.
4. `pnpm` comparison results are printed with the exact same package layout for context.

## Why This Is A Bun Bug

This is not only "symlinked workspaces are hard".

- The failing Bun case does **not** rely on workspace glob discovery.
- The workspace member path is listed explicitly in the root `workspaces` array.
- `bun install` reports success.
- The resulting link inside the real package path is objectively broken:

```text
external/shared-lib/node_modules/is-number -> ../../../../node_modules/.bun/is-number@...
```

From the real workspace package directory (`external/shared-lib`), that relative target does not exist. `readlink -f` for that link resolves to nothing, and runtime fails accordingly.

The non-symlinked Bun control proves the package graph itself is fine. The only difference is whether the workspace member sits under a symlinked directory.

## pnpm Comparison

The script also prints pnpm 11 results for the same layout and for a standalone real-path install:

- pnpm 11 does **not** make the exact aggregate symlinked-workspace layout runnable either.
- But pnpm does **not** create the same broken package-local relative symlink that Bun creates after a reported-success install.
- pnpm standalone install at the real package path works, which helps show the expected package-local dependency shape from the real path.

That makes the Bun issue more specific than generic workspace limitations:

- Bun's aggregate symlinked case claims success,
- then leaves a workspace member with a package-local dependency link that is invalid from the member's real location.

## Expected

One of these should happen:

1. Bun should materialize package-local dependency links relative to the workspace member's real path so the installed tree is runnable.
2. Or Bun should fail loudly during install if workspace members under symlinked directories are unsupported in this mode.

It should not report a successful install and leave broken package-local links behind.

## Actual

Verified locally on:

- Bun: `1.3.13-canary.1+3453c2248`
- pnpm: `11.0.0-beta.2`
- OS: Linux x86_64

Related issue:

- `TBD`

