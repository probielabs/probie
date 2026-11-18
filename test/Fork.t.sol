// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Safe} from "safe/Safe.sol";
import {ProbieFactory} from "../src/ProbieFactory.sol";
import {ProbiePermit} from "../src/ProbiePermit.sol";
import {IAllowanceModule} from "../src/interfaces/IAllowanceModule.sol";
import {ProbieSetup} from "../script/ProbieSetup.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @dev Robinhood Chain at one pinned block: our factory against the LIVE AllowanceModule 0.1.1, LIVE USDG, the live
///      Safe L2 1.4.1 singleton, SafeProxyFactory and MultiSendCallOnly. Off unless PROBIE_FORK=true, so the default
///      `forge test` stays offline:
///        PROBIE_FORK=true PROBIE_FORK_BLOCK=<recent block> forge test --match-path test/Fork.t.sol
///      The public RPC is not an archive node: it serves state for recent blocks only (a block from ~30 minutes ago
///      already fails with "historical state ... is not available"). So the block is pinned per run: PROBIE_FORK_BLOCK,
///      or the head at the moment the fork opens when it is unset.
contract ForkTest is Test {
    uint256 constant USD = 1e6;

    function setUp() public {
        if (!vm.envOr("PROBIE_FORK", false)) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envOr("PROBIE_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork("robinhood");
        else vm.createSelectFork("robinhood", pinned);
    }

    function test_liveModuleIsTheVendoredRelease() public view {
        assertEq(
            _withoutMetadata(ProbieSetup.MODULE.code),
            _withoutMetadata(vm.getDeployedCode("AllowanceModule.sol:AllowanceModule"))
        );
        assertGt(ProbieSetup.MULTISEND.code.length, 0, "MultiSendCallOnly missing");
        assertEq(IERC20(ProbieSetup.USDG).decimals(), 6);
    }

    function test_setupPaymentAndStrikeOnLiveContracts() public {
        ProbieFactory factory = new ProbieFactory(ProbieSetup.MODULE, ProbieSetup.USDG);
        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        address agent = makeAddr("agent");
        address shop = makeAddr("shop");
        address stranger = makeAddr("stranger");

        Safe safe = ProbieSetup.newSafe(ProbieSetup.PROXY_FACTORY, ProbieSetup.SAFE_L2, owner, block.timestamp);
        address[] memory payees = new address[](1);
        payees[0] = shop;
        ProbiePermit permit = ProbiePermit(
            ProbieSetup.runSetup(
                safe,
                ownerKey,
                ProbieSetup.MULTISEND,
                factory,
                ProbieSetup.Permit(agent, 0, payees, uint96(20 * USD), "fork")
            )
        );
        assertTrue(safe.isModuleEnabled(ProbieSetup.MODULE));
        deal(ProbieSetup.USDG, address(safe), 100 * USD);

        vm.prank(agent);
        assertTrue(permit.pay(shop, 5 * USD));
        assertEq(IERC20(ProbieSetup.USDG).balanceOf(shop), 5 * USD);
        assertEq(IERC20(ProbieSetup.USDG).balanceOf(address(safe)), 95 * USD);
        uint256[5] memory a =
            IAllowanceModule(ProbieSetup.MODULE).getTokenAllowance(address(safe), address(permit), ProbieSetup.USDG);
        assertEq(a[1], 5 * USD);

        vm.prank(agent);
        assertFalse(permit.pay(stranger, 1 * USD));
        assertEq(permit.strikes(), 1);
        assertEq(IERC20(ProbieSetup.USDG).balanceOf(stranger), 0);
        assertEq(IERC20(ProbieSetup.USDG).balanceOf(address(safe)), 95 * USD);
    }

    function _withoutMetadata(bytes memory code) internal pure returns (bytes32) {
        uint256 n = (uint256(uint8(code[code.length - 2])) << 8) | uint8(code[code.length - 1]);
        uint256 len = code.length - n - 2;
        assembly {
            mstore(code, len)
        }
        return keccak256(code);
    }
}
