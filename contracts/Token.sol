// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import "./interface/IToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


contract Token is IToken, ERC20, Ownable {
    /// @notice Creates token and mints full initial supply to factory.
    constructor(
        string memory name,
        string memory symbol,
        address factory,
        uint256 totalSupply
    ) ERC20(name, symbol) Ownable(factory) {
        _mint(factory, totalSupply);
    }

    /// @notice Mints new tokens. Restricted to owner (factory/admin).
    function mint(address to, uint256 amount) external override onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burns caller's own tokens.
    function burn(uint256 amount) external override { 
        _burn(msg.sender, amount);
    }

    /// @notice Transfers contract ownership to a new owner.
    function transferOwnership(address newOwner) public override(IToken, Ownable) onlyOwner {
        super.transferOwnership(newOwner);
    }
}