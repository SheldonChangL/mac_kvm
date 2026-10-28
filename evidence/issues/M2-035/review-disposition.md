# M2-035 Composition Root — Independent Review Disposition

An independent, fresh-context reviewer read `e20b3fe..8e73bf3` (TLS identity and
listener, `ServerCoordinator`, the app composition root, event tap, desktop
geometry) without running it, and reported 1 High, 3 Medium and 10 Low
findings. Fixes are in `dca58bb` (coordinator) and `65b6a08` (app); the smoke
re-run after them passed every case (`automated-smoke/`).

| ID | Finding | Disposition |
|---|---|---|
| H1 | A chord completed by a release or repeat of Delete stopped suppression while the state stayed remote | Fixed: every phase of the chord key returns input to local |
| M1 | Crossing the return edge with a held key or button leaked repeats to the Mac and dropped drags | Fixed: a held button or non-modifier key keeps the pointer on the client (tested) |
| M2 | Secure event input would route remote typing to a Mac secure field | Fixed: no enter while secure input is on; remote input returns to local on the next tick, with a status line (tested in the coordinator; the platform check needs hardware) |
| M3 | After a forced return the parked cursor re-armed the edge at once | Fixed: a forced return disarms the edge until the pointer moved 50 points away (tested) |
| L1 | An outbox overflow also dropped the releases and leave that follow | Fixed: overflow drops the backlog first |
| L2 | Shutdown could still start an enter; the flush did not wait for the last write | Fixed: the tap is removed first; 100 ms grace after the drain |
| L3 | Blocking stdout writes in the tap callback and under the lock | Fixed: status lines go through their own queue |
| L4 | Window-server calls off the main thread with the lock held (inferred) | Fixed: cursor work runs on the main queue in effect order |
| L5 | Logs carried the client screen name and port (ADR M2-001) | Fixed |
| L6 | A restore point off every display falls back onto the edge | Open, low: the park point comes from a live cursor location |
| L7 | Silent degradation (tap budget, listener death, bad client name, unusable size) | Fixed: each is reported; tap or listener failure stops the server |
| L8 | Display hot-plug is not followed | Open: restart MacKVM after changing displays |
| L9 | An absurd motion delta made the step loop unbounded | Fixed: 10 000 points per axis per event (tested) |
| L10 | Two first launches at once could race on the identity | Open, low: one server per Mac |

Residual, accepted for the owner run: a fumbled chord that presses
Control+Option+Delete before Command still forwards Control+Alt+BackSpace to the
client; X servers terminate on that only when `terminate:ctrl_alt_bksp` is set,
and the test client's display has no XKB options set (checked 2026-10-28).
