# $DEV Exploit-Derived Supply Forensics — Final

Investigation date: 2026-08-31 / snapshot block: around 25875728
Method: fetched all DEV `Transfer` logs (77 entries) from attack block 25801516 to latest using
`cast` + public/archive RPCs (blastapi.io, drpc.org), and cross-checked fund flows against current balances.

## 1. Attack Fund Flow (Confirmed)

Breakdown of attack TX `0xf7750180…` (single TX / blk 25801516):

1. `mint`: 0x0 → attack contract `0xD138A318…` minted **15,828,035,562.7541 DEV** in one shot
2. The attack contract pulled in **1,628.99 DEV** from third party `0xdfb462bf…` (origin of the third-party contamination)
3. Attack contract → Uniswap V2 pair `0x4168CEF0…`: deposited **15,828,037,191.75 DEV** and
   swapped out nearly all of the pair's WETH (current pair WETH balance = 0.00204 WETH)

Afterwards, the DEV accumulated in the pair was distributed via multiple "buyer / LP withdrawal" routes,
and part of it was sold back to the pair (e.g. 0x1932423f sold back 1.55B on 8/24 at blk 25824384).

**Important**: the current DEV balances of attack EOA `0xBBa56874…` and attack contract `0xD138A318…` are both **0**.
The recoverable exploit-derived DEV resides in "the pair + the exploit-derived supply holders + the illicit backing inside WDEV".

## 2. Current Balances (Snapshot) and Classification

| # | Address | Type | Current DEV balance | Classification | Burn decision |
|---|---|---|---:|---|---|
| 1 | `0x4168cef0fca0774176632d86ba26553e3b9cf59d` (pair) | UniV2 Pair | 3,084,441,317.15 | Residue of attack deposit (pre-attack held 3,182,715.97) | **Burn 增量 only + sync** |
| 2 | `0x58d3382fc3fc09b08ee4560a41008856321e926d` | 7702-EOA | 5,772,466,343.61 | Exploit-derived supply holder | **Burn (FULL)** |
| 3 | `0x1932423fef71a47fa6eeaaf99149adba42fe95a5` | EOA | 2,999,999,000.00 | Exploit-derived supply holder (8/24 sell-back) | **Burn (FULL)** |
| 4 | `0x6f9fe645408960ef52f7018fcb2507722feaa740` | EOA | 1,695,715,383.49 | Exploit-derived supply holder | **Burn (FULL)** |
| 5 | `0x4b0d30d98390f3079ae812732300fa3138bda775` | EOA | 1,504,302,751.31 | Exploit-derived supply holder | **Burn (FULL)** |
| 6 | `0xe9084b1b98d3ceb3cb42691e31c9e1f1231498f5` | 7702-EOA | 493,801,418.66 | Large holder, exploit-derived route (via 0x0889e932) | **Burn (FULL)** |
| 7 | `0xef7afd67cf7d2eaa3b3dd200a82747134748c22d` | EOA | 173,149,035.76 | Large holder, same aggregator route as exploit-derived holders | **Burn (FULL)** |
| 8 | `0x4a5df63b0c37b38515e4ee51baf40edd420bf7d5` (WDEV) | Wrapper | 100,153,849.71 | Illicit wrap 100M + third-party 153,849.71 | **Burn (fixed 100M)** |
| 9 | `0x90cbe4bdd538d6e9b379bff5fe72c3d67a521de5` | FeeCollector (protocol fee contract) | 5,611,789.08 | Exploit-derived 0.3% fees (pre-attack held 220.40) | **Burn 增量 only** |
| 10 | `0x2c00d792e2c1e4f13d223da640a4d76c16b6d170` | EOA | 1,558,681.99 | MEV/aggregator (`0xc0dfdb9e` route), received 1,731,868.87 DEV at blk 25801517 (attack+1); pre-attack balance 0 | **Burn (FULL)** — exploit-derived, INCLUDE |
| 11 | `0x305b38ec316c13f2322e1ea0c959a771667fb8e4` | EOA | 173,186.89 | Downstream of `0x2c00d792` (exact 10% recipient: 1,731,868.87 × 0.10); pre-attack balance 0 | **Burn (FULL)** — exploit-derived, INCLUDE |
| — | `0xd138a318…` (attack contract) | Contract | 0 | Attack principal | Excluded (0 balance) |
| — | `0xBBa56874…` (attack EOA/7702) | 7702-EOA | 0 | Attack principal | Excluded (0 balance) |
| — | `0x09bcf378…` | EOA | 0 | Round trip (net 0) | Excluded |
| — | `0x894e58b1bbae00812999cd78ec87f92c463caad1` | EOA | 1,000.00 | Third-party dust | Excluded (third-party) |
| — | `0xdfb462bfd71128b96db742a2621aeb801c4fd611` | Contract | 100.00 | Contamination origin (source of the 1,629 pull) | Excluded (third-party) |

