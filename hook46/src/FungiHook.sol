// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Position} from "v4-core/libraries/Position.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {LPToken} from "./LPToken.sol";
import {MultiRewardStaking} from "./MultiRewardStaking.sol";
import {Vault} from "./Vault.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

contract FungiHook is BaseHook {
    // Use CurrencyLibrary and BalanceDeltaLibrary
    // to add some helper functions over the Currency and BalanceDelta
    // data types
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

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

    int24 internal lastTick;

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
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
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

    /*//////////////////////////////////////////////////////////////
                      HOOKS LOGIC IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata hookData)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        // cache values
        PoolId poolId = key.toId();
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Store current tick as last tick
        lastTick = tick;

        // Map the current tick 1:1 (assuming initialization is done stable price)
        poolInfo[poolId].initialTick = tick;

        // Store poolKey
        poolInfo[poolId].poolKey = key;

        // Deploy ERC20 LP tokens and map it to pool
        address narrowLPToken = address(new LPToken("narrow", "nrw", 18));
        address largeLPToken = address(new LPToken("large", "lrg", 18));
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
        (address pool0, address pool1) = abi.decode(hookData, (address, address));
        poolInfo[poolId].vaultToken0 = new Vault(ERC20(token0), pool0);
        poolInfo[poolId].vaultToken1 = new Vault(ERC20(token1), pool1);

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

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams memory, BalanceDelta, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, int128)
    {
        // todo : only rebalance periodically, not every time a range is crossed.
        // Check if needs to invest out of range liquidity or call back liquidity from Vault
        // Get current pool price
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);

        RangeInfo memory rangeInfoNarrow = rangeInfo[poolId][true];
        RangeInfo memory rangeInfoLarge = rangeInfo[poolId][false];

        // Check for ranges if they change status
        if (tick > rangeInfoNarrow.tickLower && tick < rangeInfoNarrow.tickUpper) {
            if (rangeInfoNarrow.active == false) _vaultToPool(tick, sqrtPriceX96, true, poolId, rangeInfoNarrow);
            if (rangeInfoLarge.active == false) _vaultToPool(tick, sqrtPriceX96, false, poolId, rangeInfoLarge);
        } else if (tick > rangeInfoLarge.tickLower && tick < rangeInfoLarge.tickUpper) {
            if (rangeInfoNarrow.active == true) _poolToVault(tick, poolId, rangeInfoNarrow, true);
            if (rangeInfoLarge.active == false) _vaultToPool(tick, sqrtPriceX96, false, poolId, rangeInfoLarge);
        } else {
            if (rangeInfoNarrow.active == true) _poolToVault(tick, poolId, rangeInfoNarrow, true);
            if (rangeInfoLarge.active == true) _poolToVault(tick, poolId, rangeInfoLarge, false);
        }

        // Store last tick
        lastTick = tick;

        return (this.afterSwap.selector, 0);
    }

    function _vaultToPool(
        int24 currentTick,
        uint160 sqrtPriceX96,
        bool narrow,
        PoolId poolId,
        RangeInfo memory rangeInfo_
    ) internal {
        // todo : due to possible slippage, can have dust amounts leftover - distribute as fees or send back to Vault ?
        // Redeem funds from Vault
        bool zeroForOne;
        uint256 amountToSwap;
        uint160 sqrtPriceLimitX96;
        if (currentTick > lastTick) {
            // Redeem from Vault
            uint256 assets = poolInfo[poolId].vaultToken0.redeem(narrow);

            zeroForOne = true;

            // Rebalance amount received from Vault so that the ratio of the amounts to deposit matches with ratio of the ticks.
            uint256 ticksLowerToCurrent = uint256(uint24(currentTick - rangeInfo_.tickLower));
            uint256 ticksLowerToUpper = uint256(uint24(rangeInfo_.tickUpper - rangeInfo_.tickLower));
            uint256 targetRatio = ticksLowerToCurrent.mulDivDown(1e18, ticksLowerToUpper);

            amountToSwap = targetRatio.mulDivDown(assets, 1e18);
            sqrtPriceLimitX96 = rangeInfo_.sqrtPriceX96Lower;
        } else if (currentTick < lastTick) {
            // Redeem from Vault
            uint256 assets = poolInfo[poolId].vaultToken1.redeem(narrow);

            // Rebalance amount received from Vault so that the ratio of the amounts to deposit matches with ratio of the ticks.
            uint256 ticksCurrentToUpper = uint256(uint24(rangeInfo_.tickUpper - currentTick));
            uint256 ticksLowerToUpper = uint256(uint24(rangeInfo_.tickUpper - rangeInfo_.tickLower));
            uint256 targetRatio = ticksCurrentToUpper.mulDivDown(1e18, ticksLowerToUpper);

            amountToSwap = targetRatio.mulDivDown(assets, 1e18);
            sqrtPriceLimitX96 = rangeInfo_.sqrtPriceX96Upper;
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountToSwap),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        // Swap tokens to target ratios
        poolManager.unlock(abi.encodeCall(this.swapPM, (poolInfo[poolId].poolKey, params)));

        uint128 liquidity;
        {
            // Deposit tokens in pool
            // Get liquidity for amounts
            Currency currency0 = poolInfo[poolId].poolKey.currency0;
            Currency currency1 = poolInfo[poolId].poolKey.currency1;

            uint256 token0Balance = ERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Balance = ERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, rangeInfo_.sqrtPriceX96Lower, rangeInfo_.sqrtPriceX96Upper, token0Balance, token1Balance
            );
        }

        // Add liquidity in pool for hook
        poolManager.unlock(abi.encodeCall(this.addLiquidityPM, (poolId, narrow, int256(int128(liquidity)), msg.sender)));
    }

    function _poolToVault(int24 currentTick, PoolId poolId, RangeInfo memory rangeInfo_, bool narrow) internal {
        // Remove liquidity from pool
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = abi.decode(
            poolManager.unlock(
                abi.encodeCall(
                    this.removeLiquidityPM,
                    (poolId, narrow, int256(int128(rangeInfo_.totalLiquidity)), address(this), false)
                )
            ),
            (BalanceDelta, BalanceDelta)
        );

        // Distribute the fees
        _distributeFees(poolId, narrow, feesAccrued.amount0(), feesAccrued.amount1());

        // Invest in Vault
        if (currentTick > lastTick) {
            // Fully in token1
            Vault vaultToken1 = poolInfo[poolId].vaultToken1;
            uint256 assetsToDeposit = uint256(uint128(callerDelta.amount1()));
            vaultToken1.asset().safeApprove(address(vaultToken1), assetsToDeposit);
            vaultToken1.deposit(assetsToDeposit, narrow);
        } else {
            // Fully in token0
            Vault vaultToken0 = poolInfo[poolId].vaultToken1;
            uint256 assetsToDeposit = uint256(uint128(callerDelta.amount0()));
            vaultToken0.asset().safeApprove(address(vaultToken0), assetsToDeposit);
            vaultToken0.deposit(assetsToDeposit, narrow);
        }
    }

    function swapPM(PoolKey memory key, IPoolManager.SwapParams memory params) external poolManagerOnly {
        BalanceDelta swapDelta = poolManager.swap(key, params, "");

        // Process deltas
        processBalanceDelta(address(this), address(this), key.currency0, key.currency1, swapDelta);
    }

    /* ///////////////////////////////////////////////////////////////
                ADDING AND REMOVING LIQUIDITY VIA HOOK
    /////////////////////////////////////////////////////////////// */

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
        if (rangeInfo_.active) {
            // Convert lp balance to liquidity amount
            // Get liquidity of position
            int256 liquidity = int256(lpAmount.mulDivDown(rangeInfo_.totalLiquidity, rangeInfo_.lpToken.totalSupply()));

            _withdrawLiquidityAndFees(rangeInfo_.lpToken, lpAmount, narrow, -liquidity, msg.sender, false, poolId);
        } else {
            // Get and distribute the fees
            _withdrawLiquidityAndFees(rangeInfo_.lpToken, lpAmount, narrow, 0, msg.sender, true, poolId);

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

        // Increase total liquidity for specific range
        rangeInfo[poolId][narrow].totalLiquidity += uint128(int128(liquidity));
    }

    function removeLiquidityPM(PoolId poolId, bool narrow, int256 liquidity, address sender, bool feesOnly)
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
            liquidityDelta: liquidity,
            salt: bytes32(uint256(uint160(address(this))))
        });

        // Call modifyLiquidity()
        (callerDelta, feesAccrued) = poolManager.modifyLiquidity(poolInfo[poolId].poolKey, params, "");

        // Process deltas
        if (!feesOnly) {
            processBalanceDelta(sender, sender, currency0, currency1, callerDelta);
            // Decrease total liquidity for specific range
            rangeInfo[poolId][narrow].totalLiquidity -= uint128(int128(-liquidity));
        }
        processBalanceDelta(address(this), address(this), currency0, currency1, feesAccrued);
    }

    function _withdrawLiquidityAndFees(
        LPToken lpToken,
        uint256 lpAmount,
        bool narrow,
        int256 liquidity,
        address receiver,
        bool feesOnly,
        PoolId poolId
    ) internal returns (BalanceDelta feesAccrued) {
        // Remove liquidity and/or fees
        (, feesAccrued) = abi.decode(
            poolManager.unlock(abi.encodeCall(this.removeLiquidityPM, (poolId, narrow, liquidity, receiver, feesOnly))),
            (BalanceDelta, BalanceDelta)
        );

        // Send part of the fees to caller and distribute the rest
        uint256 lpTotalSupply = lpToken.totalSupply();
        uint128 feesAccrued0 = uint128(feesAccrued.amount0());
        uint128 feesAccrued1 = uint128(feesAccrued.amount1());

        uint128 fees0ForCaller = uint128(lpAmount.mulDivDown(feesAccrued0, lpTotalSupply));
        uint128 fees1ForCaller = uint128(lpAmount.mulDivDown(feesAccrued1, lpTotalSupply));

        // Send fees to receiver
        Currency currency0 = poolInfo[poolId].poolKey.currency0;
        Currency currency1 = poolInfo[poolId].poolKey.currency1;

        ERC20(Currency.unwrap(currency0)).safeTransfer(receiver, fees0ForCaller);
        ERC20(Currency.unwrap(currency1)).safeTransfer(receiver, fees1ForCaller);

        // Distribute the remaining fees to the staking contract
        _distributeFees(poolId, narrow, int128(feesAccrued0 - fees0ForCaller), int128(feesAccrued1 - fees1ForCaller));
    }

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

    /* ///////////////////////////////////////////////////////////////
                        PROCESS BALANCE DELTA
    /////////////////////////////////////////////////////////////// */

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
