// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniTest} from "./lib/MiniTest.sol";
import {Settlement} from "../src/Settlement.sol";
import {IAddressConfig, IDev, IMarketGroup} from "../src/interfaces/IDevProtocol.sol";

/**
 * WDEV ("Polygon Dev Wrapper", 0x4a5df63b…) burn-path proof on a mainnet fork.
 *
 * On-chain facts established by forensics (see forensics/CLUSTER.md):
 *   - WDEV is a 1:1 DEV wrapper: DEV.balanceOf(WDEV) == WDEV.totalSupply().
 *   - The attacker wrapped EXACTLY 100,000,000 illicit DEV (block 25802137) and parked
 *     the resulting WDEV at cluster proxy 0x9923263f….
 *   - WDEV existed before the attack: totalSupply − 100,000,000 = 153,849.71 WDEV is
 *     legitimate, pre-attack backing held by innocent third parties.
 *
 * We can only burn DEV via Dev.fee(from,amount). The DEV to destroy physically sits
 * INSIDE the WDEV contract, so the burn target is the WDEV address itself. We must NOT
 * use FULL_BALANCE for WDEV — that would also destroy the 153,849.71 DEV backing the
 * legit holders. Instead we burn the FIXED illicit amount (100,000,000 DEV).
 */
contract WdevBurnForkTest is MiniTest {
    address constant DEV = address(uint160(0x005caf454ba92e6f2c929df14667ee360ed9fd5b26));
    address constant CONFIG = address(uint160(0x001d415aa39d647834786eb9b5a333a50e9935b796));
    address constant WDEV = address(uint160(0x004a5df63b0c37b38515e4ee51baf40edd420bf7d5));

    uint256 constant ILLICIT_WRAPPED = 100_000_000 ether; // exact amount the attacker wrapped

    function _fork() internal returns (bool) {
        try vm.createSelectFork("mainnet") returns (uint256) { return true; }
        catch { return false; }
    }

    /// RECOMMENDED path: burn only the illicit 100,000,000 DEV, sparing legit backing.
    function test_WDEV_PartialBurn_SparesLegitBacking() public {
        if (!_fork()) { emit log("SKIP: no RPC"); return; }

        IAddressConfig config = IAddressConfig(CONFIG);
        IDev dev = IDev(DEV);
        IDev wdev = IDev(WDEV); // ERC20 view surface (balanceOf/totalSupply)
        IMarketGroup mg = IMarketGroup(config.marketGroup());
        address owner = config.owner();
        address originalFactory = config.marketFactory();

        uint256 backingBefore = dev.balanceOf(WDEV);
        uint256 wdevSupply = wdev.totalSupply();
        emit log_named_uint("WDEV DEV backing (wei)", backingBefore);
        emit log_named_uint("WDEV totalSupply (wei)", wdevSupply);
        // 1:1 fully-backed wrapper.
        assertEq(backingBefore, wdevSupply, "WDEV is 1:1 backed");
        assertGt(backingBefore, ILLICIT_WRAPPED, "backing exceeds illicit (legit remainder exists)");

        uint256 legitBacking = backingBefore - ILLICIT_WRAPPED;
        emit log_named_uint("legit pre-attack backing (wei)", legitBacking);

        Settlement s = new Settlement(config, address(this));
        vm.prank(owner);
        config.setMarketFactory(address(s));

        // Burn the FIXED illicit amount from the WDEV contract (not FULL_BALANCE).
        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](1);
        t[0] = Settlement.BurnTarget(WDEV, ILLICIT_WRAPPED);
        uint256 burned = s.settle(t, new address[](0));

        assertEq(burned, ILLICIT_WRAPPED, "burned exactly the illicit 100M");
        assertEq(dev.balanceOf(WDEV), legitBacking, "legit backing preserved");
        // Burning the *backing* does NOT change WDEV's own ERC20 supply — WDEV is now
        // fractionally backed: legitBacking DEV stands behind wdevSupply WDEV.
        assertEq(wdev.totalSupply(), wdevSupply, "WDEV supply unchanged by backing burn");
        assertTrue(!mg.isGroup(address(s)), "membership revoked");

        vm.prank(owner);
        config.setMarketFactory(originalFactory);
    }

    /// VARIANT: burn the ENTIRE backing (FULL_BALANCE). Destroys legit backing too —
    /// only acceptable if the ~153,849 DEV to innocent WDEV holders is separately
    /// reimbursed, or if policy accepts the collateral loss.
    function test_WDEV_FullBurn_DestroysAllBacking() public {
        if (!_fork()) { emit log("SKIP: no RPC"); return; }

        IAddressConfig config = IAddressConfig(CONFIG);
        IDev dev = IDev(DEV);
        address owner = config.owner();
        address originalFactory = config.marketFactory();

        uint256 backingBefore = dev.balanceOf(WDEV);
        assertGt(backingBefore, 0, "WDEV holds DEV");

        Settlement s = new Settlement(config, address(this));
        vm.prank(owner);
        config.setMarketFactory(address(s));

        Settlement.BurnTarget[] memory t = new Settlement.BurnTarget[](1);
        t[0] = Settlement.BurnTarget(WDEV, type(uint256).max); // FULL_BALANCE
        uint256 burned = s.settle(t, new address[](0));

        assertEq(burned, backingBefore, "burned full WDEV backing");
        assertEq(dev.balanceOf(WDEV), 0, "WDEV backing fully destroyed");

        vm.prank(owner);
        config.setMarketFactory(originalFactory);
    }
}