`0x9923263fa127b3d1484cfd649df8f1831c2a74e4` (upgradeable proxy) is the current holder of the illicit
100M WDEV, but its **DEV balance is 0** (it holds only WDEV). It is not a direct DEV burn target.

### Note on 0x58d3 / 0x1932 / 0x4b0d (attribution disputed, burn included)

Forensic review cannot determine these three addresses to be attacker-controlled; the third-party opportunistic-buyer hypothesis is strong. That attribution dispute is **irrelevant to the burn decision**: the tokens they hold are exploit-derived supply regardless of who holds them. They are INCLUDED for supply correction.

### Attribution-neutral supply correction

Attribution to specific actors is **not required** for supply correction. The burn targets exploit-derived tokens that should not exist in circulating supply:

- **Nemo dat quod non habet** — no one can transfer better title than they have; exploit-minted DEV does not create good title in downstream holders.
- **Acala precedent** — supply correction of exploit-derived tokens without requiring per-holder attacker attribution.
- **`Dev.fee()` as existing mechanism** — the protocol already exposes an authorized burn path used here for remediation; this is supply correction via an existing tool, not a novel seizure power.

### Traces of 7702 Delegation (actively used on mainnet)

The attack EOA and some exploit-derived supply holders are EIP-7702-delegated smart EOAs:
- `0xBBa56874…` → `0xef0100 63c0c19a282a1b52b07dd5a65b58948a07dae32b`
- `0x58d3382f…` → `0xef0100 490aac77c960b0569c8e446ac7e12490bd44ca1d`
- `0xe9084b1b…` → `0xef0100 80296ff8d1ed46f8e3c7992664d13b833504c2bb`

→ **Direct evidence that 7702 is live on mainnet today** (supporting the feasibility of Path B).

## 3. Inclusion Criteria (Explicit)

**Include in burn targets (INCLUDE)** — exploit-derived supply requiring correction:
1. The attack EOA / attack contract themselves (included in BurnTarget for idempotency even at 0 balance).
2. The four large exploit-derived supply holders from the post-attack distribution (0x58d3, 0x1932, 0x6f9f, 0x4b0d). Attribution to the attacker is not required; the balances are exploit-derived.
3. Addresses that, immediately after the attack (± a few hundred blocks), received **more than 10,000,000 DEV**
   from the pair via the attacker's aggregators
   (`0xc0dfdb9e` / `0x0889e932` / MEV routers `0x0000…d29` `0x0000…ba9c`) within **≤2 hops**,
   still hold a large balance today, and cannot be identified as a neutral entity such as a CEX, LP, or public router
   (= 0xe908, 0xef7a).
   #10 `0x2c00d792` (1.56M) and #11 `0x305b38ec` (173k) are also INCLUDED (2026-09-03 decision):
   both had a pre-attack balance of 0 and hold only exploit-derived DEV (MEV/aggregator
   `0xc0dfdb9e` recipient at blk 25801517, and its exact 10% downstream). Not legitimate
   third-party LPs or ordinary holders.
4. The illicit wrap portion inside WDEV (**fixed 100,000,000 DEV**; a full burn is not acceptable — see below).
5. FeeCollector (`0x90cbe4bd`) — protocol fee contract holding 0.3% swap fees from the contaminated pair.
   Burn only the exploit-derived 增量 (`current − 220400025594150502` pre-attack at block 25801515).
6. Pair (`0x4168cef0`) — burn only the exploit-derived 增量 (`current − 3182715966190325101277057` pre-attack), then `sync()`.

**Exclude from burn targets (EXCLUDE)**:
- Neutral infrastructure: DEX routers, MEV bots, aggregator pass-throughs (current balance 0).
- Small holdings of ordinary buyers (`0x894e58b1` 1,000 / contamination origin `0xdfb462bf` 100).
  These constitute the residual third-party contamination. Not burnable (collateral damage to uninvolved parties).
