// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Safe} from "safe/Safe.sol";
import {Enum} from "safe/common/Enum.sol";
import {SafeProxyFactory} from "safe/proxies/SafeProxyFactory.sol";
import {MultiSendCallOnly} from "safe/libraries/MultiSendCallOnly.sol";
import {ProbieFactory} from "../src/ProbieFactory.sol";
import {ProbiePermit} from "../src/ProbiePermit.sol";

/// @notice The Safe side of Probie: open a 1-of-1 Safe, build the one-batch setup, and run any call as a Safe
///         transaction signed by the owner key. Shared by the scripts and the tests.
library ProbieSetup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Robinhood Chain (4663)
    address internal constant MODULE = 0xAA46724893dedD72658219405185Fb0Fc91e091C; // AllowanceModule 0.1.1
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
    address internal constant SAFE_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762; // Safe L2 1.4.1
    address internal constant PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67; // SafeProxyFactory 1.4.1
    address internal constant MULTISEND = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2; // MultiSendCallOnly 1.4.1

    /// @notice The ceiling resets every 1440 minutes, counted from a UTC midnight: the permit's own day.
    uint16 internal constant DAY_MIN = 1440;

    function newSafe(address proxyFactory, address singleton, address owner, uint256 saltNonce)
        internal
        returns (Safe safe)
    {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory init =
            abi.encodeCall(Safe.setup, (owners, 1, address(0), "", address(0), address(0), 0, payable(address(0))));
        safe = Safe(payable(address(SafeProxyFactory(proxyFactory).createProxyWithNonce(singleton, init, saltNonce))));
    }

    /// @notice Runs one Safe transaction, signed by the 1-of-1 owner's key.
    function exec(Safe safe, uint256 ownerKey, address to, bytes memory data, Enum.Operation op)
        internal
        returns (bool)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _hash(safe, to, data, op));
        return
            safe.execTransaction(to, 0, data, op, 0, 0, 0, address(0), payable(address(0)), abi.encodePacked(r, s, v));
    }

    function _hash(Safe safe, address to, bytes memory data, Enum.Operation op) private view returns (bytes32) {
        return safe.getTransactionHash(to, 0, data, op, 0, 0, 0, address(0), address(0), safe.nonce());
    }

    function call(Safe safe, uint256 ownerKey, address to, bytes memory data) internal returns (bool) {
        return exec(safe, ownerKey, to, data, Enum.Operation.Call);
    }

    /// @notice What the owner picks for a permit. Amounts in USDG units (6 decimals).
    struct Permit {
        address agent;
        uint8 startLevel;
        address[] payees;
        uint96 ceiling;
        bytes32 salt;
    }

    /// @notice The one-batch setup, as MultiSendCallOnly calldata the Safe delegatecalls:
    ///         enableModule(module), factory.create(...), module.addDelegate(permit),
    ///         module.setAllowance(permit, token, ceiling, 1440, today's UTC midnight in minutes).
    ///         The module and token are the factory's own, so the batch cannot point the ceiling elsewhere.
    function setupBatch(address safe, ProbieFactory factory, Permit memory p)
        internal
        view
        returns (bytes memory data, address permit)
    {
        ProbiePermit impl = ProbiePermit(factory.implementation());
        address module = address(impl.module());
        permit = factory.predict(safe, p.salt);
        // a Safe that already runs the module (a second permit) skips enableModule, which would revert
        bytes memory enable = Safe(payable(safe)).isModuleEnabled(module)
            ? bytes("")
            : _tx(safe, abi.encodeWithSignature("enableModule(address)", module));
        bytes memory txs = abi.encodePacked(
            enable,
            _tx(address(factory), abi.encodeCall(ProbieFactory.create, (p.agent, p.startLevel, p.payees, p.salt))),
            _tx(module, abi.encodeWithSignature("addDelegate(address)", permit)),
            _tx(module, setAllowance(permit, impl.token(), p.ceiling))
        );
        data = abi.encodeCall(MultiSendCallOnly.multiSend, (txs));
    }

    function runSetup(Safe safe, uint256 ownerKey, address multiSend, ProbieFactory factory, Permit memory p)
        internal
        returns (address permit)
    {
        bytes memory data;
        (data, permit) = setupBatch(address(safe), factory, p);
        require(exec(safe, ownerKey, multiSend, data, Enum.Operation.DelegateCall), "setup batch failed");
    }

    /// @notice AllowanceModule.setAllowance calldata for a daily ceiling that resets at UTC midnight.
    function setAllowance(address permit, address token, uint96 ceiling) internal view returns (bytes memory) {
        uint32 midnightMin = uint32(block.timestamp / 1 days * DAY_MIN);
        return abi.encodeWithSignature(
            "setAllowance(address,address,uint96,uint16,uint32)", permit, token, ceiling, DAY_MIN, midnightMin
        );
    }

    function _tx(address to, bytes memory data) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
    }
}
