// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import "./BondingCurve.sol";

contract BondingCurveDeployer {
    address public immutable tokenFactory;

    /// @notice Stores factory address authorized to deploy curves.
    constructor(address _tokenFactory) {
        require(_tokenFactory != address(0), "Zero factory");
        tokenFactory = _tokenFactory;
    }

    /// @notice Deploys a new BondingCurve instance. Callable only by factory.
    function deployBondingCurve(
        address owner_,
        address creator,
        uint256 targetValue,
        address tokenRaise,
        address priceFeed,
        uint256 virtualTokenReserve
    ) external returns (address curve) {
        require(msg.sender == tokenFactory, "Only factory");
        curve = address(
            new BondingCurve(owner_, creator, targetValue, tokenRaise, priceFeed, virtualTokenReserve)
        );
    }
}
