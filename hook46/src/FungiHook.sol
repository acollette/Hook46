// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {LPToken} from "./LPToken.sol";
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
        LPToken lpNarrow;
        LPToken lpLarge;
        Vault vaultToken0;
        Vault vaultToken1;
        MultiRewardStaking multiRewardNarrow;
        MultiRewardStaking multiRewardLarge;
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
        // cache values
        PoolId poolId = key.toId();
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Map the current tick 1:1 (assuming initialization is done stable price)
        poolInfo[poolId].initialTick = tick;

        // Deploy ERC20 LP tokens and map it to pool
        address narrowLPToken = address(new LPToken("narrow", "nrw", 18));
        address largeLPToken = address(new LPToken("narrow", "nrw", 18));
        poolInfo[poolId].lpNarrow = LPToken(narrowLPToken);
        poolInfo[poolId].lpLarge = LPToken(largeLPToken);

        // Deploy MultiReward contract
        {
            MultiRewardStaking multiRewardNarrow = new MultiRewardStaking(narrowLPToken);
            MultiRewardStaking multiRewardLarge = new MultiRewardStaking(largeLPToken);
            poolInfo[poolId].multiRewardNarrow = multiRewardNarrow;
            poolInfo[poolId].multiRewardNarrow = multiRewardLarge;

            // add reward tokens
            multiRewardNarrow.addReward(token0, 1);
            multiRewardNarrow.addReward(token1, 1);

            multiRewardLarge.addReward(token0, 1);
            multiRewardLarge.addReward(token1, 1);
        }

        // Deploy Vaults
        poolInfo[poolId].vaultToken0 = new Vault(ERC20(token0), "Fungi-0", "FUN0");
        poolInfo[poolId].vaultToken0 = new Vault(ERC20(token1), "Fungi-1", "FUN1");

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
