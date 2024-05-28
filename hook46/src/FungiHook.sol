// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {MultiRewardStaking} from "./MultiRewardStaking.sol";
import {Vault} from "./Vault.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";

contract FungiHook is BaseHook {
    // Use CurrencyLibrary and BalanceDeltaLibrary
    // to add some helper functions over the Currency and BalanceDelta
    // data types
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public immutable narrowRange;
    uint256 public immutable largeRange;

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(PoolId poolId => PoolInfo) public poolInfo;

    struct PoolInfo {
        int24 initialTick;
        bool narrowAcitve;
        bool largeActive;
        ERC20 lpNarrow;
        ERC20 lpLarge;
        Vault vaultToken0;
        Vault vaultToken1;
        MultiRewardStaking multiReward;        
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    // Initialize BaseHook
    constructor(IPoolManager _manager, uint256 narrowRange_, uint256 largeRange_) BaseHook(_manager) {
        narrowRange = narrowRange_;
        largeRange = largeRange_;
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    // Set up hook permissions to return `true`
    // for the hook functions we are using
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {   
        // cache poolId
        PoolId poolId = key.toId();
        // Map the current tick 1:1 (assuming first deposit is at stable price)
        poolInfo[poolId].initialTick = tick;

        // Deploy ERC20 LP tokens and map it to pool
        poolInfo[poolId].lpNarrow = new ERC20("narrow", "nrw", 18);


        // Deploy MultiReward contract

        // Deploy Vaults


        return this.afterInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams memory params,
        BalanceDelta swapDelta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, int128) {
        // Check if needs to invest out of range liquidity 
        return (this.afterSwap.selector, 0);
    }

    function addLiquidity(bool large, uint256 amountDesired0, uint256 amountDesired1, PoolId poolId) external {
        // calculate ratios


        // Swap one for the other

        // Calculate liquidity in narrow/large

        // Mint LP tokens to msg.sender

        // Add liquidity in pool for hook
    }
}
