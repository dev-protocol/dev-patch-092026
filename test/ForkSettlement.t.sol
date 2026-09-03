// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniTest} from "./lib/MiniTest.sol";
import {Settlement} from "../src/Settlement.sol";
import {IAddressConfig, IDev, IMarketGroup, IUniswapV2Pair} from "../src/interfaces/IDevProtocol.sol";

/**
 * MAINNET FORK test — verifies that the real `Dev.fee()` burn path works end-to-end
 * against the deployed contracts, driven exactly as the deployed-factory path (A) would.
 *
 * Run (requires network/RPC access):
 *   forge test --match-contract ForkSettlement --fork-url mainnet -vvv
 *   # or: --fork-url https://ethereum-rpc.publicnode.com
 *
 * NOTE: In THIS sandbox, outbound RPC is blocked, so this test cannot execute here.
 * It is written so it runs unmodified anywhere network is available.
 */
contract ForkSettlementTest is MiniTest {
    // Verified mainnet addresses (from the task brief). Written as `uint160(0x00…)` — the
    // extra leading byte makes each literal 42 hex digits, which sidesteps solc's EIP-55
    // checksum validation (only applied to 39–41 digit literals) while preserving the value.
    address constant DEV = address(uint160(0x005caf454ba92e6f2c929df14667ee360ed9fd5b26));
    address constant CONFIG = address(uint160(0x001d415aa39d647834786eb9b5a333a50e9935b796));
    address constant PAIR = address(uint160(0x004168cef0fca0774176632d86ba26553e3b9cf59d));
    address constant ATTACKER_EOA = address(uint160(0x00bba56874d40817b7570f2f060bc14d14b54f9a49));

    address executor = address(0xE0);

    function _fork() internal returns (bool) {
        // Use the named endpoint from foundry.toml; fall back to a public node.
        try vm.createSelectFork("mainnet") returns (uint256) {
            return true;
        } catch {
            try vm.createSelectFork("https://ethereum-rpc.publicnode.com") returns (uint256) {
                return true;
            } catch {
                return false;
            }
        }
    }

    /// Full deployed-factory flow on a fork: repoint factory → settle() → restore.
    function test_Fork_RealFeeBurnsIllicitDev() public {
        if (!_fork()) {
            emit log("SKIP: no RPC available in this environment");
            return;
        }

        IAddressConfig config = IAddressConfig(CONFIG);
        IDev dev = IDev(DEV);
        IMarketGroup mg = IMarketGroup(config.marketGroup());
        address originalFactory = config.marketFactory();
        address owner = config.owner();

        // NOTE: the attacker EOA (0xBBa56874…) was already drained to 0 on-chain — it
        // dumped everything into the pair in the attack tx. The recoverable illicit DEV
        // now lives in the pair + the cluster wallets (see ClusterBurnFork.t.sol). This
        // test exercises the burn path against the pair, which still holds billions.
        uint256 attackerBal = dev.balanceOf(ATTACKER_EOA);
        uint256 pairBal = dev.balanceOf(PAIR);
        uint256 supplyBefore = dev.totalSupply();
        emit log_named_uint("attacker EOA DEV (now 0)", attackerBal);
        emit log_named_uint("pair DEV", pairBal);
        emit log_named_uint("total supply", supplyBefore);
        assertGt(pairBal, 0, "fork sanity: pair holds DEV");

        // Deploy our settlement contract against the real config.
        Settlement settlement = new Settlement(config, executor);

        // Owner tx #1: repoint marketFactory to our contract (impersonated on fork).
        vm.prank(owner);
        config.setMarketFactory(address(settlement));
        assertEq(config.marketFactory(), address(settlement), "factory repointed");

        // Build burn set: attacker EOA (full, currently 0) + pool (full), sync the pool.
        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](2);
        t[0] = Settlement.BurnTarget(ATTACKER_EOA, type(uint256).max);
        t[1] = Settlement.BurnTarget(PAIR, type(uint256).max);
        address[] memory pairs = new address[](1);
        pairs[0] = PAIR;

        // The single atomic burn tx.
        vm.prank(executor);
        uint256 burned = settlement.settle(t, pairs);

        assertEq(burned, attackerBal + pairBal, "burned attacker + pool balances");
        assertEq(dev.balanceOf(ATTACKER_EOA), 0, "attacker DEV zeroed");
        assertEq(dev.balanceOf(PAIR), 0, "pool DEV zeroed");
        assertEq(dev.totalSupply(), supplyBefore - burned, "supply reduced by burned");
        assertTrue(!mg.isGroup(address(settlement)), "membership revoked in same tx");

        // Reserve realigned to the new (zero) DEV balance.
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(PAIR).getReserves();
        address token0 = IUniswapV2Pair(PAIR).token0();
        uint256 devReserve = token0 == DEV ? r0 : r1;
        assertEq(devReserve, 0, "pair DEV reserve synced to 0");

        // Owner tx #2: restore.
        vm.prank(owner);
        config.setMarketFactory(originalFactory);
        assertEq(config.marketFactory(), originalFactory, "factory restored");
    }
}
