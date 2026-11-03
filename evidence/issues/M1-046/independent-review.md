# M1-046 Independent Review

- Reviewer: a fresh-context review agent (Fable), started by the lead, not the implementer,
  2026-11-03.
- Target: PR #344 at `fe8dff3`, read-only, in the reviewer's own worktree.
- The client master plan, including its amendments h.1 and h.2, is the lead's planning document
  and is not in the repository. The decisions it settled for this issue are restated in the
  component doc and `summary.md`.

## Report

The report is verbatim, in the language the reviewer wrote it in (Traditional Chinese).

> 判定：ACCEPT（建議合併；plan 修正 h.2 確認採納）— Critical 0、High 0、Medium 0、Low 5
>
> ## Critical / High / Medium
> 無。
>
> ## Low
> 1. `docs/components/M1-046-modifier-state-ledger.md:88-91,160-161` 對照 `Packages/KVMCore/Sources/KVMCore/ModifierStateLedger.swift:102-104`：「未被 Caps Lock 事件解釋的 lock 變化會回報一次」在變化首次出現於 Caps Lock 幀（或其後第一個 key event）時不成立。情境：server 在 enter 前 lock 已開、尚未打字；輸入 `capsLock down 0x1000`（toggle-off 首幀）→ `key == .capsLock` 使 `toggled == true`，`state.capsLock` 直接取 1 不回報；接著 `capsLock up 0x1000`、`A down 0x0000` 亦不回報。輸出：整個 session 沒有任何 implied capsLock。V1 只計數，影響小。修法：文件改為「在第一個既非 Caps Lock、也不緊接 Caps Lock 之後的 key event 回報一次」。（另一選項是比較 Caps Lock down 幀——兩種凍結 pattern 及 first-party encoder 的 downMask 在該幀都等於 toggle 前的 lock 狀態——但會犧牲 ADR 要求的 pattern 無關性，不建議。）
> 2. `Packages/KVMCore/Tests/KVMCoreTests/ModifierStateLedgerTests.swift:420-449`：兩條 toggle 豁免規則只靠 seeded random test 守住。我的 mutant R1（非 key event 清掉 pending toggle）與 R2（豁免只在 Caps Lock up 後設定）都只讓 `randomSequencesFollowTheRulesStatedOverTheWholeHistory` 失敗（各 1 issue）。種子固定故可重現，但改種子或生成比例即可能漏殺。修法：在 `capsLockFollowsTheFramesLockBitThroughBothTogglePatterns` 加兩個確定性斷言：(a) `capsLock up(lock)` → `.mouseMove` → `A down()` 為 isEmpty；(b) `capsLock down()` → `A down(lock)` 為 isEmpty。
> 3. `docs/...md:149-151,291-297`：Follow-up 把「queue reset 丟掉已入帳 release」寫成未決並列三個選項；master plan h.1（2026-11-03）已決定 injector sweep（`releaseAllHeld()`/`releaseRemaining()`），不在三選項內。文件對「consulted, not authoritative」（`:137-142`）與 h.1 一致、無矛盾，只是過時。修法：Follow-up 改引 h.1 與 sweep。
> 4. `docs/...md:272-275`、`Packages/KVMCore/Sources/KVMCore/ServerCoordinator.swift:375-376`：first-party server 離開前以「按下時記錄的 modifiers」送 release；若中間已放開某 modifier，該 release 會被 ledger 回報為 implied（`serverReleasesBeforeLeavingLeaveNothingHeld`:666-683 已釘住）。這是 ledger 視角的假 implied——server 其實沒按著。V1 只計數；但若日後 M1-046-FOLLOWUP-001 依 implied 合成按鍵，leave 時會多合成一次 Shift。修法：本 PR 不改；在 FOLLOWUP 或 server 端（以當下 modifiers 送 release）記一筆。
> 5. 流程：`evidence/issues/M1-046/` 缺 issue Expected Evidence 的 `summary.md` 與 plan g 的 `independent-review.md`；PR body 說由 lead 補，M1-043 先例（`1f66e6a`）亦為後補。合併前需補齊。
>
> ## h.2 判定（lock bit 取自最後一個 key event）
> 確認採納。(a) 草稿字面規則（只在 Caps Lock 幀複製）在 toggle-off 後 lock 卡在 on，因兩幀都帶 0x1000（ADR `:133-134`；register seq 523/525 實測相同）；(b) 由按壓推導被 lead 設計禁止、M1-043 留白；(c) h.2 對兩種凍結 pattern 皆不回報、對未見變化回報一次（除 Low 1 邊角）；(d) 文件 `:141-142` 明寫 `state.capsLock` 是回報、不得驅動 release/injection，與 ADR decoder policy（不從 mask 推 lock state）及 risk f.6 一致。C-006「不能完全依賴單一 event flags」對 lock 只以「前後兩個 key event 比較」弱滿足；文件 `:130-135` 已標示待 PO 確認，仍開放。
>
> ## 往返測試（焦點 3）
> 對本 issue 足夠。`serverChain`（Tests:139-152）與 `BarrierServerInputEncoder.key`（`:75-93`）逐行相符：modifier 自身 down/up 用 `mask ^ entry.modifierBit`；Caps Lock `downMask = phase == .down ? mask & ~bit : mask | bit`、up 為 `mask | bit`、repeat 不送；encoder 唯一 stored property 是 `screen`，無跨事件狀態，逐事件模型對序列同樣成立。decoder+mapper 透傳由 M1-043 的 `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey` 釘住。缺口：模型與真鏈漂移在 KVMCoreTests 不會被發現，靠 M1-043 的釘測與已記錄的 `Tests/Integration` follow-up（該 target 已 `import KVMCore` 與 `import BarrierCompatibility`，grep 確認）。
>
> ## 已檢查，無問題（指令與輸出）
> - 範圍：`git diff --name-status 876e5d6..fe8dff3` → 7 個 `A`，恰為三個 Exact Files + `evidence/issues/M1-046/{commands.json,mutations/mutations.json,mutations/run_mutations.py,tests/swift-testing-xunit-swift-testing.xml}`；`git merge-base` = `876e5d6`。
> - `timeout 900 swift test --filter ModifierStateLedger` → `✔ Test run with 20 tests in 1 suite passed after 0.113 seconds.`，exit 0。
> - `swift format lint --strict --no-color-diagnostics` 兩檔 → exit 0。
> - 自選 mutants（與實作者 21 個不同），各跑完後以備份還原並比對 sha：R1 非 key event 清 pending toggle → `randomSequences… failed with 1 issue`；R2 `lockMayHaveToggled = key == .capsLock && phase == .up` → 同上 1 issue；R3 own bit 改取 `!modifiers[modifier]` → `bothSides…`、`ownBit…`、`randomSequences…`、`serverReleases…` 失敗，13 issues；R4 modifier 自身幀 `reported = state` → `lockBitChanges…`、`ownBit…`、`randomSequences…`、`serverReleases…` 失敗，5 issues。4/4 killed。還原後 sha 前綴 `dde5c43ad856aab0`；`git diff --exit-code --stat` → exit 0；`git status --short` → 0 行。
> - 雜湊：`shasum -a 256` 兩個 Swift 檔 = mutations.json `sourceSha256`/`testsSha256`（`dde5c43a…1068`/`33e09001…b0d8`）；`git hash-object` 四檔 = commands.json `testedFiles`（`aade0325…`、`f9043e09…`、`885d5324…`、`2440f081…`）。
> - 隱私：grep `evidence/issues/M1-046/` 找 `/Users/`、使用者名、`.local`、IPv4 → 只命中版本字串（6.2.3.3、700.6.3.2、1.127.14.1）；本機 hostname 命中 0。
> - RED：19 tests、exit 1、`expectedFailure: true`；`testRenames` 記錄改名（`everyKeyFrameRefreshes…` → `lockBitChanges…`）與後加的 `serverReleasesBeforeLeavingLeaveNothingHeld`；摘錄可見的 15 個名稱都在現行 suite。toolchain（Swift 6.2.3、Xcode 26.2、macOS 26.6.2）與 `date: 2026-11-02` 皆在。
> - XML：204 testcases、0 failures；20 個 `ModifierStateLedgerTests` 名稱與檔內 20 個 `@Test` 的 diff 為空。
> - 契約手推：register seq 404-525（Shift+A/1/minus、Control+c、Alt+a、Super+a、Control+Shift+Esc、四個 modifier 各自 tap、左右成對 483-512、Caps Lock on/A/off 515-525）逐幀過 `apply()`：全程 isEmpty、結尾 state 全空；seq 487 L-Shift DKUP 在 R-Shift 仍按住時釋放，是已記錄的 M1-042 代價，非誤報。first-party 鏈（Option/Command 順序釋放、雙 Shift 三按一放、leave 釋放序列）皆無誤報、無漏報。
> - 文件引用的 first-party 事實與原始碼一致：`MacKeyboardCapture.swift:16-17`、`BarrierServerInputEncoder.swift:75-93`、`ServerCoordinator.swift:374-376,476-485`；規則段落明標 first-party；Barrier 行為只引 ADR 與 register。
> - 清潔室：未開啟任何 Barrier/Deskflow 原始碼；Barrier 行為僅取自 ADR 與 register fixture（base64 解碼本 repo 的 `server-input-capture.json`）。
>
> ## 未驗證
> - RED 摘錄被截斷（保留前 25／後 80 行），19 個名稱中 4 個無法從 artifact 確認。
> - 未重跑 `make verify`、`xcodebuild`、`make architecture-check`、`validate_package.py`（commands.json 記錄皆 exit 0）；未重跑實作者的 21 個 mutants（以自選 4 個替代）。
> - 文件 `:59-61` 的 macOS 雙側 flag 推論（已標 inference）未在硬體上驗證；C-006 lock 讀法的 PO 確認仍開放。

## Resolution (`c6958a8`, and the lead's finishing commit)

| Finding | Resolution |
| --- | --- |
| Low 1 | The doc and the Swift doc comment say an unexplained lock change is reported once, on the first key event that is neither a Caps Lock frame nor the key event right after one. The reviewer's case is listed as a known limitation. No behavior change. |
| Low 2 | `capsLockFollowsTheFramesLockBitThroughBothTogglePatterns` gained the two deterministic assertions. R1 and R2 are in the mutation runner; each now fails that test and the random test. Against the previous suite they failed only the random test (`mutations/mutations-previous-suite.json`). |
| Low 3 | The follow-up section and the queue-reset sentence cite amendment h.1 (the injector sweep) instead of listing options. |
| Low 4 | The doc adds the follow-up note: a future synthesis feature must not act on implied reports caused by the server's releases before it leaves, or the server must send those releases with the current modifiers. |
| Low 5 | `summary.md` and this file are added by the lead's finishing commit. |
| h.2 judgment | The doc records the lock reading as adopted in amendment h.2 and confirmed by this review. It states that V1 uses the lock bit for diagnostics only, and that the lock is compared only across consecutive key events. |
