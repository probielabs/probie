// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ProbiePermit} from "./ProbiePermit.sol";

/// @title ProbieFactory
/// @notice Makes one ProbiePermit clone per (Safe, agent). The caller is the Safe: it calls create() from its own
///         batched transaction, so nobody can open a permit on someone else's Safe. predict() gives the address
///         ahead of time, so the same batch can add the permit as an AllowanceModule delegate and set its ceiling.
contract ProbieFactory {
    address public immutable implementation;

    event PermitCreated(address indexed safe, address indexed permit, address indexed agent, uint8 startLevel);

    constructor(address module, address token) {
        implementation = address(new ProbiePermit(module, token, address(this)));
    }

    function create(address agent, uint8 startLevel, address[] calldata payees, bytes32 salt)
        external
        returns (address permit)
    {
        permit = Clones.cloneDeterministic(implementation, _salt(msg.sender, salt));
        ProbiePermit(permit).initialize(msg.sender, agent, startLevel, payees);
        emit PermitCreated(msg.sender, permit, agent, startLevel);
    }

    function predict(address safe, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(safe, salt));
    }

    function _salt(address safe, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(safe, salt));
    }
}
