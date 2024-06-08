// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract Vault is Owned {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    ERC20 public immutable asset;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(bool narrow => uint256 shares) public rangeToShares;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotImplemented();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, bool narrow, uint256 assets, uint256 shares);

    event Withdraw(address indexed caller, bool narrow, uint256 assets, uint256 shares);

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(ERC20 asset_) Owned(msg.sender) {
        asset = asset_;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, bool narrow) external onlyOwner returns (uint256 shares) {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets, narrow)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);

        rangeToShares[narrow] = shares;

        // todo : deposit in Strategy

        emit Deposit(msg.sender, narrow, assets, shares);
    }

    function withdraw(uint256 assets, bool narrow, address receiver) external onlyOwner returns (uint256 shares) {
        shares = previewWithdraw(assets, narrow); // No need to check for rounding error, previewWithdraw rounds up.

        rangeToShares[narrow] -= shares;

        // todo : withdraw from strategy

        emit Withdraw(receiver, narrow, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    function redeem(bool narrow) external onlyOwner returns (uint256 assets) {
        // Check for rounding error since we round down in previewRedeem.
        uint256 shares = rangeToShares[narrow];
        require((assets = previewRedeem(narrow)) != 0, "ZERO_ASSETS");

        rangeToShares[narrow] = 0;

        // todo : withdraw from strategy

        emit Withdraw(msg.sender, narrow, assets, shares);

        asset.safeTransfer(msg.sender, assets);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view returns (uint256) {}

    function totalAssetsForRange(bool narrow) public view returns (uint256 assets) {
        if (narrow) {
            uint256 narrowShares = rangeToShares[true];
            assets = narrowShares.mulDivDown(totalAssets(), narrowShares + rangeToShares[false]);
        } else {
            uint256 largeShares = rangeToShares[false];
            assets = largeShares.mulDivDown(totalAssets(), largeShares + rangeToShares[true]);
        }
    }

    function convertToShares(uint256 assets, bool narrow) public view returns (uint256 shares) {
        if (rangeToShares[!narrow] == 0) {
            shares = assets.mulDivDown(rangeToShares[!narrow], totalAssets());
        } else {
            shares = assets;
        }
    }

    function convertToAssets(bool narrow) public view returns (uint256 assets) {
        assets = totalAssetsForRange(narrow);
    }

    function previewDeposit(uint256 assets, bool narrow) public view returns (uint256) {
        return convertToShares(assets, narrow);
    }

    function previewWithdraw(uint256 assets, bool narrow) public view returns (uint256 shares) {
        uint256 totalAssetsForRange_ = totalAssetsForRange(narrow);
        shares = assets.mulDivUp(rangeToShares[narrow], totalAssetsForRange_);
    }

    function previewRedeem(bool narrow) public view returns (uint256) {
        return convertToAssets(narrow);
    }
}
