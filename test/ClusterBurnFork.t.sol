// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniTest} from "./lib/MiniTest.sol";
import {Settlement} from "../src/Settlement.sol";
import {IAddressConfig, IDev, IMarketGroup, IUniswapV2Pair} from "../src/interfaces/IDevProtocol.sol";

/**
 * FULL remediation dress-rehearsal on a mainnet fork, using the ACTUAL cluster addresses
 * and live balances discovered by forensics. Balances change daily (attacker keeps
 * selling), so this test reads them at fork time and asserts relative outcomes — it stays
 * green regardless of the day it is run.
 *
 * Burn set (recommended "Plan B++"):
 *   - 8 exploit-derived cluster wallets  → FULL_BALANCE
 *     (CL7/CL8 added 2026-09-03: MEV/aggregator recipient at blk 25801517
 *      and its exact 10% downstream; both pre-attack balance 0)
 *   - WDEV contract                      → FIXED 100,000,000 DEV (spares legit backing)
 *   - FeeCollector                       → KEEP_OFFSET + pre-attack remainder
 *   - Uniswap V2 pair                    → KEEP_OFFSET + pre-attack remainder, then sync()
 */
contract ClusterBurnForkTest is MiniTest {
    address constant DEV = address(uint160(0x005caf454ba92e6f2c929df14667ee360ed9fd5b26));
    address constant CONFIG = address(uint160(0x001d415aa39d647834786eb9b5a333a50e9935b796));
    address constant PAIR = address(uint160(0x004168cef0fca0774176632d86ba26553e3b9cf59d));
    address constant WDEV = address(uint160(0x004a5df63b0c37b38515e4ee51baf40edd420bf7d5));
    address constant FEE_COLLECTOR = address(uint160(0x0090cbe4bdd538d6e9b379bff5fe72c3d67a521de5));

    // Exploit-derived supply holders (see forensics/CLUSTER.md).
    address constant C_58D3 = address(uint160(0x0058d3382fc3fc09b08ee4560a41008856321e926d));
    address constant C_1932 = address(uint160(0x001932423fef71a47fa6eeaaf99149adba42fe95a5));
    address constant C_6F9F = address(uint160(0x006f9fe645408960ef52f7018fcb2507722feaa740));
    address constant C_4B0D = address(uint160(0x004b0d30d98390f3079ae812732300fa3138bda775));
    address constant C_E908 = address(uint160(0x00e9084b1b98d3ceb3cb42691e31c9e1f1231498f5));
    address constant C_EF7A = address(uint160(0x00ef7afd67cf7d2eaa3b3dd200a82747134748c22d));

    // Exploit-derived, added 2026-09-03 (see forensics/CLUSTER.md #10/#11).
    // CL7: MEV/aggregator (0xc0dfdb9e) recipient — 1,731,868.87 DEV at blk 25801517, pre-attack balance 0.
    // CL8: exact 10% downstream of CL7 (1,731,868.87 × 0.10), pre-attack balance 0.
    address constant C_2C00 = address(uint160(0x002c00d792e2c1e4f13d223da640a4d76c16b6d170));
    address constant C_305B = address(uint160(0x00305b38ec316c13f2322e1ea0c959a771667fb8e4));

    uint256 constant ILLICIT_WRAPPED = 100_000_000 ether;

    // Pre-attack balances verified on-chain at block 25801515 (spared; only 增量 is burned).
    uint256 constant PAIR_PRE_ATTACK = 3_182_715_966_190_325_101_277_057;
    uint256 constant FEE_COLLECTOR_PRE_ATTACK = 220_400_025_594_150_502;

    function _fork() internal returns (bool) {
        try vm.createSelectFork("mainnet") returns (uint256) { return true; }
        catch { return false; }
    }

    function test_FullClusterBurn_EndToEnd() public {
        if (!_fork()) { emit log("SKIP: no RPC"); return; }

        IAddressConfig config = IAddressConfig(CONFIG);
        IDev dev = IDev(DEV);
        IMarketGroup mg = IMarketGroup(config.marketGroup());
        address owner = config.owner();
        address originalFactory = config.marketFactory();

        address[8] memory cluster = [C_58D3, C_1932, C_6F9F, C_4B0D, C_E908, C_EF7A, C_2C00, C_305B];

        uint256 supplyBefore = dev.totalSupply();
        uint256 pairBal = dev.balanceOf(PAIR);
        uint256 feeCollectorBal = dev.balanceOf(FEE_COLLECTOR);
        require(pairBal >= PAIR_PRE_ATTACK, "pair bal < pre-attack");
        require(feeCollectorBal >= FEE_COLLECTOR_PRE_ATTACK, "feeCollector bal < pre-attack");

        uint256 expectedBurn = ILLICIT_WRAPPED; // WDEV fixed portion
        for (uint256 i = 0; i < cluster.length; i++) {
            expectedBurn += dev.balanceOf(cluster[i]);
        }
        // Pair / FeeCollector: burn only exploit-derived 增量 (current − pre-attack).
        expectedBurn += feeCollectorBal - FEE_COLLECTOR_PRE_ATTACK;
        expectedBurn += pairBal - PAIR_PRE_ATTACK;
        emit log_named_uint("supply before (wei)", supplyBefore);
        emit log_named_uint("expected burn (wei)", expectedBurn);

        Settlement s = new Settlement(config, address(this));

        // Owner tx #1 — repoint factory.
        vm.prank(owner);
        config.setMarketFactory(address(s));

        // Build the burn set: 8 cluster FULL + WDEV fixed + FeeCollector/pair keep-remainder.
        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](11);
        for (uint256 i = 0; i < cluster.length; i++) {
            t[i] = Settlement.BurnTarget(cluster[i], type(uint256).max);
        }
        t[8] = Settlement.BurnTarget(WDEV, ILLICIT_WRAPPED);
        // FeeCollector / pair: leave the pre-attack remainder (KEEP_OFFSET encoding).
        t[9] = Settlement.BurnTarget(FEE_COLLECTOR, s.KEEP_OFFSET() + FEE_COLLECTOR_PRE_ATTACK);
        t[10] = Settlement.BurnTarget(PAIR, s.KEEP_OFFSET() + PAIR_PRE_ATTACK);
        address[] memory pairs = new address[](1);
        pairs[0] = PAIR;

        // The single atomic remediation tx.
        uint256 burned = s.settle(t, pairs);

        assertEq(burned, expectedBurn, "burned == cluster FULL + WDEV fixed + pair/FeeCollector delta");
        assertEq(dev.totalSupply(), supplyBefore - expectedBurn, "supply reduced exactly");

        // Every cluster wallet zeroed.
        for (uint256 i = 0; i < cluster.length; i++) {
            assertEq(dev.balanceOf(cluster[i]), 0, "cluster wallet drained");
        }
        // FeeCollector / pair retain only the pre-attack legitimate balance.
        assertEq(dev.balanceOf(FEE_COLLECTOR), FEE_COLLECTOR_PRE_ATTACK, "FeeCollector keeps pre-attack");
        assertEq(dev.balanceOf(PAIR), PAIR_PRE_ATTACK, "pair keeps pre-attack");
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(PAIR).getReserves();
        uint256 devReserve = IUniswapV2Pair(PAIR).token0() == DEV ? r0 : r1;
        assertEq(devReserve, PAIR_PRE_ATTACK, "pair DEV reserve synced to pre-attack");

        // Membership self-revoked in the same tx.
        assertTrue(!mg.isGroup(address(s)), "membership revoked");

        // Supply lands near the legitimate floor (9.93M) + unrecoverable contamination.
        emit log_named_uint("supply after (wei)", dev.totalSupply());

        // Owner tx #2 — restore.
        vm.prank(owner);
        config.setMarketFactory(originalFactory);
        assertEq(config.marketFactory(), originalFactory, "factory restored");
    }
}
