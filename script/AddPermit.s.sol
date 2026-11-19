// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Safe} from "safe/Safe.sol";
import {ProbieFactory} from "../src/ProbieFactory.sol";
import {ProbiePermit} from "../src/ProbiePermit.sol";
import {ProbieSetup} from "./ProbieSetup.sol";

/// @notice Opens one more permit on an existing 1-of-1 Safe. Its AllowanceModule is already on, so the batch skips
///         enableModule. Same inputs as SetupDemo, plus PROBIE_SAFE; PROBIE_SALT picks the permit's address.
contract AddPermit is Script {
    function run() external returns (ProbiePermit permit) {
        uint256 key = vm.envUint("PROBIE_OWNER_KEY");
        Safe safe = Safe(payable(vm.envAddress("PROBIE_SAFE")));
        ProbieFactory factory = ProbieFactory(vm.envAddress("PROBIE_FACTORY"));
        ProbieSetup.Permit memory p = ProbieSetup.Permit({
            agent: vm.envAddress("PROBIE_AGENT"),
            startLevel: uint8(vm.envUint("PROBIE_START_LEVEL")),
            payees: vm.envOr("PROBIE_PAYEES", ",", new address[](0)), // unset = no approved payees
            ceiling: uint96(vm.envUint("PROBIE_CEILING")),
            salt: vm.envBytes32("PROBIE_SALT")
        });
        require(safe.isOwner(vm.addr(key)), "key is not an owner of PROBIE_SAFE");
        require(p.ceiling > 0, "PROBIE_CEILING must be > 0");
        require(p.startLevel <= 2, "PROBIE_START_LEVEL must be 0-2");
        require(factory.predict(address(safe), p.salt).code.length == 0, "that salt already has a permit");

        vm.startBroadcast(key);
        permit = ProbiePermit(ProbieSetup.runSetup(safe, key, ProbieSetup.MULTISEND, factory, p));
        vm.stopBroadcast();

        console.log("Safe       ", address(safe));
        console.log("permit     ", address(permit));
        console.log("agent      ", permit.agent());
        console.log("level      ", permit.level());
        console.log("ceiling    ", p.ceiling);
    }
}
