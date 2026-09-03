// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniTest} from "./lib/MiniTest.sol";
import {Settlement} from "../src/Settlement.sol";
import {IAddressConfig, IDev} from "../src/interfaces/IDevProtocol.sol";
import {MockAddressConfig, MockMarketGroup, MockDev, MockPair} from "./mocks/Mocks.sol";

/**
 * Offline (no-RPC) integration test. Reproduces the exact on-chain gating —
 * setMarketFactory=onlyOwner, addGroup=onlyFactory, fee=onlyGroupMember — and proves:
 *   1. The deployed-factory path burns every target + syncs pools in ONE atomic call.
 *   2. Membership is self-granted and self-revoked within that same call.
 *   3. Without the owner's setMarketFactory step, settle() cannot even self-register.
 *   4. The EIP-7702 owner path does registration+burn+restore in one call.
 * Run: forge test -vvv   (fully offline; solc 0.8.24 is cached locally)
 */
contract SettlementTest is MiniTest {
    address owner = address(0x1dCb85e0);
    address executor = address(0xE0);

    MockAddressConfig config;
    MockMarketGroup mg;
    MockDev dev;
    MockPair pair;

    // stand-ins for the attack cluster / WDEV / pair
    address attacker1 = address(0xA1);
    address attacker2 = address(0xA2);
    address wdev = address(0xD0);

    Settlement settlement;
    address originalFactory = address(0xF0F0);

    function setUp() public {
        vm.startPrank(owner);
        config = new MockAddressConfig(owner);
        dev = new MockDev(IAddressConfig(address(config)));
        mg = new MockMarketGroup(IAddressConfig(address(config)));
        config.setToken(address(dev));
        config.setMarketGroup(address(mg));
        config.setMarketFactory(originalFactory); // pre-existing real factory
        vm.stopPrank();

        pair = new MockPair(dev);

        // Illicit balances: attackers, WDEV, and the pool.
        dev.mint(attacker1, 7_000_000_000 ether);
        dev.mint(attacker2, 5_650_000_000 ether);
        dev.mint(wdev, 100_000_000 ether);
        dev.mint(address(pair), 3_080_000_000 ether);
        pair.sync(); // reserve now reflects pool DEV

        settlement = new Settlement(IAddressConfig(address(config)), executor);
    }

    function _targets() internal view returns (Settlement.BurnTarget[] memory t) {
        t = new Settlement.BurnTarget[](4);
        t[0] = Settlement.BurnTarget(attacker1, type(uint256).max); // full balance
        t[1] = Settlement.BurnTarget(attacker2, type(uint256).max);
        t[2] = Settlement.BurnTarget(wdev, type(uint256).max);
        t[3] = Settlement.BurnTarget(address(pair), type(uint256).max);
    }

    /// Path (A): burn is a single atomic tx once the owner has repointed marketFactory.
    function test_DeployedFactory_AtomicBurn() public {
        uint256 supplyBefore = dev.totalSupply();

        // Owner tx #1 — registration (repoint factory to our contract).
        vm.prank(owner);
        config.setMarketFactory(address(settlement));

        address[] memory pairs = new address[](1);
        pairs[0] = address(pair);

        // Single atomic tx: self-register → burn 4 targets → sync → self-deregister.
        vm.prank(executor);
        uint256 burned = settlement.settle(_targets(), pairs);

        assertEq(burned, supplyBefore, "should burn entire illicit supply");
        assertEq(dev.totalSupply(), 0, "supply zeroed");
        assertEq(dev.balanceOf(attacker1), 0, "attacker1 drained");
        assertEq(dev.balanceOf(address(pair)), 0, "pair DEV drained");
        assertEq(uint256(pair.reserve()), 0, "pair reserve resynced to 0");
        assertTrue(!mg.isGroup(address(settlement)), "self-deregistered");

        // Owner tx #2 — restore original factory wiring.
        vm.prank(owner);
        config.setMarketFactory(originalFactory);
        assertEq(config.marketFactory(), originalFactory, "restored");
    }

    /// Without the owner's setMarketFactory step, settle() cannot self-register → reverts.
    function test_WithoutRegistration_Reverts() public {
        address[] memory pairs = new address[](0);
        vm.prank(executor);
        vm.expectRevert(bytes("not the market factory"));
        settlement.settle(_targets(), pairs);
    }

    /// Only the configured executor may trigger the deployed path.
    function test_OnlyExecutor() public {
        vm.prank(owner);
        config.setMarketFactory(address(settlement));
        address[] memory pairs = new address[](0);
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("not executor"));
        settlement.settle(_targets(), pairs);
    }

    /// Path (B): emulate EIP-7702 by making config.owner() == the settlement contract, so
    /// inside settleAsOwner `address(this)==config.owner()`. ONE call does registration +
    /// burn + sync + restore — the fully-atomic remediation.
    function test_OwnerDelegate_SingleTxEverything() public {
        // Fresh stack.
        vm.prank(owner);
        MockAddressConfig cfg2 = new MockAddressConfig(owner);
        MockDev dev2 = new MockDev(IAddressConfig(address(cfg2)));
        MockMarketGroup mg2 = new MockMarketGroup(IAddressConfig(address(cfg2)));

        vm.startPrank(owner);
        cfg2.setToken(address(dev2));
        cfg2.setMarketGroup(address(mg2));
        cfg2.setMarketFactory(originalFactory);
        vm.stopPrank();

        Settlement s = new Settlement(IAddressConfig(address(cfg2)), executor);

        // Illicit balances on the fresh Dev.
        dev2.mint(attacker1, 12_650_000_000 ether);
        dev2.mint(wdev, 100_000_000 ether);
        uint256 supplyBefore = dev2.totalSupply();

        // 7702 emulation: the owner account's code == settlement, so owner()==address(s).
        cfg2.setOwner(address(s));

        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](2);
        t[0] = Settlement.BurnTarget(attacker1, type(uint256).max);
        t[1] = Settlement.BurnTarget(wdev, type(uint256).max);

        // Single call — no prior owner tx, no follow-up restore tx. Self-sponsored: under a
        // real 7702 delegation the owner EOA calls itself, so msg.sender == address(s).
        vm.prank(address(s));
        uint256 burned = s.settleAsOwner(originalFactory, t, new address[](0));

        assertEq(burned, supplyBefore, "burned all in one call");
        assertEq(dev2.totalSupply(), 0, "supply zeroed");
        assertEq(cfg2.marketFactory(), originalFactory, "factory restored in same tx");
        assertTrue(!mg2.isGroup(address(s)), "membership revoked in same tx");
    }

    /// Guard: settleAsOwner rejects a caller that is not the configured owner.
    function test_OwnerDelegate_RejectsNonOwner() public {
        vm.prank(executor);
        vm.expectRevert(bytes("must run as owner (7702)"));
        settlement.settleAsOwner(originalFactory, _targets(), new address[](0));
    }

    /// fee() returns false → entire settle reverts
    function test_FeeReturnsFalse_RevertsAll() public {
        // Set up so fee() returns false (e.g., amount exceeds balance after FULL_BALANCE resolution)
        // This tests the "fee failed" require path
        vm.prank(owner);
        config.setMarketFactory(address(settlement));

        // Target with 0 balance + explicit non-zero amount → fee should fail
        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](1);
        t[0] = Settlement.BurnTarget(address(0xDEAD), 1 ether); // 0 balance but explicit amount
        address[] memory pairs = new address[](0);

        vm.prank(executor);
        vm.expectRevert(bytes("fee failed"));
        settlement.settle(t, pairs);
    }

    /// Empty targets array → succeeds with 0 burned
    function test_EmptyTargets_Succeeds() public {
        vm.prank(owner);
        config.setMarketFactory(address(settlement));

        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](0);
        address[] memory pairs = new address[](0);

        vm.prank(executor);
        uint256 burned = settlement.settle(t, pairs);
        assertEq(burned, 0, "nothing burned");
    }

    /// Duplicate targets: second one skips (balance already 0)
    function test_DuplicateTarget_SecondSkips() public {
        vm.prank(owner);
        config.setMarketFactory(address(settlement));

        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](2);
        t[0] = Settlement.BurnTarget(attacker1, type(uint256).max);
        t[1] = Settlement.BurnTarget(attacker1, type(uint256).max); // duplicate
        address[] memory pairs = new address[](0);

        vm.prank(executor);
        uint256 burned = settlement.settle(t, pairs);
        assertEq(burned, 7_000_000_000 ether, "burned once, second skipped");
    }

    /// settleAsOwner rejects zero originalFactory
    function test_SettleAsOwner_RejectsZeroFactory() public {
        // The originalFactory validation is the first check, so it fires regardless of caller/owner context.
        vm.expectRevert(bytes("invalid originalFactory"));
        settlement.settleAsOwner(address(0), _targets(), new address[](0));
    }

    /// KEEP_OFFSET + remainder burns down to that remainder, including extra tokens
    /// received after the amount was encoded (pair-swap / FeeCollector drift).
    function test_KeepOffset_BurnsDownToRemainderAcrossDrift() public {
        address holder = address(0xB0B);
        uint256 keep = 40 ether;
        dev.mint(holder, 100 ether);

        vm.prank(owner);
        config.setMarketFactory(address(settlement));

        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](1);
        t[0] = Settlement.BurnTarget(holder, settlement.KEEP_OFFSET() + keep);

        vm.prank(executor);
        uint256 burned = settlement.settle(t, new address[](0));
        assertEq(burned, 60 ether, "first burn = 100-40");
        assertEq(dev.balanceOf(holder), keep, "left the keep remainder");

        // Simulate a swap-in (or FeeCollector deposit) after calldata was signed.
        dev.mint(holder, 15 ether);
        assertEq(dev.balanceOf(holder), 55 ether, "drifted up");

        vm.prank(executor);
        burned = settlement.settle(t, new address[](0));
        assertEq(burned, 15 ether, "second burn consumes only the drift");
        assertEq(dev.balanceOf(holder), keep, "still the same remainder");
    }

    /// KEEP_OFFSET reverts rather than over-burning if live balance is below the remainder.
    function test_KeepOffset_RevertsIfBelowKeep() public {
        address holder = address(0xB0B);
        dev.mint(holder, 10 ether);

        vm.prank(owner);
        config.setMarketFactory(address(settlement));

        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](1);
        t[0] = Settlement.BurnTarget(holder, settlement.KEEP_OFFSET() + 25 ether);

        vm.prank(executor);
        vm.expectRevert(bytes("below keep target"));
        settlement.settle(t, new address[](0));
        assertEq(dev.balanceOf(holder), 10 ether, "untouched on revert");
    }
}
