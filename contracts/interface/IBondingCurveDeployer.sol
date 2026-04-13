// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

interface IBondingCurveDeployer {
    function deployBondingCurve(
        address owner_,
        address creator,
        uint256 targetValue,
        address tokenRaise,
        address priceFeed,
        uint256 virtualTokenReserve
    ) external returns (address curve);
}
