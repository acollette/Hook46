// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {LPToken} from "./LPToken.sol";
import {MultiRewardStaking} from "./MultiRewardStaking.sol";
import {Vault} from "./Vault.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

// todo: refactor to have only one LP token from the Vault. Mint based on liquidity.
// note : we keep vault as we might change the strategies of the Vault which makes it interesting.

contract FungiHook is BaseHook {
    // Use CurrencyLibrary and BalanceDeltaLibrary
    // to add some helper functions over the Currency and BalanceDelta
    // data types
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // The multiplier for the tick spacing defining the narrow range.
    int24 public immutable narrowRangeMultiple;
    // The multiplier for the tick spacing defining the large range.
    int24 public immutable largeRangeMultiple;

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(PoolId poolId => PoolInfo) public poolInfo;
    mapping(PoolId poolId => mapping(bool narrow => RangeInfo)) public rangeInfo;

    struct PoolInfo {
        int24 initialTick;
        PoolKey poolKey;
        Vault vaultToken0;
        Vault vaultToken1;
        MultiRewardStaking multiRewardNarrow;
        MultiRewardStaking multiRewardLarge;
    }

    struct RangeInfo {
        bool active;
        int24 tickLower;
        int24 tickUpper;
        uint128 totalLiquidity;
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
        LPToken lpToken;
    }

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error BalanceTooLow();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    // Initialize BaseHook
    constructor(IPoolManager manager_, int24 narrowRangeMultiple_, int24 largeRangeMultiple_) BaseHook(manager_) {
        narrowRangeMultiple = narrowRangeMultiple_;
        largeRangeMultiple = largeRangeMultiple_;
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

        // Store poolKey
        poolInfo[poolId].poolKey = key;

        // Deploy ERC20 LP tokens and map it to pool
        address narrowLPToken = address(new LPToken("narrow", "nrw", 18));
        address largeLPToken = address(new LPToken("narrow", "nrw", 18));
        rangeInfo[poolId][true].lpToken = LPToken(narrowLPToken);
        rangeInfo[poolId][false].lpToken = LPToken(largeLPToken);

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

        // Add sqrtPrices for tick ranges
        {
            int24 halfNarrowTickRange = narrowRangeMultiple * key.tickSpacing / 2;
            int24 halfLargeTickRange = largeRangeMultiple * key.tickSpacing / 2;

            rangeInfo[poolId][true].sqrtPriceX96Lower = TickMath.getSqrtPriceAtTick(tick - halfNarrowTickRange);
            rangeInfo[poolId][true].sqrtPriceX96Upper = TickMath.getSqrtPriceAtTick(tick + halfNarrowTickRange);
            rangeInfo[poolId][false].sqrtPriceX96Lower = TickMath.getSqrtPriceAtTick(tick - halfLargeTickRange);
            rangeInfo[poolId][false].sqrtPriceX96Upper = TickMath.getSqrtPriceAtTick(tick + halfLargeTickRange);

            rangeInfo[poolId][true].tickLower = tick - halfNarrowTickRange;
            rangeInfo[poolId][true].tickUpper = tick + halfNarrowTickRange;
            rangeInfo[poolId][false].tickLower = tick - halfLargeTickRange;
            rangeInfo[poolId][false].tickUpper = tick + halfLargeTickRange;
        }

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

    function addLiquidity(bool narrow, uint256 amountDesired0, uint256 amountDesired1, PoolId poolId) external {
        // Get current pool price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // Cache Struct
        RangeInfo memory rangeInfo_ = rangeInfo[poolId][narrow];

        // Get liquidity for amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, rangeInfo_.sqrtPriceX96Lower, rangeInfo_.sqrtPriceX96Upper, amountDesired0, amountDesired1
        );

        // Add liquidity in pool for hook
        (, BalanceDelta feesAccrued) = abi.decode(
            poolManager.unlock(
                abi.encodeCall(this.addLiquidityPM, (poolId, narrow, int256(int128(liquidity)), msg.sender))
            ),
            (BalanceDelta, BalanceDelta)
        );

        // Distribute the fees
        _distributeFees(poolId, narrow, feesAccrued.amount0(), feesAccrued.amount1());

        // Mint LP tokens to msg.sender
        if (rangeInfo_.totalLiquidity == 0) {
            rangeInfo_.lpToken.mint(msg.sender, liquidity);
        } else {
            // todo : add FixedPointMathLib
            uint256 lpToMint = liquidity * rangeInfo_.lpToken.totalSupply() / rangeInfo_.totalLiquidity;
            rangeInfo_.lpToken.mint(msg.sender, lpToMint);
        }

        // Increase total liquidity for specific range
        rangeInfo[poolId][narrow].totalLiquidity += liquidity;
    }

    function addLiquidityPM(PoolId poolId, bool narrow, int256 liquidity, address sender)
        external
        poolManagerOnly
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        Currency currency0 = poolInfo[poolId].poolKey.currency0;
        Currency currency1 = poolInfo[poolId].poolKey.currency1;

        // Caller has to approve poolManager for tokens
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: rangeInfo[poolId][narrow].tickLower,
            tickUpper: rangeInfo[poolId][narrow].tickUpper,
            liquidityDelta: int256(int128(liquidity)),
            salt: bytes32(uint256(uint160(address(this))))
        });

        // Call modifyLiquidity()
        (callerDelta, feesAccrued) = poolManager.modifyLiquidity(poolInfo[poolId].poolKey, params, "");

        // Process deltas
        processBalanceDelta(sender, sender, currency0, currency1, callerDelta);
        processBalanceDelta(address(this), address(this), currency0, currency1, feesAccrued);
    }

    function removeLiquidity(PoolId poolId, bool narrow, uint256 lpAmount) external {
        // Get current tick of pool
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // Cache storage pointer
        RangeInfo storage rangeInfo_ = rangeInfo[poolId][narrow];

        // Get lpToken
        LPToken lpToken_ = rangeInfo_.lpToken;

        if (lpToken_.balanceOf(msg.sender) < lpAmount) revert BalanceTooLow();

        // Check if range is active
        if (rangeInfo_.isActive) {
            // Collect fees and distribute

            // Decrease totalLiquidity

            // Get liquidity for amounts
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, rangeInfo_.sqrtPriceX96Lower, rangeInfo_.sqrtPriceX96Upper, amountDesired0, amountDesired1
            );

            // Add liquidity in pool for hook
            (, BalanceDelta feesAccrued) = abi.decode(
                poolManager.unlock(
                    abi.encodeCall(this.addLiquidityPM, (poolId, narrow, int256(int128(liquidity)), msg.sender))
                ),
                (BalanceDelta, BalanceDelta)
            );

            // Distribute the fees
            _distributeFees(poolId, narrow, feesAccrued.amount0(), feesAccrued.amount1());

            // Increase total liquidity for specific range
            rangeInfo[poolId][narrow].totalLiquidity += liquidity;
        } else {
            // Todo : Collect fees and distribute first (do we really need to distribute the fees from the Vault ? Don't think so but maybe cleaner)
            // Check which token the position is fully in and how much of assets it represents
            Vault activeVault =
                currentTick <= rangeInfo_.tickLower ? poolInfo[poolId].vaultToken0 : poolInfo[poolId].vaultToken1;

            // Convert LP to number of assets to withdraw (LP number represents share of liquidity)
            uint256 assets = lpAmount.mulDivDown(activeVault.totalAssetsForRange(narrow), lpToken_.totalSupply());

            // Withdraw from Vault the number of assets to the msg.sender
            activeVault.withdraw(assets, narrow, msg.sender);

            // Burn lp tokens
            lpToken_.burn(msg.sender, lpAmount);
        }
    }

    // todo: only distribute once per block
    function _distributeFees(PoolId poolId, bool narrow, int128 amount0, int128 amount1) internal {
        MultiRewardStaking multiReward_ =
            narrow ? poolInfo[poolId].multiRewardNarrow : poolInfo[poolId].multiRewardLarge;
        if (amount0 > 0) {
            multiReward_.depositReward(Currency.unwrap(poolInfo[poolId].poolKey.currency0), uint256(uint128(amount0)));
        }

        if (amount1 > 0) {
            multiReward_.depositReward(Currency.unwrap(poolInfo[poolId].poolKey.currency1), uint256(uint128(amount1)));
        }
    }

    function processBalanceDelta(
        address sender,
        address recipient,
        Currency currency0,
        Currency currency1,
        BalanceDelta delta
    ) internal {
        if (delta.amount0() > 0) {
            if (currency0.isNative()) {
                poolManager.settle{value: uint128(delta.amount0())}(currency0);
            } else {
                ERC20(Currency.unwrap(currency0)).transferFrom(sender, address(poolManager), uint128(delta.amount0()));
                poolManager.settle(currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (currency1.isNative()) {
                poolManager.settle{value: uint128(delta.amount1())}(currency1);
            } else {
                ERC20(Currency.unwrap(currency1)).transferFrom(sender, address(poolManager), uint128(delta.amount1()));
                poolManager.settle(currency1);
            }
        }

        if (delta.amount0() < 0) {
            poolManager.take(currency0, recipient, uint128(-delta.amount0()));
        }
        if (delta.amount1() < 0) {
            poolManager.take(currency1, recipient, uint128(-delta.amount1()));
        }
    }
}
