// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniTest} from "./lib/MiniTest.sol";
import {Settlement} from "../src/Settlement.sol";
import {IAddressConfig, IDev, IMarketGroup, IUniswapV2Pair} from "../src/interfaces/IDevProtocol.sol";

/// @dev The real mainnet AddressConfig is OpenZeppelin `Ownable`. `transferOwnership` is
///      onlyOwner and is NOT in the production interface (Settlement never calls it), so we
///      declare the minimal extension the fork test needs to emulate a 7702 delegation.
interface IOwnable {
    function transferOwnership(address newOwner) external;
}

/**
 * MAINNET FORK test — Path (B), `settleAsOwner`, end-to-end against the real contracts.
 *
 * Emulates the EIP-7702 owner-delegate flow: under a real 7702 authorization the owner EOA
 * runs THIS code as its own account, so `address(this) == config.owner() == msg.sender`.
 * We reproduce that on a fork by transferring AddressConfig ownership to the deployed
 * Settlement (making `config.owner() == address(settlement)`) and then calling
 * `settleAsOwner` self-sponsored (`vm.prank(address(settlement))`).
 *
 * This proves Path B works: ONE call performs setMarketFactory(self) → addGroup(self) →
 * burn every target → sync the pool → deleteGroup(self) → restore the original factory.
 *
 * Run (requires network/RPC access):
 *   forge test --match-contract ForkSettlement7702 --fork-url mainnet -vvv
 *
 * NOTE: In THIS sandbox outbound RPC is blocked, so the fork tests SKIP. They run unmodified
 * anywhere a mainnet RPC is reachable.
 */
