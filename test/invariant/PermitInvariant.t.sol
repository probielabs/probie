// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Safe} from "safe/Safe.sol";
import {Stack, USDG} from "../Stack.sol";
import {ProbiePermit} from "../../src/ProbiePermit.sol";
import {ProbieSetup} from "../../script/ProbieSetup.sol";

/// @dev Drives one permit over the real stack: the agent pays approved payees (A, B) or new ones (C, D), time moves,
///      and the owner (as signed Safe transactions) changes payees, freezes and sets new ceilings. Ghost state is kept
///      per UTC day.
contract Handler is Test {
    uint256 constant USD = 1e6;

    ProbiePermit immutable permit;
    Safe immutable safe;
    USDG immutable usdg;
    address immutable module;
    address immutable agent;
    uint256 immutable ownerKey;
    address[4] payees;

    // ghost state, per UTC day
    uint256[] public dayList;
    mapping(uint256 => bool) seen;
    mapping(uint256 => uint256) public outflow;
    mapping(uint256 => uint256) public newOutflow;
    mapping(uint256 => uint8) public maxLevel;
    mapping(uint256 => uint256) public maxCeiling;
    // ghost state, whole run
    uint256 public ceiling;
    uint256 public falseReturns;
    uint256 public movedOnFalse;
    uint256 public paidWhileFrozen;
    uint256 public wrongAmount;
    uint256 public unexpectedReverts;
    uint256 public paidCount;
    uint8 public topLevelSeen;

    constructor(
        ProbiePermit permit_,
        Safe safe_,
        USDG usdg_,
        address module_,
        address agent_,
        uint256 ownerKey_,
        address[4] memory payees_,
        uint256 ceiling_
    ) {
        permit = permit_;
        safe = safe_;
        usdg = usdg_;
        module = module_;
        agent = agent_;
        ownerKey = ownerKey_;
        payees = payees_;
        ceiling = ceiling_;
    }

    function daysCount() external view returns (uint256) {
        return dayList.length;
    }

    function _observe() internal {
        uint256 d = block.timestamp / 1 days;
        if (!seen[d]) {
            seen[d] = true;
            dayList.push(d);
        }
        uint8 l = permit.status().level;
        if (l > maxLevel[d]) maxLevel[d] = l;
        if (l > topLevelSeen) topLevelSeen = l;
        if (ceiling > maxCeiling[d]) maxCeiling[d] = ceiling;
    }

    // ---------- actions ----------

    /// @param who bits 0-1 pick the payee (0-1 approved at start, 2-3 new); bits 2-3 scale the amount down by
    ///        1, 10, 100 or 1000x, so payments that fit each level show up as often as ones that do not.
    function pay(uint256 who, uint256 amount) external {
        address to = payees[who % 4];
        amount = bound(amount, 0, 600 * USD) / 10 ** ((who >> 2) % 4);
        _observe();
        uint256 d = block.timestamp / 1 days;
        bool isNew = !permit.approved(to);
        bool wasFrozen = permit.frozen();
        uint256 bal = usdg.balanceOf(address(safe));

        vm.prank(agent);
        try permit.pay(to, amount) returns (bool ok) {
            uint256 moved = bal - usdg.balanceOf(address(safe));
            if (wasFrozen) paidWhileFrozen++;
            if (ok) {
                paidCount++;
                if (moved != amount) wrongAmount++;
                outflow[d] += moved;
                if (isNew) newOutflow[d] += moved;
            } else {
                falseReturns++;
                movedOnFalse += moved;
            }
        } catch {
            // the only expected reverts: frozen, or a zero amount
            if (!wasFrozen && amount != 0) unexpectedReverts++;
        }
        _observe();
    }

    function warp(uint256 secs) external {
        // hashed, so steps spread evenly over 0-3 days instead of clustering on the fuzzer's favourite small values
        vm.warp(block.timestamp + uint256(keccak256(abi.encode(secs))) % (3 days + 1));
        _observe();
    }

    function setPayee(uint256 who, bool ok) external {
        _owner(address(permit), abi.encodeCall(ProbiePermit.setPayee, (payees[who % 4], ok)));
    }

    /// @dev Freezes on one call in four, so most of a run is spent unfrozen.
    function setFrozen(uint256 x) external {
        _owner(address(permit), abi.encodeCall(ProbiePermit.setFrozen, (x % 4 == 0)));
    }

    function setCeiling(uint256 amount) external {
        _observe();
        ceiling = bound(amount, 1 * USD, 2_000 * USD);
        _owner(module, ProbieSetup.setAllowance(address(permit), address(usdg), uint96(ceiling)));
        _observe();
    }

    function _owner(address to, bytes memory data) internal {
        require(ProbieSetup.call(safe, ownerKey, to, data), "safe tx failed");
    }
}

/// @dev Run from L0 (new payees blocked, a slow climb) and from L2 (new payees open, room to reach L4).
abstract contract PermitInvariant is Stack {
    ProbiePermit permit;
    Handler handler;

    function _startLevel() internal pure virtual returns (uint8);

    function setUp() public {
        _deployStack();
        permit = _open(_startLevel(), 1_000 * USD, "inv");
        handler = new Handler(
            permit, safe, usdg, address(module), agent, ownerKey, [shop, shop2, stranger, stranger2], 1_000 * USD
        );
        // the handler signs as the owner, so it needs no special rights: the Safe checks the signature
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = Handler.pay.selector;
        sel[1] = Handler.warp.selector;
        sel[2] = Handler.setPayee.selector;
        sel[3] = Handler.setFrozen.selector;
        sel[4] = Handler.setCeiling.selector;
        targetSelector(FuzzSelector(address(handler), sel));
        targetContract(address(handler));
    }

    function invariant_dailyOutflowWithinLevelAndCeiling() public view {
        for (uint256 i; i < handler.daysCount(); ++i) {
            uint256 d = handler.dayList(i);
            assertLe(handler.outflow(d), permit.limitOf(handler.maxLevel(d)), "over the level limit");
            assertLe(handler.outflow(d), handler.maxCeiling(d), "over the ceiling");
        }
    }

    function invariant_newPayeeOutflowWithinCap() public view {
        for (uint256 i; i < handler.daysCount(); ++i) {
            uint256 d = handler.dayList(i);
            uint8 l = handler.maxLevel(d);
            assertLe(handler.newOutflow(d), permit.newCapOf(l), "over the new-payee cap");
            if (l < 2) assertEq(handler.newOutflow(d), 0, "new payee paid at L0-L1");
        }
    }

    function invariant_falseReturnMovesNothing() public view {
        assertEq(handler.movedOnFalse(), 0);
    }

    function invariant_nothingMovesWhileFrozen() public view {
        assertEq(handler.paidWhileFrozen(), 0);
    }

    function invariant_strikesEqualFalseReturns() public view {
        assertEq(permit.strikes(), handler.falseReturns());
    }

    function invariant_levelAtMostTop() public view {
        assertLe(permit.level(), 4);
        assertLe(permit.status().level, 4);
    }

    /// @dev The permit's own checks agree with the module: a payment it lets through never reverts there.
    function invariant_paidExactlyAndNoSurpriseRevert() public view {
        assertEq(handler.wrongAmount(), 0);
        assertEq(handler.unexpectedReverts(), 0);
    }
}

contract PermitInvariantL0Test is PermitInvariant {
    function _startLevel() internal pure override returns (uint8) {
        return 0;
    }
}

contract PermitInvariantL2Test is PermitInvariant {
    function _startLevel() internal pure override returns (uint8) {
        return 2;
    }
}