- (`0x2c00d792` and `0x305b38ec` were moved from EXCLUDE/Grey to INCLUDE on 2026-09-03; see #10/#11 above.)

## 4. Burn Simulation Results (fork-proven: ClusterBurnFork.t.sol) — pre-execution estimates

- Current totalSupply at investigation time: **15,837,968,767.688425741 DEV**
- Pre-attack totalSupply (archive-verified at blk 25801515): **9,933,204.934315354 DEV** (= current supply − **15,828,035,562.7541** mint)
- Total burn under the executed plan (#1–#11, WDEV = fixed 100M, pair/FeeCollector = 增量 only): burns the exploit-derived portion while sparing pre-attack pair (3,182,715.97) and FeeCollector (220.40)
- Pair and FeeCollector retain their pre-attack balances after the 增量 burn; WDEV's 153,849.71 third-party backing remains inside WDEV (part of the pre-attack floor, not additional to it)
- With #10 `0x2c00d792` and #11 `0x305b38ec` INCLUDED (2026-09-03), the post-burn supply lands within
  ≈629 DEV **below** the pre-attack floor (see §5 reconciliation: −1,628.99 legitimate pulled-in burned, +1,100
  third-party dust intentionally spared), instead of ≈1.73M above it under the #1–#9 plan.

**Note**: pair and FeeCollector held legitimate DEV before the attack (verified at block 25801515). Burning FULL would destroy that
pre-attack liquidity/fees; the recommended plan burns only `current − pre-attack`. `0x2c00d792` and `0x305b38ec`
had pre-attack balances of 0, so a FULL burn destroys no legitimate holdings.

## 5. Execution Record (mainnet, 2026-09-03)

Executed via `scripts/path_a_bundle.sh` (Path A: Flashbots bundle TX1 factory→Settlement, TX2 `settle`, TX3 factory→ORIGF).

- **Land block**: 25897353. TX2 `0xa433d9ab04ec19099754d4c17e967466fba350948cb6c292bdd9b1b9164ebe29` (Settlement `0x535d2d9266a41441a8a6eb4a2f6329e08a31de9a`, executor `0x22b5975fc07af43eb1eaad46e6a2a224d718f06a`), receipt status 1, gasUsed 253,720. All three txs landed in one block; `marketFactory` restored to ORIGF in the same block.
- **`Settled` event**: `targets=11`, `totalBurned=15,828,036,191.747307724555483759 DEV`, `supplyAfter=9,932,575.941118016729992203 DEV`.
- **Post-burn state (RUNBOOK §3 verify, all ✔)**: pair DEV + DEV-side reserve = `3182715966190325101277057` (pre-attack); FeeCollector = `220400025594150502` (pre-attack); CL1–CL8 (#2–#7 + #10 + #11) = 0; WDEV backing = 153,849.712469344324277075 DEV with WDEV `totalSupply` unchanged at 100,153,849.712469344324277075; `isGroup(Settlement)` false; `getCount` 6.
- **Reconciliation vs pre-attack floor** (totalSupply at blk 25801515 = 9,933,204.934315354419250810 DEV, via archive node):
  - `after − pre = −628.993197337689 DEV`. Decomposition: the attack pulled **1,628.993201689603 DEV** of legitimate third-party DEV (from `0xdfb462bf…`) into the exploit flow and it was burned with the cluster, while **1,000 DEV** of exploit-derived dust at `0x894e58b1…` (and `100 DEV` at `0xdfb462bf…` itself) was deliberately left unburned (third-party). Net ≈ −629 DEV of over-correction, i.e. the burn removed 1,628.99 DEV of legitimate supply to eliminate 15.83B of exploit supply.
  - Residual unburned exploit-derived DEV: ≈ **1,100 DEV** (`0x894e58b1` 1,000 + `0xdfb462bf` 100) plus ≈4.35×10⁻⁶ DEV of dust-accounting noise from pair movement between snapshot and land.
- **Provenance**: `0x2c00d792` acquired via swap (0.001066382 WETH invested at blk 25801517, no sales); `0x305b38ec` received its 173,186.887 DEV via a plain `transfer()` from `0x2c00d792` (tx `0x6804263e…`, blk 25871856), not a swap — zero cost basis.
