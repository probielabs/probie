// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProbiePermit} from "../src/ProbiePermit.sol";
import {ProbieFactory} from "../src/ProbieFactory.sol";
import {IAllowanceModule} from "../src/interfaces/IAllowanceModule.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function move(address from, address to, uint256 a) external {
        balanceOf[from] -= a;
        balanceOf[to] += a;
    }
}

/// @dev Mirrors AllowanceModule 0.1.1's allowance arithmetic (reset on load, aligned periods, uint16 nonce) and its
///      empty-signature rule; moves a mock token instead of calling the Safe.
contract MockModule is IAllowanceModule {
    struct A {
        uint96 amount;
        uint96 spent;
        uint16 resetTimeMin;
        uint32 lastResetMin;
        uint16 nonce;
    }

    mapping(address => mapping(address => mapping(address => A))) internal al;
    mapping(address => mapping(address => bool)) public isDelegate;

    function addDelegate(address safe, address d) external {
        isDelegate[safe][d] = true;
    }

    function setAllowance(address safe, address d, address token, uint96 amount, uint16 resetTimeMin, uint32 baseMin)
        external
    {
        A memory a = _get(safe, d, token);
        a.amount = amount;
        uint32 cur = uint32(block.timestamp / 60);
        if (resetTimeMin > 0) {
            require(baseMin <= cur);
            a.lastResetMin = cur - ((cur - baseMin) % resetTimeMin);
        } else if (a.resetTimeMin > 0) {
            a.lastResetMin = 0;
        }
        a.resetTimeMin = resetTimeMin;
        al[safe][d][token] = a;
    }

    function _get(address safe, address d, address token) internal view returns (A memory a) {
        a = al[safe][d][token];
        uint32 cur = uint32(block.timestamp / 60);
        if (a.resetTimeMin > 0 && a.lastResetMin <= cur - a.resetTimeMin) {
            a.spent = 0;
            a.lastResetMin = cur - ((cur - a.lastResetMin) % a.resetTimeMin);
        }
    }

    function getTokenAllowance(address safe, address d, address token) external view returns (uint256[5] memory r) {
        A memory a = _get(safe, d, token);
        r = [uint256(a.amount), a.spent, a.resetTimeMin, a.lastResetMin, a.nonce];
    }

    function executeAllowanceTransfer(
        address safe,
        address token,
        address payable to,
        uint96 amount,
        address,
        uint96,
        address delegate,
        bytes memory signature
    ) external {
        A memory a = _get(safe, delegate, token);
        require(a.nonce != type(uint16).max, "nonce");
        a.nonce++;
        uint96 ns = a.spent + amount;
        require(ns > a.spent && ns <= a.amount, "allowance");
        a.spent = ns;
        al[safe][delegate][token] = a;
        require(signature.length == 0 && msg.sender == delegate && isDelegate[safe][delegate], "delegate");
        MockToken(token).move(safe, to, amount);
    }
}

