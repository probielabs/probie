// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Stack} from "../Stack.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProbiePermit} from "../../src/ProbiePermit.sol";
import {ProbieFactory} from "../../src/ProbieFactory.sol";
import {IAllowanceModule} from "../../src/interfaces/IAllowanceModule.sol";

/// @dev A contract that is not a Safe: it opens a permit for itself and answers every module call with success,
///      without moving any token.
contract FakeSafe {
    function execTransactionFromModule(address, uint256, bytes calldata, uint8) external pure returns (bool) {
        return true;
    }

    function open(ProbieFactory f, address agent, address payee) external returns (address p) {
        ProbiePermit impl = ProbiePermit(f.implementation());
        address m = address(impl.module());
        address[] memory payees = new address[](1);
        payees[0] = payee;
        p = f.create(agent, 2, payees, bytes32(0));
        (bool ok,) = m.call(abi.encodeWithSignature("addDelegate(address)", p));
        require(ok);
        (ok,) = m.call(
            abi.encodeWithSignature(
                "setAllowance(address,address,uint96,uint16,uint32)",
                p,
                impl.token(),
                type(uint96).max,
                uint16(1440),
                uint32(block.timestamp / 1 days * 1440)
            )
        );
        require(ok);
    }
}

/// @dev Regression tests for the 18 Nov review (F1-F3). Each one failed on the reviewed code.
contract ReviewPoC is Stack {
    uint256 t0;

    function setUp() public {
        _deployStack();
        t0 = block.timestamp; // a UTC midnight
    }

    function _pay(ProbiePermit p, address to, uint256 amount) internal returns (bool) {
        vm.prank(agent);
        return p.pay(to, amount);
    }

    function _ceiling(ProbiePermit p, uint96 amount, uint16 resetMin, uint32 baseMin) internal {
        _owner(
            address(module),
            abi.encodeWithSignature(
                "setAllowance(address,address,uint96,uint16,uint32)",
                address(p),
                address(usdg),
                amount,
                resetMin,
                baseMin
            )
        );
    }

    /// @dev pay() and check() both revert with BadCeiling: nothing moves and nothing is recorded.
    function _refused(ProbiePermit p) internal {
        uint256 bal = usdg.balanceOf(shop);
        uint32 n = p.strikes();
        vm.expectRevert(ProbiePermit.BadCeiling.selector);
        p.check(shop, 1 * USD);
        vm.expectRevert(ProbiePermit.BadCeiling.selector);
        _pay(p, shop, 1 * USD);
        assertEq(usdg.balanceOf(shop), bal);
        assertEq(p.strikes(), n);
    }

    /// F1: a ceiling that does not reset once per UTC day at a UTC midnight would let an L4 agent move more than the
    ///     ceiling in one UTC day. The permit refuses to pay against it until the owner sets a UTC-day ceiling.
    function test_F1_misalignedCeilingIsRefused() public {
        ProbiePermit p = _open(2, 100 * USD, "f1");
        vm.warp(t0 + 44 days + 12 hours); // L4 by the clock; it is noon UTC
        assertEq(p.status().level, 4);
        uint32 nowMin = uint32(block.timestamp / 60);
        uint32 midnightMin = uint32((t0 + 44 days) / 60);

        _ceiling(p, 100 * USD, 1440, nowMin); // resets at noon
        _refused(p);
        vm.warp(t0 + 45 days + 12 hours - 1); // the next UTC day, still before the noon reset
        _refused(p);
        _ceiling(p, 100 * USD, 60, midnightMin); // hourly: 24x a day
        _refused(p);
        _ceiling(p, 100 * USD, 0, 0); // never resets
        _refused(p);

        // a UTC-day ceiling: at most the ceiling per UTC day, across the old noon boundary
        _ceiling(p, 100 * USD, 1440, uint32((t0 + 45 days) / 60));
        uint256 before = usdg.balanceOf(shop);
        assertTrue(_pay(p, shop, 100 * USD));
        vm.warp(t0 + 45 days + 12 hours);
        assertEq(p.check(shop, 1 * USD), p.OVER_CEILING());
        assertEq(usdg.balanceOf(shop) - before, 100 * USD);
        vm.warp(t0 + 46 days);
        assertTrue(_pay(p, shop, 100 * USD)); // the next UTC midnight resets it
    }

    /// F2: frozen days are not clean days. Progress made before the freeze is kept; the clock pauses while frozen.
    function test_F2_freezePausesTheCleanDayClock() public {
        ProbiePermit p = _open(0, 1_000 * USD, "f2");
        vm.warp(t0 + 1 days);
        _owner(address(p), abi.encodeCall(ProbiePermit.setFrozen, (true)));
        vm.warp(t0 + 20 days);
        assertEq(p.status().level, 0);
        assertEq(p.status().cleanDays, 1); // status() does not underflow while frozen
        p.sync(); // a third-party sync while frozen banks nothing extra
        vm.warp(t0 + 40 days);
        _owner(address(p), abi.encodeCall(ProbiePermit.setFrozen, (false)));
        assertEq(p.level(), 0, "the freeze promoted the agent");
        assertEq(p.cleanSince(), t0 + 39 days); // one clean day banked before the freeze
        assertFalse(_pay(p, stranger, 25 * USD)); // still L0: a new payee is a strike

        // a fresh run after the strike: L1 after 3 clean days, and a level earned before a freeze is kept
        vm.warp(t0 + 43 days);
        _owner(address(p), abi.encodeCall(ProbiePermit.setFrozen, (true)));
        assertEq(p.level(), 1);
        vm.warp(t0 + 100 days);
        _owner(address(p), abi.encodeCall(ProbiePermit.setFrozen, (false)));
        assertEq(p.level(), 1);
        assertEq(p.status().cleanDays, 0);
        vm.warp(t0 + 107 days);
        assertEq(p.status().level, 2); // 7 clean days after the thaw
    }

    /// F3 (not fixed on chain, by design): the factory takes any caller as "the Safe", so a contract that only fakes
    ///     the Safe interface gets a permit whose Paid events move no USDG. The board must keep a permit only when its
    ///     Safe is a SafeProxy whose masterCopy() is the Safe 1.4.1 singleton, and count volume from USDG Transfer logs.
    ///     This test pins both facts the indexer relies on.
    function test_F3_fakeSafeIsTellableFromARealSafe() public {
        FakeSafe fake = new FakeSafe();
        ProbiePermit p = ProbiePermit(fake.open(factory, agent, shop));
        vm.recordLogs();
        assertTrue(_pay(p, shop, 100 * USD));
        assertEq(usdg.balanceOf(shop), 0, "a fake Safe moves no USDG");
        assertEq(_usdgTransfers(), 0, "so no USDG Transfer log backs its Paid");

        // masterCopy() (0xa619486e) is answered by the SafeProxy itself
        (bool ok, bytes memory ret) = address(safe).staticcall(abi.encodeWithSelector(0xa619486e));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), singleton);
        (ok,) = address(fake).staticcall(abi.encodeWithSelector(0xa619486e));
        assertFalse(ok, "a fake Safe has no masterCopy");

        ProbiePermit real = _open(2, 100 * USD, "f3");
        vm.recordLogs();
        assertTrue(_pay(real, shop, 100 * USD));
        assertEq(_usdgTransfers(), 1);
    }

    function _usdgTransfers() internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(usdg) && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)"))
            {
                n++;
            }
        }
    }
}
