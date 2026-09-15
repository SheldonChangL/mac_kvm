# M1-DOCS-001 Canonical Docs Check

## Outcome

This bootstrap correction establishes the previously unowned formal command required by M1 documentation and backfill Issues:

```bash
make docs-check
```

The cumulative `make verify`/GitHub CI pipeline invokes the identical production command and its unit suite before architecture, quality, build, and test gates.

## Tracked-file boundary

The checker asks Git for tracked `*.md` and `*.json` paths. This makes the checked set deterministic and prevents untracked Product Owner inputs, local artifacts, `.build`, or ignored CI reports from entering logs or validation. Absolute/parent-traversal paths, missing files, symlinks, Git failures, invalid Git-path UTF-8, and timeouts fail closed.

## Markdown rules

- valid UTF-8
- LF-only newlines
- no trailing spaces or tabs
- exactly one final newline
- balanced backtick/tilde fenced-code blocks, including marker length and type

The first repository run correctly found one pre-existing unmatched opening fence at `MacKVM_Implementation_Package_v2/MILESTONES.md:1`. The PR removes only that stray fence/blank line; all milestone content remains unchanged.

## JSON rules

- valid UTF-8
- parseable standard JSON
- no duplicate object keys

The canonical package validator remains responsible for backlog/schema semantics. The docs checker supplies baseline encoding/syntax integrity and does not create a second divergent package validator.

## Privacy and cancellation

Diagnostics contain only repository-relative path, line, fixed rule id, and fixed detail. Document/JSON content and raw Git stderr are never replayed. Git enumeration runs in its own process group; timeout, keyboard interruption, and runner `SIGTERM` clean it up and fail non-zero.

## Out of scope and rollback

Remote-link crawling, prose style, automatic rewriting, product/runtime behavior, public API, protocol, networking, platform input, and security policy are out of scope.

Rollback by reverting the PR. No runtime state or user data migration exists.