contract ForkSettlement7702Test is MiniTest {
    // Verified mainnet addresses (uint160(0x00…) form sidesteps solc's EIP-55 checksum on
    // 40-hex literals while preserving the value — same convention as the other fork tests).
    address constant DEV = address(uint160(0x005caf454ba92e6f2c929df14667ee360ed9fd5b26));
    address constant CONFIG = address(uint160(0x001d415aa39d647834786eb9b5a333a50e9935b796));
    address constant PAIR = address(uint160(0x004168cef0fca0774176632d86ba26553e3b9cf59d));
    address constant WDEV = address(uint160(0x004a5df63b0c37b38515e4ee51baf40edd420bf7d5));

    // Exploit-derived supply holders (see forensics/CLUSTER.md) — same set as ClusterBurnFork.
    address constant C_58D3 = address(uint160(0x0058d3382fc3fc09b08ee4560a41008856321e926d));
    address constant C_1932 = address(uint160(0x001932423fef71a47fa6eeaaf99149adba42fe95a5));
    address constant C_6F9F = address(uint160(0x006f9fe645408960ef52f7018fcb2507722feaa740));
    address constant C_4B0D = address(uint160(0x004b0d30d98390f3079ae812732300fa3138bda775));
    address constant C_E908 = address(uint160(0x00e9084b1b98d3ceb3cb42691e31c9e1f1231498f5));
    address constant C_EF7A = address(uint160(0x00ef7afd67cf7d2eaa3b3dd200a82747134748c22d));

    uint256 constant ILLICIT_WRAPPED = 100_000_000 ether; // WDEV fixed portion (spares legit backing)

    function _fork() internal returns (bool) {
        // Named endpoint from foundry.toml, then a public fallback for RPC resilience.
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

    /// Full Path-B remediation in a SINGLE self-sponsored `settleAsOwner` call.
    function test_Fork7702_SettleAsOwner_EndToEnd() public {
        if (!_fork()) {
            emit log("SKIP: no RPC available in this environment");
            return;
        }

        IAddressConfig config = IAddressConfig(CONFIG);
        IDev dev = IDev(DEV);
        IMarketGroup mg = IMarketGroup(config.marketGroup());
        address owner = config.owner();
        address originalFactory = config.marketFactory();

        address[6] memory cluster = [C_58D3, C_1932, C_6F9F, C_4B0D, C_E908, C_EF7A];

        // Expected burn = live cluster balances + fixed WDEV portion + live pair balance.
        uint256 supplyBefore = dev.totalSupply();
        uint256 expectedBurn = ILLICIT_WRAPPED;
        for (uint256 i = 0; i < cluster.length; i++) {
            expectedBurn += dev.balanceOf(cluster[i]);
        }
        uint256 pairBal = dev.balanceOf(PAIR);
        expectedBurn += pairBal;
        assertGt(pairBal, 0, "fork sanity: pair holds DEV");
        emit log_named_uint("supply before (wei)", supplyBefore);
        emit log_named_uint("expected burn (wei)", expectedBurn);

        // Deploy the burn executor against the REAL config.
        Settlement s = new Settlement(config, address(this));

        // 7702 emulation: make the owner account BE the settlement code by pointing
        // config.owner() at address(s). Under a real 7702 delegation this identity holds
        // because the owner EOA's code == this implementation.
        vm.prank(owner);
        IOwnable(CONFIG).transferOwnership(address(s));
        assertEq(config.owner(), address(s), "ownership delegated to settlement (7702 emu)");

        // Build the burn set: 6 cluster FULL + WDEV fixed + pair FULL = 8 targets.
        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](8);
        for (uint256 i = 0; i < cluster.length; i++) {
            t[i] = Settlement.BurnTarget(cluster[i], type(uint256).max);
        }
        t[6] = Settlement.BurnTarget(WDEV, ILLICIT_WRAPPED);
        t[7] = Settlement.BurnTarget(PAIR, type(uint256).max);
        address[] memory pairs = new address[](1);
        pairs[0] = PAIR;

        // The single atomic tx. Self-sponsored: the owner account calls itself, so
        // msg.sender == address(s) == config.owner().
        vm.prank(address(s));
        uint256 burned = s.settleAsOwner(originalFactory, t, pairs);

        // Burned amounts and supply reduction.
        assertEq(burned, expectedBurn, "burned == sum of live balances + fixed WDEV");
        assertEq(dev.totalSupply(), supplyBefore - expectedBurn, "supply reduced exactly");

        // Every cluster wallet zeroed.
        for (uint256 i = 0; i < cluster.length; i++) {
            assertEq(dev.balanceOf(cluster[i]), 0, "cluster wallet drained");
        }

        // Pair zeroed and reserve resynced to 0.
        assertEq(dev.balanceOf(PAIR), 0, "pair drained");
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(PAIR).getReserves();
        uint256 devReserve = IUniswapV2Pair(PAIR).token0() == DEV ? r0 : r1;
        assertEq(devReserve, 0, "pair DEV reserve synced to 0");

        // Membership self-revoked AND factory restored — all in the same single tx.
        assertTrue(!mg.isGroup(address(s)), "membership revoked in same tx");
        assertEq(config.marketFactory(), originalFactory, "factory restored in same tx");

        emit log_named_uint("supply after (wei)", dev.totalSupply());
    }

    /// Guard: with the 7702 identity in place (address(this)==owner), a NON-self caller must
    /// be rejected by the `msg.sender == address(this)` self-sponsorship check.
    function test_Fork7702_RejectsRelaySponsor() public {
        if (!_fork()) {
            emit log("SKIP: no RPC available in this environment");
            return;
        }

        IAddressConfig config = IAddressConfig(CONFIG);
        address owner = config.owner();
        address originalFactory = config.marketFactory();

        Settlement s = new Settlement(config, address(this));

        // Delegate ownership to the settlement so the owner-identity check would pass...
        vm.prank(owner);
        IOwnable(CONFIG).transferOwnership(address(s));

        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](1);
        t[0] = Settlement.BurnTarget(PAIR, type(uint256).max);
        address[] memory pairs = new address[](1);
        pairs[0] = PAIR;

        // ...but a separate relay/sponsor (msg.sender != address(this)) is blocked. This is
        // exactly why relay-separated 7702 is unsupported (see RUNBOOK §5).
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("must be self-sponsored (7702)"));
        s.settleAsOwner(originalFactory, t, pairs);
    }
}
