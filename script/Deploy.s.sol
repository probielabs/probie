// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ProbieFactory} from "../src/ProbieFactory.sol";
import {ProbieSetup} from "./ProbieSetup.sol";

/// @notice Deploys ProbieFactory (and with it the ProbiePermit implementation) for the live AllowanceModule and USDG.
///         The deployer key comes from the PROBIE_DEPLOYER_KEY environment variable and is never logged.
///         PROBIE_DEPLOYER_KEY=... forge script script/Deploy.s.sol --rpc-url <rpc>   (add --broadcast to send)
contract Deploy is Script {
    function run() external returns (ProbieFactory factory) {
        require(ProbieSetup.MODULE.code.length > 0, "no AllowanceModule here: wrong chain?");
        require(ProbieSetup.USDG.code.length > 0, "no USDG here: wrong chain?");
        uint256 key = vm.envUint("PROBIE_DEPLOYER_KEY");
        vm.startBroadcast(key);
        factory = new ProbieFactory(ProbieSetup.MODULE, ProbieSetup.USDG);
        vm.stopBroadcast();
        console.log("chain id                ", block.chainid);
        console.log("deployer                ", vm.addr(key));
        console.log("ProbieFactory           ", address(factory));
        console.log("ProbiePermit (impl)     ", factory.implementation());
    }
}
