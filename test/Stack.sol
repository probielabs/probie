// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Safe} from "safe/Safe.sol";
import {SafeL2} from "safe/SafeL2.sol";
import {SafeProxyFactory} from "safe/proxies/SafeProxyFactory.sol";
import {MultiSendCallOnly} from "safe/libraries/MultiSendCallOnly.sol";
import {ProbieFactory} from "../src/ProbieFactory.sol";
import {ProbiePermit} from "../src/ProbiePermit.sol";
import {IAllowanceModule} from "../src/interfaces/IAllowanceModule.sol";
import {ProbieSetup} from "../script/ProbieSetup.sol";

contract USDG is ERC20("Global Dollar", "USDG") {
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev The real stack, deployed locally: Safe L2 1.4.1, SafeProxyFactory, MultiSendCallOnly, AllowanceModule 0.1.1
///      (built like its release) and a 6-decimal token as USDG. A 1-of-1 Safe runs the one-batch setup.
abstract contract Stack is Test {
    uint96 constant USD = 1e6;

    IAllowanceModule module;
    USDG usdg;
    ProbieFactory factory;
    address singleton;
    address proxyFactory;
    address multiSend;

    uint256 ownerKey;
    address owner;
    Safe safe;
    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address shop2 = makeAddr("shop2");
    address stranger = makeAddr("stranger");
    address stranger2 = makeAddr("stranger2");

    function _deployStack() internal {
        vm.warp(1_794_960_000); // 2026-11-18 00:00 UTC
        singleton = address(new SafeL2());
        proxyFactory = address(new SafeProxyFactory());
        multiSend = address(new MultiSendCallOnly());
        module = IAllowanceModule(deployCode("AllowanceModule.sol:AllowanceModule"));
        usdg = new USDG();
        factory = new ProbieFactory(address(module), address(usdg));
        (owner, ownerKey) = makeAddrAndKey("owner");
        safe = ProbieSetup.newSafe(proxyFactory, singleton, owner, 0);
        usdg.mint(address(safe), 1_000_000 * USD);
    }

    function _open(uint8 startLevel, uint96 ceiling, bytes32 salt) internal returns (ProbiePermit) {
        address[] memory payees = new address[](2);
        payees[0] = shop;
        payees[1] = shop2;
        return ProbiePermit(
            ProbieSetup.runSetup(
                safe, ownerKey, multiSend, factory, ProbieSetup.Permit(agent, startLevel, payees, ceiling, salt)
            )
        );
    }

    /// @dev Any owner call, as a signed Safe transaction.
    function _owner(address to, bytes memory data) internal {
        assertTrue(ProbieSetup.call(safe, ownerKey, to, data), "safe tx failed");
    }

    function _setCeiling(address permit, uint96 ceiling) internal {
        _owner(address(module), ProbieSetup.setAllowance(permit, address(usdg), ceiling));
    }

    function _allowance(address permit) internal view returns (uint256[5] memory) {
        return module.getTokenAllowance(address(safe), permit, address(usdg));
    }
}
