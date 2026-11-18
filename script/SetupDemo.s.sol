// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Safe} from "safe/Safe.sol";
import {ProbieFactory} from "../src/ProbieFactory.sol";
import {ProbiePermit} from "../src/ProbiePermit.sol";
import {ProbieSetup} from "./ProbieSetup.sol";

/// @notice Opens a demo permit: a new 1-of-1 Safe from the live SafeProxyFactory (Safe L2 1.4.1), then the one-batch
///         setup as a single Safe transaction signed by the owner. Inputs (environment):
///           PROBIE_OWNER_KEY     the Safe owner's key (never logged); it also pays the gas
///           PROBIE_FACTORY       the deployed ProbieFactory
///           PROBIE_AGENT         the agent's address
///           PROBIE_PAYEES        approved payees, comma-separated (leave unset for none)
///           PROBIE_CEILING       the daily ceiling in USDG units (6 decimals: 30000000 = $30)
///           PROBIE_START_LEVEL   0, 1 or 2
///           PROBIE_SALT          a bytes32; also the Safe's salt nonce, so each salt is a new Safe
contract SetupDemo is Script {
    function run() external returns (Safe safe, ProbiePermit permit) {
        uint256 key = vm.envUint("PROBIE_OWNER_KEY");
        ProbieFactory factory = ProbieFactory(vm.envAddress("PROBIE_FACTORY"));
        bytes32 salt = vm.envBytes32("PROBIE_SALT");
        ProbieSetup.Permit memory p = ProbieSetup.Permit({
            agent: vm.envAddress("PROBIE_AGENT"),
            startLevel: uint8(vm.envUint("PROBIE_START_LEVEL")),
            payees: vm.envOr("PROBIE_PAYEES", ",", new address[](0)), // unset = no approved payees
            ceiling: uint96(vm.envUint("PROBIE_CEILING")),
            salt: salt
        });
        require(address(factory).code.length > 0, "no factory at PROBIE_FACTORY");
        require(p.ceiling > 0, "PROBIE_CEILING must be > 0");
        require(p.startLevel <= 2, "PROBIE_START_LEVEL must be 0-2");

        vm.startBroadcast(key);
        safe = ProbieSetup.newSafe(ProbieSetup.PROXY_FACTORY, ProbieSetup.SAFE_L2, vm.addr(key), uint256(salt));
        permit = ProbiePermit(ProbieSetup.runSetup(safe, key, ProbieSetup.MULTISEND, factory, p));
        vm.stopBroadcast();

        console.log("owner      ", vm.addr(key));
        console.log("Safe       ", address(safe));
        console.log("permit     ", address(permit));
        console.log("agent      ", permit.agent());
        console.log("level      ", permit.level());
        console.log("ceiling    ", p.ceiling);
    }
}
