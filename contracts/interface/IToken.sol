// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IToken is IERC20 {
    /// @notice Mints `amount` tokens to `to`.
    function mint(address to, uint256 amount) external;
    /// @notice Burns `amount` tokens from caller balance.
    function burn(uint256 amount) external;
    /// @notice Transfers ownership to `newOwner`.
    function transferOwnership(address newOwner) external;
}