contract ProbiePermitTest is Test {
    MockModule module;
    MockToken usdg;
    ProbieFactory factory;
    ProbiePermit permit;

    address safe = makeAddr("safe");
    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address stranger = makeAddr("stranger");

    uint96 constant USD = 1e6;
    uint32 midnightMin;
    uint256 opened;

    function setUp() public {
        vm.warp(1_763_424_000); // 2025-11-18 00:00 UTC
        module = new MockModule();
        usdg = new MockToken();
        factory = new ProbieFactory(address(module), address(usdg));
        usdg.mint(safe, 1_000_000 * USD);
        midnightMin = uint32(block.timestamp / 1 days * 1 days / 60);
        permit = _open(0, 1_000 * USD);
    }

    function _open(uint8 startLevel, uint96 ceiling) internal returns (ProbiePermit p) {
        address[] memory payees = new address[](1);
        payees[0] = shop;
        bytes32 salt = bytes32(++opened);
        address predicted = factory.predict(safe, salt);
        vm.prank(safe);
        p = ProbiePermit(factory.create(agent, startLevel, payees, salt));
        assertEq(address(p), predicted);
        module.addDelegate(safe, address(p));
        module.setAllowance(safe, address(p), address(usdg), ceiling, 1440, midnightMin);
    }

    function _pay(ProbiePermit p, address to, uint256 amount) internal returns (bool) {
        vm.prank(agent);
        return p.pay(to, amount);
    }

    function test_L0_paysApprovedPayeeInsideTheLimit() public {
        assertTrue(_pay(permit, shop, 3 * USD));
        assertTrue(_pay(permit, shop, 2 * USD));
        assertEq(usdg.balanceOf(shop), 5 * USD);
        assertEq(permit.strikes(), 0);
    }

    function test_overTheLimitIsAStrikeAndNothingMoves() public {
        assertTrue(_pay(permit, shop, 4 * USD));
        assertFalse(_pay(permit, shop, 2 * USD));
        assertEq(usdg.balanceOf(shop), 4 * USD);
        assertEq(permit.strikes(), 1);
        assertEq(permit.pausedUntil(), block.timestamp + 7 days);
        assertEq(permit.cleanSince(), block.timestamp);
    }

    function test_L0_newPayeeIsAStrike() public {
        assertEq(permit.check(stranger, 1), permit.PAYEE_NOT_ALLOWED());
        assertFalse(_pay(permit, stranger, 1 * USD));
        assertEq(usdg.balanceOf(stranger), 0);
        assertEq(permit.strikes(), 1);
    }

    function test_payeeStrikesNeverDropTheLevel() public {
        ProbiePermit p = _open(2, 1_000 * USD);
        for (uint256 i; i < 5; ++i) {
            assertFalse(_pay(p, stranger, 11 * USD)); // over the $10 new-payee cap, then paused
            vm.warp(block.timestamp + 1 hours);
        }
        assertEq(p.level(), 2);
        assertEq(p.strikes(), 5);
        assertEq(p.check(stranger, 1 * USD), p.NEW_PAYEES_PAUSED());
        assertTrue(_pay(p, shop, 50 * USD)); // approved payees still work inside the limit
    }

    function test_secondOverLimitWithin7DaysDropsALevel() public {
        ProbiePermit p = _open(2, 1_000 * USD);
        assertFalse(_pay(p, shop, 101 * USD));
        assertEq(p.level(), 2);
        vm.warp(block.timestamp + 6 days);
        assertFalse(_pay(p, shop, 101 * USD));
        assertEq(p.level(), 1);
        vm.warp(block.timestamp + 7 days + 1); // 7 clean days at L1: back to L2
        assertEq(p.status().level, 2);
        assertFalse(_pay(p, shop, 101 * USD)); // more than 7 days since the last one: no drop
        assertEq(p.level(), 2);
    }

    function test_cleanDaysRaiseTheLevelAndCatchUp() public {
        vm.warp(block.timestamp + 3 days);
        permit.sync();
        assertEq(permit.level(), 1);
        vm.warp(block.timestamp + 51 days); // 54 days in all: 3 + 7 + 14 + 30
        assertEq(permit.status().level, 4);
        permit.sync();
        assertEq(permit.level(), 4);
    }

    function test_aStrikeRestartsTheCount() public {
        vm.warp(block.timestamp + 2 days);
        assertFalse(_pay(permit, stranger, 1 * USD));
        vm.warp(block.timestamp + 2 days);
        permit.sync();
        assertEq(permit.level(), 0);
        vm.warp(block.timestamp + 1 days);
        permit.sync();
        assertEq(permit.level(), 1);
    }

    function test_theCeilingCapsTheTopLevel() public {
        ProbiePermit p = _open(2, 150 * USD);
        vm.warp(block.timestamp + 14 days + 30 days);
        assertEq(p.status().level, 4);
        assertTrue(_pay(p, shop, 150 * USD));
        assertEq(p.check(shop, 1), p.OVER_CEILING());
        assertFalse(_pay(p, shop, 1));
        vm.warp(block.timestamp + 1 days); // the ceiling and the counters reset at UTC midnight
        assertTrue(_pay(p, shop, 150 * USD));
    }

    function test_dailyCountersResetAtUtcMidnight() public {
        assertTrue(_pay(permit, shop, 5 * USD));
        vm.warp(block.timestamp + 1 days);
        assertTrue(_pay(permit, shop, 5 * USD));
        assertEq(usdg.balanceOf(shop), 10 * USD);
    }

    function test_frozenMovesNothingAndRecordsNothing() public {
        vm.prank(safe);
        permit.setFrozen(true);
        assertEq(permit.check(shop, 1), permit.FROZEN());
        vm.prank(agent);
        vm.expectRevert(ProbiePermit.IsFrozen.selector);
        permit.pay(shop, 1);
        assertEq(permit.strikes(), 0);
    }

    function test_onlyTheAgentPaysAndOnlyTheSafeSteers() public {
        vm.expectRevert(ProbiePermit.NotAgent.selector);
        permit.pay(shop, 1);
        vm.expectRevert(ProbiePermit.NotSafe.selector);
        permit.setPayee(stranger, true);
        vm.expectRevert(ProbiePermit.NotSafe.selector);
        permit.setFrozen(true);
        vm.expectRevert(ProbiePermit.NotSafe.selector);
        permit.setAgent(stranger);
    }

    function test_noCeilingRevertsInsteadOfStriking() public {
        module.setAllowance(safe, address(permit), address(usdg), 0, 0, 0);
        vm.prank(agent);
        vm.expectRevert(ProbiePermit.NoCeiling.selector);
        permit.pay(shop, 1);
    }

    function test_nobodyOpensAPermitOnSomeoneElsesSafe() public {
        address[] memory none;
        vm.prank(stranger);
        ProbiePermit p = ProbiePermit(factory.create(agent, 0, none, bytes32(0)));
        assertEq(p.safe(), stranger); // the caller is always the Safe
        vm.expectRevert(ProbiePermit.NotFactory.selector);
        p.initialize(safe, agent, 0, none);
    }

    function test_startLevelAboveL2IsRefused() public {
        address[] memory none;
        vm.prank(safe);
        vm.expectRevert(ProbiePermit.BadLevel.selector);
        factory.create(agent, 3, none, bytes32("x"));
    }

    function test_theImplementationCannotBeInitialized() public {
        address[] memory none;
        ProbiePermit impl = ProbiePermit(factory.implementation());
        vm.prank(address(factory));
        vm.expectRevert(ProbiePermit.NotFactory.selector);
        impl.initialize(safe, agent, 0, none);
    }

    /// The agent never moves more than its level's limit in one UTC day, whatever it tries.
    function testFuzz_neverMoreThanTheDailyLimit(uint256[12] memory amounts, uint8 startLevel) public {
        ProbiePermit p = _open(uint8(bound(startLevel, 0, 2)), 1_000 * USD);
        uint256 before = usdg.balanceOf(safe);
        uint256 limit = p.limitOf(p.level());
        for (uint256 i; i < amounts.length; ++i) {
            _pay(p, i % 3 == 0 ? stranger : shop, bound(amounts[i], 1, 200 * USD));
        }
        assertLe(before - usdg.balanceOf(safe), limit);
    }
}
