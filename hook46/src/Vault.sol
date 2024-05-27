// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

contract AaveVault is ERC4626, Owned {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address owner => uint256 shares) public addressToShares;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotImplemented();

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(ERC20 _asset, string memory _name, string memory _symbol)
        ERC4626(_asset, _name, _symbol)
        Owned(msg.sender)
    {}

    /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        // All liquidity in Aave
        // + all amounts of token in active liquidity
    }

    function deposit(uint256 assets, address receiver) public override onlyOwner returns (uint256 shares) {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // No transfer of assets initially, all sent to the pool.
        // But we need to keep track of amounts deposited from the user.
        addressToShares[receiver] = shares;

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert NotImplemented();
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        onlyOwner
        returns (uint256 shares)
    {
        shares = previewWithdraw(assets);

        // TODO : Need to identify and calculate the extra fees earned here

        if (addressToShares[receiver] > shares) {
            addressToShares[receiver] -= shares;
        } else {
            addressToShares[receiver] = 0;
        }

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert NotImplemented();
    }
}
