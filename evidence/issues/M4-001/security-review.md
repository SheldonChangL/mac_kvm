# M4-001 Security Review

Status: pending the designated Security Reviewer. The implementing agent lists what the
reviewer must check; it does not sign off.

| Area | What the ADR selects | Reviewer finding |
| --- | --- | --- |
| Fail closed | TLS on by default, minimum TLS 1.2; the custom verification callback succeeds only on an exact SHA-256 match of the leaf DER with the trusted fingerprint; an unknown fingerprint prompts and a changed one is rejected | pending |
| Key and secret handling | the Linux client holds no private key; the trusted-server store holds fingerprints only (M4-021-FOLLOWUP-001, a 0600 file) | pending |
| Identity change | a changed server fingerprint is rejected (C-009, `FingerprintChangeFlow`) | pending |
| Abuse paths | XTest injection needs the user's own X display connection; no root, no uinput; no Linux listener | pending |
| Supply chain | the image is pinned by digest and the dependencies by exact version; drift stops Linux work | pending |
| Licensing | Apache-2.0 packages; BoringSSL under ISC and the OpenSSL license; no GPL | pending |
