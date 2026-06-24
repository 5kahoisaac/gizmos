# gizmos

A catalog of small, single-file shell utilities (zsh/bash). Each `.sh` file is
standalone — no build system, package manager, or test runner. Scripts are
meant to be sourced directly from a shell rc file.

## Conventions

- One script = one self-contained tool, sourced rather than executed as a binary.
- Document new scripts in `README.md` using the `gizmos-catalog` skill.

## Verifying changes

There is no build/lint/test tooling. Verify by sourcing the script and
running its functions/commands directly in a shell, e.g.:

```sh
source ./gac.sh && gac -h
```
