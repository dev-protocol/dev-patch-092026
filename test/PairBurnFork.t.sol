// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniTest} from "./lib/MiniTest.sol";
import {Settlement} from "../src/Settlement.sol";
import {IAddressConfig, IDev, IMarketGroup, IUniswapV2Pair} from "../src/interfaces/IDevProtocol.sol";

/// Validates the HARDEST part on a real fork: burning the Uniswap V2 pair's
/// exploit-derived DEV increment via Dev.fee(pair) then sync(), while sparing
/// the pre-attack legitimate reserve (same increment rule as ClusterBurnFork).
contract PairBurnForkTest is MiniTest {
    address constant DEV = address(uint160(0x005caf454ba92e6f2c929df14667ee360ed9fd5b26));
    address constant CONFIG = address(uint160(0x001d415aa39d647834786eb9b5a333a50e9935b796));
    address constant PAIR = address(uint160(0x004168cef0fca0774176632d86ba26553e3b9cf59d));

    // Pre-attack pair DEV at block 25801515. Do NOT FULL_BALANCE — that would
    // destroy this legitimate liquidity. Production encodes KEEP_OFFSET + this
    // remainder so execution-time balance drift cannot freeze a stale delta.
    uint256 constant PAIR_PRE_ATTACK = 3_182_715_966_190_325_101_277_057;

    function test_PairBurn_EndToEnd() public {
        try vm.createSelectFork("mainnet") {} catch {
            emit log("SKIP: no RPC");
            return;
        }

        IAddressConfig config = IAddressConfig(CONFIG);
        IDev dev = IDev(DEV);
        IMarketGroup mg = IMarketGroup(config.marketGroup());
        address owner = config.owner();
        address originalFactory = config.marketFactory();

        uint256 pairBal = dev.balanceOf(PAIR);
        uint256 supplyBefore = dev.totalSupply();
        require(pairBal >= PAIR_PRE_ATTACK, "pair bal < pre-attack");
        uint256 delta = pairBal - PAIR_PRE_ATTACK;
        emit log_named_uint("pair DEV (wei)", pairBal);
        emit log_named_uint("pair delta (wei)", delta);
        emit log_named_uint("supply (wei)", supplyBefore);
        assertGt(delta, 0, "pair should hold exploit-derived DEV");

        Settlement s = new Settlement(config, address(this));

        // owner tx 1: repoint factory
        vm.prank(owner);
        config.setMarketFactory(address(s));

        // single atomic tx: burn down to the pre-attack remainder, then sync
        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](1);
        t[0] = Settlement.BurnTarget(PAIR, s.KEEP_OFFSET() + PAIR_PRE_ATTACK);
        address[] memory pairs = new address[](1);
        pairs[0] = PAIR;
        uint256 burned = s.settle(t, pairs);

        emit log_named_uint("burned (wei)", burned);
        assertEq(burned, delta, "burned == pair live-pre keep delta");
        assertEq(dev.balanceOf(PAIR), PAIR_PRE_ATTACK, "pair keeps pre-attack");
        assertEq(dev.totalSupply(), supplyBefore - delta, "supply reduced by delta");

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(PAIR).getReserves();
        uint256 devReserve = IUniswapV2Pair(PAIR).token0() == DEV ? r0 : r1;
        emit log_named_uint("pair DEV reserve after sync", devReserve);
        assertEq(devReserve, PAIR_PRE_ATTACK, "reserve synced to pre-attack");

        assertTrue(!mg.isGroup(address(s)), "membership revoked");

        vm.prank(owner);
        config.setMarketFactory(originalFactory);
    }
}
