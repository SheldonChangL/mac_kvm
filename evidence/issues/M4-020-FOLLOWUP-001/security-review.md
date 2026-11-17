# M4-020-FOLLOWUP-001 Security Review

- Reviewer: fresh-context Opus agent, not the implementer
- Date: 2026-11-17
- Target: PR #370 at `a020ac2`
- Verdict: APPROVE WITH MINOR FIXES; 0 Critical, 0 High, 0 Medium, 4 Low. Static review only.

## Reviewer designation

This is a Tier S PR (risk critical). On 2026-11-17 the Product Owner decided that a fresh-context
security review replaces the designated Codex Security Reviewer for Tier S PRs. The review below is
that fresh-context security review, done by a model that did not implement the change. It is
separate from the Tier C review in `independent-review.md`.

## Review (verbatim)

Quoted from the lead's review record for PR #370; the `FIX:` notes in it were added by the lead after
the fixes and are not the reviewer's words.

> Static only. Pin decision inside handshake, fail-closed on store error, re-pin after interactive trust (no TOCTOU), only exact `trust` stores, presentedFingerprint display-only, `fingerprint trust` never overwrites, root refused before state read, no host/clipboard leaks, strict CLI validation.
> Findings (all Low): 1 shutdown timeout keys held (fixed as above); 2 Ctrl-C during prompt (fixed); 3 systemd unit hardening + hardcoded DISPLAY=:0 (FIX: NoNewPrivileges, LockPersonality, RestrictSUIDSGID, RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6, UMask=0077; DISPLAY removed; unit test updated); 4 signal handlers installed late (harmless, noted).
> Out of scope: trust-file perms/atomic writes (M4-021, unchanged).

## Resolution

Fixes are at `fffb60f`; CI `verify-linux` and `build-test-manifest` passed at that head.

| Finding | Resolution |
| --- | --- |
| Low 1: shutdown timeout may leave keys held | Fixed with Tier C Low 3: the release sweep runs first with its own 1 s bound; documented. |
| Low 2: Ctrl-C during the trust prompt | Fixed with Tier C Medium: the prompt races signals; mutant M36 killed. |
| Low 3: systemd unit hardening and a hard-coded `DISPLAY=:0` | Fixed: `NoNewPrivileges`, `LockPersonality`, `RestrictSUIDSGID`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, `UMask=0077`; `DISPLAY` removed; the unit structure test updated. |
| Low 4: signal handlers installed late | Harmless; noted, no change. |
| Out of scope: trust file permissions and atomic writes | Owned by M4-021-FOLLOWUP-001; unchanged here. |
