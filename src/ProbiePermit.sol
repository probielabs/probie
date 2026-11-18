// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAllowanceModule} from "./interfaces/IAllowanceModule.sol";

/// @title ProbiePermit
/// @notice A learner's permit for one AI agent over one Safe.
///         The Safe keeps the money. The Safe's AllowanceModule caps what this permit can move per day: that is the
///         owner's ceiling, enforced by audited code. Inside the ceiling the permit lets the agent pay only what its
///         level allows. Clean days raise the level. A blocked payment is a strike: nothing moves, and the strike is
///         written on chain (pay() returns false instead of reverting, so the record stays).
/// @dev One EIP-1167 clone per (Safe, agent), made by ProbieFactory. The Safe sets it up in one batched transaction:
///      factory.create(...), allowanceModule.addDelegate(permit), allowanceModule.setAllowance(permit, token,
///      ceiling, 1440, <a UTC midnight in minutes>). Amounts are in the token's units (USDG has 6 decimals).
contract ProbiePermit {
    // ---------- rules ----------
    uint8 public constant TOP_LEVEL = 4;
    uint8 public constant MAX_START_LEVEL = 2;
    /// @notice After any strike, payments to new payees are blocked for this long.
    uint256 public constant PAUSE = 7 days;
    /// @notice Going over the daily limit (or the ceiling) a second time within this window drops one level.
    uint256 public constant DEMOTE_WINDOW = 7 days;

    // ---------- reasons (check() and the Strike event) ----------
    uint8 public constant OK = 0;
    uint8 public constant OVER_LIMIT = 1; // over the level's daily limit
    uint8 public constant OVER_CEILING = 2; // over what is left of the owner's ceiling today
    uint8 public constant PAYEE_NOT_ALLOWED = 3; // a new payee at a level that allows none
    uint8 public constant NEW_PAYEES_PAUSED = 4; // a new payee within PAUSE of a strike
    uint8 public constant OVER_NEW_PAYEE_CAP = 5; // over the level's daily cap for new payees
    uint8 public constant FROZEN = 6; // check() only: pay() reverts while frozen and records nothing

    IAllowanceModule public immutable module;
    address public immutable token;
    address public immutable factory;

    address public safe;
    address public agent;
    uint8 public level;
    bool public frozen;
    /// @notice While frozen: the time up to which the frozen clock has been banked (clean days do not run while frozen).
    uint64 public frozenAt;
    /// @notice Start of the current clean run: the permit's start, its last strike or its last level-up.
    uint64 public cleanSince;
    /// @notice Time of the last over-limit or over-ceiling strike (0 = never).
    uint64 public lastOverLimit;
    /// @notice New payees are blocked until this time.
    uint64 public pausedUntil;
    uint32 public strikes;
    /// @notice The UTC day (timestamp / 1 days) that spentToday and newSpentToday belong to.
    uint32 public day;
    uint96 public spentToday;
    uint96 public newSpentToday;
    /// @notice The owner's list. Any other address is a new payee, every time.
    mapping(address => bool) public approved;

    struct State {
        uint8 level;
        uint64 cleanSince;
        uint32 day;
        uint96 spent;
        uint96 newSpent;
    }

    struct Status {
        uint8 level;
        uint256 cleanDays;
        uint256 daysToNextLevel; // 0 at the top level
        uint256 dailyLimit;
        uint256 spentToday;
        uint256 newPayeeCap;
        uint256 newSpentToday;
        uint256 ceilingLeft;
        uint64 pausedUntil;
        uint32 strikes;
        bool frozen;
    }

    event Paid(address indexed to, uint256 amount, uint8 level, bool newPayee);
    event Strike(address indexed to, uint256 amount, uint8 reason, uint8 level, uint32 strikes);
    event LevelChanged(uint8 from, uint8 to);
    event PayeeSet(address indexed payee, bool approved);
    event FrozenSet(bool frozen);
    event AgentSet(address indexed agent);

    error NotFactory();
    error NotSafe();
    error NotAgent();
    error BadAddress();
    error BadLevel();
    error BadAmount();
    error IsFrozen();
    error NoCeiling();
    error BadCeiling();

    constructor(address module_, address token_, address factory_) {
        if (module_ == address(0) || token_ == address(0) || factory_ == address(0)) revert BadAddress();
        module = IAllowanceModule(module_);
        token = token_;
        factory = factory_;
        // the implementation itself can never be initialized
        safe = address(0xdead);
    }

    /// @notice Called once by the factory, in the Safe's own transaction.
    function initialize(address safe_, address agent_, uint8 startLevel, address[] calldata payees) external {
        if (msg.sender != factory || safe != address(0)) revert NotFactory();
        if (safe_ == address(0) || agent_ == address(0)) revert BadAddress();
        if (startLevel > MAX_START_LEVEL) revert BadLevel();
        safe = safe_;
        agent = agent_;
        level = startLevel;
        cleanSince = uint64(block.timestamp);
        day = uint32(block.timestamp / 1 days);
        emit AgentSet(agent_);
        for (uint256 i; i < payees.length; ++i) {
            _setPayee(payees[i], true);
        }
    }

    // ---------- the agent ----------

    /// @notice Pay `amount` of the token from the Safe to `to`, if the permit allows it.
    /// @return paid false when the payment was blocked: nothing moved and a strike was recorded.
    function pay(address to, uint256 amount) external returns (bool paid) {
        if (msg.sender != agent) revert NotAgent();
        if (frozen) revert IsFrozen();
        if (to == address(0)) revert BadAddress();
        if (amount == 0 || amount > type(uint96).max) revert BadAmount();

        uint8 before = level;
        State memory s = _state();
        uint8 reason = _reason(s, to, amount);

        if (reason != OK) {
            if (reason == OVER_LIMIT || reason == OVER_CEILING) {
                if (lastOverLimit != 0 && block.timestamp < lastOverLimit + DEMOTE_WINDOW && s.level > 0) s.level--;
                lastOverLimit = uint64(block.timestamp);
            }
            s.cleanSince = uint64(block.timestamp);
            pausedUntil = uint64(block.timestamp + PAUSE);
            uint32 n = strikes + 1;
            strikes = n;
            _save(s, before);
            emit Strike(to, amount, reason, s.level, n);
            return false;
        }

        bool isNew = !approved[to];
        s.spent += uint96(amount);
        if (isNew) s.newSpent += uint96(amount);
        _save(s, before);
        // empty signature: the module checks that msg.sender (this permit) is the Safe's delegate
        module.executeAllowanceTransfer(safe, token, payable(to), uint96(amount), address(0), 0, address(this), "");
        emit Paid(to, amount, s.level, isNew);
        return true;
    }

    // ---------- the owner (the Safe) ----------

    function setPayee(address payee, bool ok) external {
        if (msg.sender != safe) revert NotSafe();
        _setPayee(payee, ok);
    }

    function setFrozen(bool frozen_) external {
        if (msg.sender != safe) revert NotSafe();
        // bank level-ups earned before a freeze; on a thaw, push the clean run past the frozen time
        _save(_state(), level);
        frozen = frozen_;
        frozenAt = uint64(block.timestamp);
        emit FrozenSet(frozen_);
    }

    function setAgent(address agent_) external {
        if (msg.sender != safe) revert NotSafe();
        if (agent_ == address(0)) revert BadAddress();
        agent = agent_;
        emit AgentSet(agent_);
    }

    /// @notice Applies level-ups and the day's counter reset. Anyone may call it; pay() does it too.
    function sync() external {
        _save(_state(), level);
    }

    // ---------- views ----------

    /// @notice The reason a payment would get right now (OK = it would go through).
    function check(address to, uint256 amount) external view returns (uint8) {
        if (frozen) return FROZEN;
        return _reason(_state(), to, amount);
    }

    function status() external view returns (Status memory st) {
        State memory s = _state();
        st.level = s.level;
        st.cleanDays = (block.timestamp - s.cleanSince) / 1 days;
        if (s.level < TOP_LEVEL) st.daysToNextLevel = daysToNext(s.level) - st.cleanDays;
        st.dailyLimit = limitOf(s.level);
        st.spentToday = s.spent;
        st.newPayeeCap = newCapOf(s.level);
        st.newSpentToday = s.newSpent;
        st.ceilingLeft = ceilingLeft();
        st.pausedUntil = pausedUntil;
        st.strikes = strikes;
        st.frozen = frozen;
    }

    /// @notice What is left of the owner's ceiling in the current allowance period.
    function ceilingLeft() public view returns (uint256) {
        uint256[5] memory a = module.getTokenAllowance(safe, address(this), token);
        return a[0] > a[1] ? a[0] - a[1] : 0;
    }

    function limitOf(uint8 l) public pure returns (uint256) {
        if (l == 0) return 5e6;
        if (l == 1) return 25e6;
        if (l == 2) return 100e6;
        if (l == 3) return 500e6;
        return type(uint96).max; // the top level: only the ceiling limits it
    }

    function newCapOf(uint8 l) public pure returns (uint256) {
        if (l < 2) return 0;
        if (l == 2) return 10e6;
        return 25e6;
    }

    function daysToNext(uint8 l) public pure returns (uint256) {
        if (l == 0) return 3;
        if (l == 1) return 7;
        if (l == 2) return 14;
        return 30; // l == 3; the top level never moves up
    }

    // ---------- internals ----------

    /// @dev The stored state with today's counters and any level-ups due applied, in memory.
    function _state() internal view returns (State memory s) {
        s = State(level, cleanSince, day, spentToday, newSpentToday);
        uint32 today = uint32(block.timestamp / 1 days);
        if (s.day != today) {
            s.day = today;
            s.spent = 0;
            s.newSpent = 0;
        }
        // clean days do not run while frozen: the frozen time since frozenAt moves the clean run forward
        if (frozen) s.cleanSince += uint64(block.timestamp - frozenAt);
        while (s.level < TOP_LEVEL) {
            uint256 need = daysToNext(s.level) * 1 days;
            if (block.timestamp < s.cleanSince + need) break;
            s.cleanSince += uint64(need);
            s.level++;
        }
    }

    function _reason(State memory s, address to, uint256 amount) internal view returns (uint8) {
        uint256[5] memory a = module.getTokenAllowance(safe, address(this), token);
        if (a[0] == 0) revert NoCeiling(); // not set up, or the owner removed the ceiling: not the agent's fault
        // the ceiling must be per UTC day: a 1440-minute period whose current start (a[3]) is a UTC midnight
        if (a[2] != 1440 || a[3] % 1440 != 0) revert BadCeiling();
        if (!approved[to]) {
            uint256 cap = newCapOf(s.level);
            if (cap == 0) return PAYEE_NOT_ALLOWED;
            if (block.timestamp < pausedUntil) return NEW_PAYEES_PAUSED;
            if (s.newSpent + amount > cap) return OVER_NEW_PAYEE_CAP;
        }
        if (s.spent + amount > limitOf(s.level)) return OVER_LIMIT;
        if (amount > (a[0] > a[1] ? a[0] - a[1] : 0)) return OVER_CEILING;
        return OK;
    }

    function _save(State memory s, uint8 before) internal {
        level = s.level;
        cleanSince = s.cleanSince;
        day = s.day;
        spentToday = s.spent;
        newSpentToday = s.newSpent;
        if (frozen) frozenAt = uint64(block.timestamp); // the frozen time up to now is now in cleanSince
        if (s.level != before) emit LevelChanged(before, s.level);
    }

    function _setPayee(address payee, bool ok) internal {
        if (payee == address(0)) revert BadAddress();
        approved[payee] = ok;
        emit PayeeSet(payee, ok);
    }
}
