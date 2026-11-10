# Task Token as a Reverse Asset — Reference Implementation

Reference implementation, deterministic toolchain, and test vectors for the ERC draft
**"Token-Bound Task Tenders"** (TASK-KERNEL v3.0).

An ERC-721 extension that binds a token to a hash-verifiable task tender: the chain
anchors *exactly which task specification, acceptance criteria, version, and publication
history* a token commits to — together with an escrowed reward paid per accepted
completion. It is the demand-side inverse of
[Token-Bound Executable Skills](https://github.com/garyyang-finchip/skill-token-standard)
(ERC-8338): where a skill token wraps supplied value awaiting payment, a task token
wraps committed payment awaiting supplied value.

**What "reverse asset" means.** A task token is not an escrow. An escrow is a bilateral
arrangement — two named parties, a condition, a release — with no owner, no price, and
nothing to trade. A reverse asset is a bearer position on the demand side: it has an
owner (who may be neither the publisher nor the judge), a price that fulfillers and
secondary buyers quote against its vault, and a claim that is on *work*, not on money —
the mirror of a skill token, whose holder's claim is on money for work already wrapped.
Three consequences follow, and the kernel enforces all three: the money sits inside the
token (the vault), the demander's commitment binds without its further cooperation
(silence pays the fulfiller), and judgment is a power a buyer can inspect and price
before acquiring the token (the third authority).

**What "fulfillable token" means.** The two names answer two questions. *Reverse asset*
says what the token is economically: the demand side, wrapped first. *Fulfillable token*
says what kind of token it is mechanically: one whose value is drawn down by fulfillment,
as an executable token's (ERC-8338) is drawn down by execution — the supply side is *run*,
the demand side is *met*. Transfer moves a fulfillable token; only fulfillment draws on
it, which is why every state-changing path in `ITaskTender` is a fulfillment path or a
refund path, and none is a payment path.

```
Supply side (ERC-8338):   T(f(v), $)      = ($, v)   the seller moves first
Demand side (this work):  T(v, f⁻¹($))    = ($, v)   the buyer moves first
Together:                 T(f(v), f⁻¹($)) = ($, v)   the agent economy, bidirectionally complete
```

The wrapping is literal: every task token deploys a **per-token locked vault** at mint —
the bounty sits at the token's own vault address, visible to any explorer, spendable by
no one, released only through settlement or refund. The vault is the tender's credit
foundation and travels with the NFT through every trade.

```
ERC-721 layer          who owns this task token (a funded tender is a tradable demand-side asset)
Task Binding layer     tdHash / taskHash / version / taskURI / updateAuthority / frozen
Tender layer           per-token locked VAULT / immutable terms (asset, reward, maxCompletions,
                       submitBy, settleBy, epochLength, maxCompletionsPerEpoch) /
                       acceptance authority spectrum: verifier contract => machine settlement
                       (permissionless, "solve it and the vault pays") · any judging address =>
                       judged settlement / submissions / refund
On-chain Document      optional plaintext primary task document, readable from the chain itself
Task Object Model      deterministic DAG-CBOR object graph, per-file CIDs (off-chain, normative),
                       byte-compatible with the ERC-8338 Skill Object Model — one toolchain, two standards
```

## Static task token, faucet task token — the two halves of the demand side

ERC-8338 has two usages of one artifact: a **static skill token** (buy the capability
once) and an **API Call Token** (buy the capability as a metered stream — per call,
per period, per unit of compute). The demand side mirrors both, and this standard
covers both with **one kernel and no mode flag**:

| | supply side (ERC-8338) | demand side (this standard) |
|---|---|---|
| **static** — one exchange, then done | static skill token | **static task token**: one tender, one vault, settled when the work is accepted |
| **continuous** — a metered stream | API Call Token | **faucet task token**: a standing demand that keeps paying per delivery for as long as the vault is refilled |

Together the four quadrants make the agent economy complete in both directions and
both tempos: `T(f(v), f⁻¹($)) = ($, v)`, whether `f` and `f⁻¹` are exercised once or
continuously.

A faucet task token is not a second mechanism. It is the same `TenderTerms` with the cadence
fields set — which is why every worked example, static or faucet, settles through the
same code path and the same tests:

| API Call Token meters by | a faucet task token meters by | kernel field |
|---|---|---|
| count (per call) | per accepted delivery | `rewardPerCompletion` × the completion counter (`maxCompletions`, `0` = open-ended) |
| time (per period) | per epoch | `epochLength` + `maxCompletionsPerEpoch` |
| compute (per unit of work) | per unit of work, *as the task package defines the unit* | the completion itself — `fulfillment.json` says what one completion is; the kernel pays a flat price per unit |

The tap opens with `fundTask` (anyone, any time, any number of times) and closes with
`cancelTask` — with every delivery already in flight still protected by its reservation
and its judgment window. Case 2 below is a faucet task token that ran on Sepolia; cases 1, 3,
4 and 5 are static task tokens.

## Fulfillment shapes (one number + one address, no new mechanisms)

| Shape | On-chain expression |
|---|---|
| Exclusive — one task, one fulfiller | `maxCompletions = 1` |
| Collaborative — one task, a team shares one reward | `maxCompletions = 1`, fulfiller of record = split contract (ERC-1155 shares) |
| Replicated — N completions, each earns the same reward | `maxCompletions = N` (0 = unbounded, funded incrementally) |
| **Faucet** (standing tender) — a continuing demand, paid per delivery as long as money flows | `epochLength` + `maxCompletionsPerEpoch` for cadence, `maxCompletions = 0` for open-ended, `fundTask` at any time to refill — the inverse of supply-side metered point-card assets |
| Subcontracted | submission permissionless; economic shares transfer via companion ERC-1155 contracts |

Settlement spans the whole task spectrum through one slot: point `acceptanceAuthority`
at a verifier contract (`ITaskVerifier` via ERC-165) and the task is **machine-settled** —
anyone may call `settleFulfillment` with a proof, so fully quantifiable tasks (solve an
equation, reveal a preimage, oracle-confirmed outcomes) pay with no one in the loop.
Point it at any judging address — an EOA at cold start, the `JuryPanel` K-of-N reference,
a DAO later — and the task is **judged**; governance evolves by one
`setAcceptanceAuthority` call, never by touching the standard.

The contract enforces arithmetic (counting, solvency, deadlines, authority); the
acceptance authority enforces semantics (eligibility, quality, team composition) per the
fulfillment descriptor committed inside `taskHash`.

## Fees and incentives — outside the kernel, at three enforceable points

The kernel pays exactly one party (the fulfiller of record) and refunds exactly one
class (attributed funders). Platform fees and judge compensation are composed outside
it, in the slots it already has — and because the money is *inside* the token, each
point is enforceable, not merely advisory:

| attach at | how | enforced by |
|---|---|---|
| **funding entry** | a router calls `fundTask` with the net amount, keeps its fee, forwards refunds on its own ledger | it is the only path the platform offers |
| **settlement exit** | fulfiller of record = a split contract (`examples/teams/FixedSplitter.sol`): provider gets its share, treasury the rest — 0%, 0.5%, 2.5%, whatever the split says | acceptance policy accepts only submissions from registered splitters |
| **judgment slot** | the judging contract holds its own compensation escrow and pays jurors on their ruling | the demander funds the panel when appointing it |

Fee rates live in those contracts, so governance changes them without ever touching the
kernel. A machine verifier needs no incentive (it is code; the caller pays gas), and a
single-address judge is usually the demander itself. Third-party committees are the one
case that needs paying, and the escrow belongs with the committee. Companion escrows
must **not** pay per rejection — that is a vault drain (see Security Considerations).

## Repository layout

```
ERCS/erc-9999.md         the ERC draft (placeholder number, assigned by editors at PR time)
contracts/               TaskToken.sol + TaskVault.sol + interfaces (ITaskToken / ITaskTender
                         / ITaskVerifier / IOnchainTaskDocument)
contracts/verifiers/     HashlockVerifier.sol — stock machine-settlement verifier
contracts/judgment/      JuryPanel.sol — K-of-N reference judging authority
test/                    Foundry suite, 58 tests, one assertion cluster per MUST clause
tools/task-pack/         pack.py (canonical packer) / verify.py (fulfiller-side verifier)
                         / tom.py (deterministic DAG-CBOR + CID library, zero deps)
schemas/                 task manifest + fulfillment descriptor + confidentiality JSON Schemas
vectors/                 frozen test vectors (KEY.demo files are NON-CRYPTOGRAPHIC TEST keys)
sample-task/             the source package the vectors are built from
scripts/                 local_e2e.sh + smoke.mjs (solc-js + ganache lifecycle, 108 assertions)
                         pack_examples.sh — canonical pack flags for all nine example packages
scripts/helpers/         SmokeFixtures.sol — fulfiller/token fixtures the smoke run compiles
vectors-objects-bundle.tar.gz   insurance copy of all vectors/*/objects/
```

Interface IDs (compiler-verified, solc 0.8.24):
`ITaskToken = 0xcdaeb26d` · `ITaskTender = 0xc319d532` · `ITaskVerifier = 0x9977db15` · `IOnchainTaskDocument = 0xeb078d05`

## Settlement deductions (this branch)

This branch adds the escrow side of the draft
[Settlement Deductions ERC](https://github.com/unicore-gpu/settlement-deductions) to the
kernel, so that a deployment can withhold part of each payout for a tax, a referral fee
or a loan repayment. With no policy, settlement is unchanged.

- `contracts/TaskToken.sol`: `_deductionPolicy()` (default: none), `onTaskCreated` at mint,
  and `_applyDeductions` on every payout path: a fixed gas budget the caller cannot starve,
  at most one word of return data, full payout and `DeductionsSkipped` on any invalid
  answer, the deduction credited to the policy and withdrawn through `withdrawCredit`.
- `contracts/interfaces/ISettlementDeductions.sol`: a copy of the ERC's interfaces.
- `companions/DeductingTaskToken.sol`: deploys the reference policy from the
  settlement-deductions repository and names it for life.
- `test/DeductingTaskToken.t.sol`: 21 tests, including a contract-size check;
  `test/DeductionConformance.t.sol`: 8 tests of the kernel against the ERC's escrow
  requirements (every payout path asks the policy, no refund or rejection path does,
  no gas limit settles without the deductions, the ERC's events, withdrawal by anyone).
- Size on this branch: `TaskToken` 23,803 bytes of runtime code (37 more than the
  figure below), `DeductingTaskToken` 24,490, both under the 24,576-byte limit.

## Quick start

```bash
# 0) clone fresh
git clone https://github.com/garyyang-finchip/task-token-standard.git
cd task-token-standard

# 1) hygiene: strip CRLF (Windows transit) and restore objects if transport dropped them
find . \( -name '*.sh' -o -name '*.py' \) -exec sed -i 's/\r$//' {} +
ls vectors/public-v1/objects >/dev/null 2>&1 || tar -xzf vectors-objects-bundle.tar.gz

# 2) offline verification (no chain needed) — proves the deterministic toolchain
TD=$(python3 -c "import json;print(json.load(open('vectors/public-v1/vector.json'))['tdHash'])")
TH=$(python3 -c "import json;print(json.load(open('vectors/public-v1/vector.json'))['taskHash'])")
python3 tools/task-pack/verify.py vectors/public-v1 --tdhash $TD --taskhash $TH --max-completions 10
# expected: [OK] steps ... PASS - task package verified; safe to price, fulfill, and cite this version.

# 3) Foundry: compile + full MUST-clause test suite
curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup
forge install foundry-rs/forge-std --no-git
forge install unicore-gpu/settlement-deductions@eb8a7c1 --no-git   # settlement-deductions branch only
forge build
forge test -vvv

# 4) local chain lifecycle without Foundry (solc-js + ganache + ethers):
#    vault lock -> judged + machine settlement -> epoch pacing -> jury panel ->
#    cancel -> pro-rata reclaim + owner residual -> payout credit -> on-chain
#    document. 108 assertions.
npm install -g solc@0.8.24 ganache && npm install ethers@6
bash scripts/local_e2e.sh
# expected: SMOKE RESULT: 108 passed, 0 failed

```

## Status — Milestone M3 (2026-08-22, TASK-KERNEL v3.0)

**v3.0 closes the free-look asymmetry of the demand side.** A supply-side artifact is
bought against a hash and can be checked after payment; a task fulfiller has to reveal
the work *before* being paid, to the very party holding the money. v2.0 let that party
read a delivery and then cancel, or stall, and reclaim the bounty — an attack we
reproduced end to end before fixing it. Three rules remove it, using counting and a
clock rather than cryptography:

- **A delivery reserves a slot and a reward.** `submitFulfillment` reverts unless the
  tender has an unreserved slot and the vault can cover every Pending reward at once.
  `pendingOf` and `lockedEscrowOf` expose the reservation; refunds cannot touch it.
- **Cancellation stops new work, not delivered work.** Submissions Pending at
  cancellation stay acceptable, rejectable, settleable, and claimable; `reclaimEscrow`
  and `reclaimResidual` revert while anything is still Pending.
- **Silence pays the fulfiller.** `claimUnjudged` is permissionless: past
  `submittedAt + judgmentWindow`, an unjudged delivery settles to its fulfiller, and
  it ignores both cancellation and `settleBy`. On the machine path it is refused —
  there, code already ruled. Rejecting is still allowed, but it must be said out loud,
  on-chain, inside a window published before any work began.
- **A settlement never depends on the recipient taking the money.** If the transfer
  to the fulfiller fails, the amount is credited and withdrawable later; the
  settlement stands. Reverting instead wedged the submission forever and froze
  every refund behind it — a whole vault lost to nothing worse than a contract
  with a reverting fallback.
- **Refunds no longer depend on who claims first.** The pool and denominator are
  snapshotted at the first reclaim; flooring dust joins the owner residual.
- **A default is still a paced settlement.** `claimUnjudged` respects the epoch
  bound. On a standing tender delivery is not paced but settlement is, so without
  this a provider could hand in every period's work at once and, on the judge's
  silence, drain the whole budget inside one epoch. A blocked claim is queued to
  the next epoch, not lost.
- **And the right to refuse expires with the window.** `rejectFulfillment` reverts
  once the judgment window has closed. Otherwise a judge could stay silent the whole
  window and then front-run the claim with a refusal — and under pacing a queued
  claim would sit exposed for an entire epoch.
- **The settlement mode is snapshotted at delivery.** `Submission.machineSettled`
  records whether a verifier held the judgment slot when the work arrived, and the
  two deadline paths route off that snapshot. Reading the live slot would let a
  demander take delivery under a judge and then swap in a verifier to convert a debt
  into an expiry.
- **And junk cannot squat a machine tender.** `releaseExpired` is the machine-path
  counterpart: past the same deadline, a submission that never produced a valid proof
  is released by anyone, freeing its slot and reward. Without it the reservation rule
  would be a weapon — with no judge to reject junk, filling every slot would freeze
  the vault forever.

`Submission` gains `submittedAt`, so a verifier profile can also require a minimum
submission age against mempool front-running. `TenderTerms` gains `judgmentWindow`.

- Deterministic toolchain closed end-to-end: three frozen vectors (`public-v1`,
  `update-v2-companion-only` with constant `tdHash`, `confidential-v1`) pack, verify,
  and fail correctly on tampered inputs (descriptor/chain mismatch, missing key)
- Contracts compile clean under solc 0.8.24 (optimizer on, 1 run: the reference implementation trades gas for size, zero warnings). `TaskToken`
  deployed runtime code is 23,766 bytes — under the EIP-170 limit of 24,576
  (creation bytecode 24,515); `TaskVault` 1,205, `JuryPanel` 2,720,
  `HashlockVerifier` 1,651. All four interface IDs compiler-verified
- Foundry suite executed on forge 1.7.1: **58/58 tests PASS** (`forge test`), one
  assertion cluster per normative clause
- Full v3 lifecycle proven on a local chain: **108/108 assertions PASS**
  (`scripts/local_e2e.sh`), covering the locked per-token vault (visible balance,
  drain attempts revert, direct-transfer gifts count as escrow), judged settlement
  paying from the vault, permissionless machine settlement via HashlockVerifier
  (wrong proofs leave submissions Pending; copied commitments cannot steal payouts;
  set-once answers), epoch pacing (1/day standing tender across a day boundary),
  JuryPanel 2-of-3 quorum settlement plus timeout-default rejection, terminal
  rejection, completion bounds, cancellation, pro-rata refunds over the attributed
  pool only, the gift-residual rule, and every free-look route: slot and reward
  reservation, sock-puppet slot starvation, refund and residual locks while work is
  Pending, the judgment deadline, its refusal on machine-settled tenders, and the
  machine-path release that stops junk submissions freezing a vault, and the pacing
  of default claims that stops a silent judge draining a standing tender at once

## Worked examples

`examples/` carries end-to-end commercial cases, each a real task package whose
on-chain anchors are re-derivable from this repository:

```
examples/DEPLOYMENTS.md              the Sepolia reference deployment: one contract,
                                      seven tokens, one row per worked example
examples/case-1-labeling-qa/          support-ticket intent labeling settled per batch
                                      against gold-standard QA receipts (machine
                                      judgment, replicated across three annotators)
examples/case-2-media-sla/            a paid-media retainer: one daily report per
                                      period, judged by a person, paced one
                                      settlement per period, with a review deadline
                                      that turns silence into payment
examples/case-3-invoice-agent/         an exclusive FDE build: delivery and decision
                                      deadlines, a rejected first revision, and a
                                      deliverable committed by its own digest
examples/case-3-deliverable-v1/       the rejected build (96.2%)
examples/case-3-deliverable-v2/       the accepted build (98.7%); its package digest
                                      is the resultHash settled on-chain
examples/case-4-tax-opinion/          a confidential professional engagement: the
                                      scope is an encrypted object, the acceptance
                                      standard and its conformance check are public,
                                      and the fee is priced in a stable unit
examples/case-4-tax-opinion-v1/       the same tender at scope revision 1, so the
                                      on-chain version bump is reproducible
examples/case-4-deliverable/          the delivered opinion itself, a real document
                                      that passes the public conformance check
examples/case-5-benchmark-consortium/  a consortium-funded shared benchmark: several
                                      funders, a K-of-N committee none of them
                                      controls, a team paid through a split contract,
                                      and an anonymous gift
examples/teams/FixedSplitter.sol      a team as fulfiller of record: fixed shares in
                                      basis points, pull payments
examples/mocks/DemoUSD.sol            a points-style ERC-20 used to price the
                                      examples; not a stablecoin
examples/verifiers/                   verifier contracts used by the examples;
BatchReceiptVerifier.sol              profile x-batch-receipt-merkle-minage-v1 —
                                      one secret per claim (Merkle root over
                                      sha256(receipt || assigned fulfiller)) plus a
                                      minimum submission age read from `submittedAt`
```

Re-derive every example's anchors with the exact flags the Sepolia record was produced
with — one script, nine packages, byte-for-byte the hashes in `examples/DEPLOYMENTS.md`:

```bash
bash scripts/pack_examples.sh
```

Or individually, the same way as the frozen vectors:

```bash
python3 tools/task-pack/pack.py examples/case-3-invoice-agent --out examples/case-3-invoice-agent/out \
    --primary TASK.md --spec spec/agent-interface.yaml --spec-profile x-invoice-extraction-agent-v1 \
    --acceptance acceptance/evaluation-protocol.md --acceptance-profile x-heldout-scored-eval-v1 \
    --max-completions 1

# the deliverables are packed the same way; their root digest is the settlement commitment
python3 tools/task-pack/pack.py examples/case-3-deliverable-v2 --out examples/case-3-deliverable-v2/out \
    --primary SKILL.md --spec spec/runtime.yaml --spec-profile x-invoice-extraction-agent-v1 --max-completions 1

python3 tools/task-pack/pack.py examples/case-2-media-sla --out examples/case-2-media-sla/out \
    --primary TASK.md --spec spec/daily-report-schema.yaml --spec-profile x-daily-media-report-v1 \
    --acceptance acceptance/review-checklist.md --acceptance-profile x-human-review-checklist-v1 \
    --max-completions 5

python3 tools/task-pack/pack.py examples/case-1-labeling-qa --out examples/case-1-labeling-qa/out     --primary TASK.md --spec spec/labeling-schema.yaml --spec-profile x-support-intent-taxonomy-v1     --acceptance acceptance/gold-standard-qa.md --acceptance-profile x-batch-receipt-merkle-minage-v1     --max-completions 3
```

## Reproducing the vectors

Two independent implementations MUST reproduce `vectors/*/taskroot.cbor` byte-for-byte.

```bash
python3 tools/task-pack/pack.py <task-dir> --out out/ \
    [--primary TASK.md] [--spec spec/api.yaml] \
    [--acceptance acceptance/harness.py --acceptance-profile x-pytest-v1] \
    [--max-completions N] \
    [--version N --prev 0x<previous-taskHash>] \
    [--encrypt path1,path2 --key <hex>]
python3 tools/task-pack/verify.py out/ --tdhash 0x.. --taskhash 0x.. \
    [--version N --previous-taskhash 0x..] [--max-completions N] [--key <hex>]
```

The verifier enforces: taskHash, canonical re-encode byte-equality, closed-map schema +
path rules, spec/acceptance interlocks, the version chain (`digest(prev) == previous
taskHash`), confidentiality descriptor cross-matching against TaskRoot links, per-leaf
digests, plaintext `tdHash`, strict UTF-8 on the primary document, and descriptor/chain
agreement on `maxCompletions`.

## Relationship to ERC-8338

The Task Object Model (tom.py) is byte-compatible with the Skill Object Model (som.py):
identical deterministic DAG-CBOR encoding, identical CID/link form, identical path rules,
identical confidentiality descriptor. A deliverable that is itself an ERC-8338 skill
package settles a task by pointing `resultHash` at that package's `packageHash` — the
reverse asset retires into a forward asset, and the trade `T(f(v), f⁻¹($)) = ($, v)`
clears entirely on-chain.

## Acknowledgments

First-round review on the Ethereum Magicians thread materially improved this draft:

- **chugarchugarr** identified that the Package Boundary clause promised more than the
  design delivers, and supplied the correct scoping — the TaskRoot commits everything
  that *defines* how work is to be judged, never the live state that judgment is later
  performed in. The amended normative text adopts his resolution.
- **babyblueviper1** independently verified the Sepolia deployment by raw `eth_call`
  ("real, not vaporware"), surfaced the verifier-kind disclosure gap now recorded in
  Security Considerations, reframed `judgmentFee` as the price of one recomputable
  ruling (see ROADMAP.md), and proposed the judgment-execution attestation companion.

## License

Specification and reference code released under [CC0](LICENSE).
`x-test-sha256-xor-stream-v1` is a NON-CRYPTOGRAPHIC TEST profile — never use it in production.
