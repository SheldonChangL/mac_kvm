# M1-TOOLING-002 Independent Review

- Reviewer: fresh-context Opus agent, Tier B
- Date: 2026-11-17
- Target: PR #366 at `1e42eb2`
- Verdict: APPROVE, nothing blocking; 2 Nit, 1 Info

## Review (verbatim)

> PR #366 (M1-TOOLING-002) Tier B review, fresh-context Opus, 2026-11-17, head 1e42eb2914d237971d01e3fda29929158aa7ab3b
> Verdict: APPROVE, nothing blocking.
> Verified: pattern M[1-5]-[0-9]{3}(?:-FOLLOWUP-[0-9]{3})? in run_e2e.py:56 (ISSUE_PATTERN), :57-59 (SCRIPT_NAME_PATTERN), validate_evidence.py:84 (ISSUE_PATTERN), :95 (ARTIFACT_PATH_PATTERN), e2e-result.schema.json:27 and :454; all fullmatch/anchored, trailing \n rejected; schema/validator equality test passes. Reject tests cover no digits, 2/4 digits, two suffixes, lower case, non-digit, trailing newline, extra suffix, wrong-issue artifact paths. Author's extra change run_e2e.py:218-230 (base id skips <base>-FOLLOWUP-nnn-* scripts) judged correct and necessary. Existing ids unchanged apart from that.
> Findings: NIT run_e2e.py:61 infix check only matches FOLLOWUP-[0-9]{3}-, so malformed M4-036-FOLLOWUP-01-x.sh still resolves for base M4-036 (harmless, needs a badly named repo script); NIT test_run_e2e.py extra blank lines; NIT test_validate_evidence.py import order; INFO schemas/issue.schema.json:20 unchanged, correct per b.17 scope.
> Reviewer runs: detached worktree on PR head, python3 -m unittest discover -s Tools/Evidence/tests: 211 tests OK; main e4c8769 suite passes. 4 own mutants all detected: M1 excludes_followup=False (1 fail 1 error); M2 validator pattern [0-9]+ (3 fails); M3 infix check off (1 fail 1 error); M4 schema artifact path loses group (1 fail).

## Resolution

All three notes were accepted as they are; there was no code change after the review.

| Finding | Resolution |
| --- | --- |
| Nit (`run_e2e.py:61`): the infix check only matches `FOLLOWUP-[0-9]{3}-`, so a malformed `M4-036-FOLLOWUP-01-x.sh` still resolves for base `M4-036` | Accepted: harmless, it needs a badly named repository script. |
| Nit (`test_run_e2e.py`): extra blank lines | Accepted: style only. |
| Nit (`test_validate_evidence.py`): import order | Accepted: style only. |
| Info (`schemas/issue.schema.json:20`): unchanged | No action: correct for this scope. |

Gates: the unit suite (211 tests) and the other gates recorded in `commands.json` ran on the
reviewed code, which is unchanged.
