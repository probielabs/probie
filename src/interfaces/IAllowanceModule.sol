// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The two calls Probie makes on Safe's audited AllowanceModule 0.1.1
///         (0xAA46724893dedD72658219405185Fb0Fc91e091C on Robinhood Chain).
interface IAllowanceModule {
    /// @dev With an empty signature the module takes msg.sender as the delegate, so a contract can be a delegate.
    function executeAllowanceTransfer(
        address safe,
        address token,
        address payable to,
        uint96 amount,
        address paymentToken,
        uint96 payment,
        address delegate,
        bytes memory signature
    ) external;

    /// @return [amount, spent, resetTimeMin, lastResetMin, nonce], with the period's reset already applied.
    function getTokenAllowance(address safe, address delegate, address token) external view returns (uint256[5] memory);
}
