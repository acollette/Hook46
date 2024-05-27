// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";

contract AaveMockedPool is ERC20 {
    ERC20 public immutable underlyingAsset;

    error WrongAsset();
    error InsufficientLPTokens();

    constructor(address _underlyingAsset, string memory _name, string memory _symbol, uint8 _decimals)
        ERC20(_name, _symbol, _decimals)
    {
        underlyingAsset = ERC20(_underlyingAsset);
    }

    function deposit(address asset, uint256 amount) external {
        if (asset != address(underlyingAsset)) revert WrongAsset();

        uint256 totalUnderlying = underlyingAsset.balanceOf(address(this));

        ERC20(asset).transferFrom(msg.sender, address(this), amount);

        if (totalSupply == 0) {
            _mint(msg.sender, amount * 10 ** (18 - ERC20(asset).decimals()));
        } else {
            uint256 lpToMint = amount * totalSupply / totalUnderlying;
            _mint(msg.sender, lpToMint);
        }
    }

    function withdraw(uint256 amount) external {
        if (amount > balanceOf[msg.sender]) revert InsufficientLPTokens();

        uint256 underlyingAmount = amount * underlyingAsset.balanceOf(address(this)) / totalSupply;

        _burn(msg.sender, amount);
        underlyingAsset.transfer(msg.sender, underlyingAmount);
    }
}
