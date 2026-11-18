// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Stack} from "./Stack.sol";
import {ProbiePermit} from "../src/ProbiePermit.sol";

/// @dev The permit's rules through the real AllowanceModule 0.1.1 and a real Safe 1.4.1; every owner action is a
///      signed Safe transaction.
contract IntegrationTest is Stack {
    ProbiePermit permit; // L0, ceiling $1,000
    uint256 t0;

    function setUp() public {
        _deployStack();
        t0 = block.timestamp;
        permit = _open(0, 1_000 * USD, "l0");
    }

    function _pay(ProbiePermit p, address to, uint256 amount) internal returns (bool) {
        vm.prank(agent);
        return p.pay(to, amount);
    }

    function _paid(ProbiePermit p, address to, uint256 amount) internal {
        uint256 before = usdg.balanceOf(to);
        assertTrue(_pay(p, to, amount), "payment blocked");
        assertEq(usdg.balanceOf(to), before + amount);
    }

    /// @dev A blocked payment: the reason check() gives, a false return, nothing moved, one more strike.
    function _strike(ProbiePermit p, address to, uint256 amount, uint8 reason) internal {
        assertEq(p.check(to, amount), reason, "reason");
        uint256 bal = usdg.balanceOf(address(safe));
        uint256 spent = _allowance(address(p))[1];
        uint32 n = p.strikes();
        uint8 lvl = p.status().level;
        uint64 last = p.lastOverLimit();
        if (reason <= p.OVER_CEILING() && last != 0 && block.timestamp < last + 7 days && lvl > 0) lvl--;
        vm.expectEmit(address(p));
        emit ProbiePermit.Strike(to, amount, reason, lvl, n + 1);
        assertFalse(_pay(p, to, amount));
        assertEq(usdg.balanceOf(address(safe)), bal, "moved");
        assertEq(_allowance(address(p))[1], spent, "ceiling used");
        assertEq(p.strikes(), n + 1);
        assertEq(p.pausedUntil(), block.timestamp + 7 days);
        assertEq(p.cleanSince(), block.timestamp);
    }

    function test_setupBatchWiresEverything() public view {
        assertTrue(safe.isModuleEnabled(address(module)));
        assertEq(safe.nonce(), 1); // one Safe transaction
        uint256[5] memory a = _allowance(address(permit));
        assertEq(a[0], 1_000 * USD);
        assertEq(a[1], 0);
        assertEq(a[2], 1440);
        assertEq(a[3], t0 / 60); // t0 is a UTC midnight
        assertEq(a[4], 1);
        assertEq(permit.safe(), address(safe));
        assertEq(permit.agent(), agent);
        assertEq(permit.level(), 0);
        assertTrue(permit.approved(shop) && permit.approved(shop2));
        assertFalse(permit.approved(stranger));
    }

    function test_secondPermitOnTheSameSafe() public {
        ProbiePermit p2 = _open(2, 50 * USD, "l2");
        assertTrue(address(p2) != address(permit));
        _paid(p2, shop, 50 * USD);
        _paid(permit, shop, 5 * USD);
    }

    function test_paysInsideTheLevel() public {
        _paid(permit, shop, 3 * USD);
        _paid(permit, shop2, 2 * USD);
        uint256[5] memory a = _allowance(address(permit));
        assertEq(a[1], 5 * USD);
        assertEq(a[4], 3);
        assertEq(permit.strikes(), 0);
        assertEq(permit.spentToday(), 5 * USD);
    }

    function test_strikesForEveryReason() public {
        _strike(permit, stranger, 1 * USD, permit.PAYEE_NOT_ALLOWED());
        _strike(permit, shop, 6 * USD, permit.OVER_LIMIT());

        ProbiePermit p = _open(2, 60 * USD, "l2");
        _strike(p, stranger, 11 * USD, p.OVER_NEW_PAYEE_CAP());
        _strike(p, stranger, 1 * USD, p.NEW_PAYEES_PAUSED());
        _paid(p, shop, 50 * USD);
        _strike(p, shop, 20 * USD, p.OVER_CEILING()); // 70 fits the $100 limit, not the $60 ceiling
        _strike(p, shop, 51 * USD, p.OVER_LIMIT()); // second over-limit-or-ceiling in 7 days: L2 -> L1
        assertEq(p.level(), 1);
    }

    function test_newPayeeCapAtL2() public {
        ProbiePermit p = _open(2, 1_000 * USD, "l2");
        _paid(p, stranger, 6 * USD);
        _paid(p, stranger2, 4 * USD);
        assertEq(p.newSpentToday(), 10 * USD);
        _strike(p, stranger, 1 * USD, p.OVER_NEW_PAYEE_CAP());
        _paid(p, shop, 90 * USD); // approved payees still pay; the cap sits inside the $100 limit
        assertEq(p.spentToday(), 100 * USD);
    }

    function test_levelUpsAndCatchUp() public {
        vm.warp(t0 + 3 days - 1);
        assertEq(permit.status().level, 0);
        vm.warp(t0 + 3 days);
        assertEq(permit.status().level, 1);
        assertEq(permit.level(), 0); // lazy until a call
        vm.expectEmit(address(permit));
        emit ProbiePermit.LevelChanged(0, 1);
        permit.sync();
        assertEq(permit.cleanSince(), t0 + 3 days);

        // a strike at L1 restarts the count
        vm.warp(t0 + 5 days);
        _strike(permit, stranger, 1 * USD, permit.PAYEE_NOT_ALLOWED());
        vm.warp(t0 + 12 days - 1);
        assertEq(permit.status().level, 1);
        vm.warp(t0 + 12 days);
        assertEq(permit.status().level, 2);

        // catch-up: idle days run L2 -> L4 in one call, each step from the moment the last level was reached
        uint256 l2At = t0 + 12 days;
        vm.warp(l2At + 14 days + 30 days);
        vm.expectEmit(address(permit));
        emit ProbiePermit.LevelChanged(1, 4);
        permit.sync();
        _paid(permit, shop, 900 * USD);
        assertEq(permit.level(), 4);
        assertEq(permit.cleanSince(), l2At + 44 days);
    }

    function test_catchUpFromL0ToTop() public {
        vm.warp(t0 + 54 days);
        ProbiePermit.Status memory st = permit.status();
        assertEq(st.level, 4);
        assertEq(st.daysToNextLevel, 0);
        assertEq(st.newPayeeCap, 25 * USD);
    }

    function test_overLimitDemotion() public {
        ProbiePermit p = _open(2, 1_000 * USD, "l2");
        _strike(p, shop, 101 * USD, p.OVER_LIMIT());
        assertEq(p.level(), 2); // the first one only costs the clean run
        uint256 t1 = t0 + 7 days - 1;
        vm.warp(t1);
        _strike(p, shop, 101 * USD, p.OVER_LIMIT());
        assertEq(p.level(), 1);

        // payee strikes never drop the level
        _strike(p, stranger, 1 * USD, p.PAYEE_NOT_ALLOWED());
        assertEq(p.level(), 1);

        // 7 clean days later it is back at L2, and an over-limit outside the window does not demote
        vm.warp(t1 + 7 days);
        _strike(p, shop, 101 * USD, p.OVER_LIMIT());
        assertEq(p.level(), 2);
    }

    function test_neverBelowL0() public {
        _strike(permit, shop, 6 * USD, permit.OVER_LIMIT());
        _strike(permit, shop, 6 * USD, permit.OVER_LIMIT());
        assertEq(permit.level(), 0);
    }

    function test_ceilingCapsTheTopLevel() public {
        vm.warp(t0 + 54 days);
        _paid(permit, shop, 1_000 * USD); // L4 has no level limit
        _strike(permit, shop, 1, permit.OVER_CEILING());
        vm.warp(t0 + 55 days);
        _paid(permit, shop, 1_000 * USD);
    }

    function test_utcMidnightResetsBothCounters() public {
        ProbiePermit p = _open(0, 3 * USD, "c3");
        vm.warp(t0 + 1 days - 1); // 23:59:59
        _paid(permit, shop, 5 * USD);
        _paid(p, shop, 3 * USD);
        assertEq(permit.check(shop, 1), permit.OVER_LIMIT());
        assertEq(p.check(shop, 1), p.OVER_CEILING());
        vm.warp(t0 + 1 days); // 00:00:00
        assertEq(permit.check(shop, 5 * USD), 0);
        assertEq(p.check(shop, 3 * USD), 0);
        _paid(permit, shop, 5 * USD);
        _paid(p, shop, 3 * USD);
        assertEq(_allowance(address(p))[1], 3 * USD);
        assertEq(permit.spentToday(), 5 * USD);
    }

    function test_freeze() public {
        vm.prank(owner); // the owner's key is not the owner: the Safe is
        vm.expectRevert(ProbiePermit.NotSafe.selector);
        permit.setFrozen(true);

        _owner(address(permit), abi.encodeCall(ProbiePermit.setFrozen, (true)));
        assertTrue(permit.frozen());
        assertEq(permit.check(shop, 1), permit.FROZEN());
        vm.prank(agent);
        vm.expectRevert(ProbiePermit.IsFrozen.selector);
        permit.pay(shop, 1);
        assertEq(permit.strikes(), 0);

        _owner(address(permit), abi.encodeCall(ProbiePermit.setFrozen, (false)));
        _paid(permit, shop, 1 * USD);
    }

    function test_ownerSetsPayeesAndAgent() public {
        _owner(address(permit), abi.encodeCall(ProbiePermit.setPayee, (stranger, true)));
        _paid(permit, stranger, 1 * USD);
        _owner(address(permit), abi.encodeCall(ProbiePermit.setPayee, (shop, false)));
        assertEq(permit.check(shop, 1), permit.PAYEE_NOT_ALLOWED());

        address agent2 = makeAddr("agent2");
        _owner(address(permit), abi.encodeCall(ProbiePermit.setAgent, (agent2)));
        vm.prank(agent);
        vm.expectRevert(ProbiePermit.NotAgent.selector);
        permit.pay(shop2, 1);
        vm.prank(agent2);
        assertTrue(permit.pay(shop2, 1 * USD));
    }

    function test_ownerChangesCeilingMidDay() public {
        ProbiePermit p = _open(2, 100 * USD, "l2");
        vm.warp(t0 + 12 hours);
        _paid(p, shop, 30 * USD);

        _setCeiling(address(p), 200 * USD); // raising keeps what was spent today
        assertEq(_allowance(address(p))[1], 30 * USD);
        assertEq(p.ceilingLeft(), 170 * USD);

        _setCeiling(address(p), 40 * USD);
        assertEq(p.ceilingLeft(), 10 * USD);
        assertEq(p.check(shop, 20 * USD), p.OVER_CEILING());
        _paid(p, shop, 10 * USD);

        vm.warp(t0 + 1 days); // still resets at UTC midnight
        assertEq(p.ceilingLeft(), 40 * USD);
    }

    function test_ownerDeletesCeiling() public {
        vm.warp(t0 + 12 hours);
        _paid(permit, shop, 2 * USD);
        _owner(address(module), abi.encodeWithSignature("deleteAllowance(address,address)", permit, address(usdg)));

        // not the agent's fault: a revert, no strike
        vm.expectRevert(ProbiePermit.NoCeiling.selector);
        permit.check(shop, 1);
        vm.prank(agent);
        vm.expectRevert(ProbiePermit.NoCeiling.selector);
        permit.pay(shop, 1);
        assertEq(permit.strikes(), 0);

        _setCeiling(address(permit), 10 * USD);
        assertEq(permit.ceilingLeft(), 10 * USD);
        _paid(permit, shop, 3 * USD); // the permit's own $5 day still counts the $2
        assertEq(permit.check(shop, 1), permit.OVER_LIMIT());
    }

    function test_removedDelegateCannotPay() public {
        // keep the allowance: the permit's checks pass, the module refuses a delegate the Safe removed
        _owner(address(module), abi.encodeWithSignature("removeDelegate(address,bool)", permit, false));
        vm.prank(agent);
        vm.expectRevert(
            bytes("expectedDelegate == signer && delegates[address(safe)][uint48(signer)].delegate == signer")
        );
        permit.pay(shop, 1);
        assertEq(usdg.balanceOf(shop), 0);
    }

    /// @dev AllowanceModule 0.1.1 (solc 0.7.6) has no nonce cap: the uint16 nonce wraps, and with the empty-signature
    ///      path the nonce guards nothing, so payments go on. Release 1.0.0 stops at 65,534 transfers.
    function test_moduleNonceWrapsOn011() public {
        bytes32 slot = keccak256(
            abi.encode(
                address(usdg), keccak256(abi.encode(address(permit), keccak256(abi.encode(address(safe), uint256(0)))))
            )
        );
        uint256 word = uint256(vm.load(address(module), slot));
        word = (word & ~(uint256(0xffff) << 240)) | (uint256(0xffff) << 240);
        vm.store(address(module), slot, bytes32(word));
        assertEq(_allowance(address(permit))[4], 65_535);
        _paid(permit, shop, 1 * USD);
        assertEq(_allowance(address(permit))[4], 0);
        _paid(permit, shop, 1 * USD);
        assertEq(_allowance(address(permit))[4], 1);
    }
}
