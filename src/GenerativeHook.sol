// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { ProtectedLaunchTokenV1 } from "./programmable/launch-protection/ProtectedLaunchTokenV1.sol";
import { AutomaticLaunchProtectionModuleV2 } from "./programmable/automatic-platform-fees-v2/AutomaticLaunchProtectionModuleV2.sol";
import { AutomaticNativeFeeVaultV2 } from "./programmable/automatic-platform-fees-v2/AutomaticNativeFeeVaultV2.sol";

interface IGenerativeHolderVault {
    function notifyFee(uint256 amount) external;
}

interface IGenerativeTokenVault {
    function holderVault() external view returns (address);
}

/// @title GenerativeHook
/// @notice The GENV/ETH pool's hook. On every buy and sell it takes, on the gross native-ETH leg:
///           0.30% for Programmable  (pushed automatically as ETH to Programmable's team wallet)
///           4.00% creator fee        (claimable by the fixed creator wallet)
///           0.30% for NFT holders    (sent to HolderVault, split across the 281 NFTs)
///         = 4.60% in total, rounded up per trade. During the first 30 seconds after launch a buy also pays
///         Programmable's opening anti-sniper tax, which decays from 99% total to normal.
/// @dev    Programmable's AutomaticProtectedNative30HookV2 (programmablehq/PROGRAMMABLE @2e09593), unchanged
///         except for the holders' share: it is computed on the same gross basis, rounded down (so the
///         platform's rounded-up 0.3% is never reduced), minted as backed native claims to HolderVault, and
///         HolderVault is told the amount. The creator ledger and Programmable's payout use their unmodified
///         AutomaticNativeFeeVaultV2. Fee rates are constants or immutable; there is no owner.
///         Only the exact bound PoolKey is covered. ETH-specified partial fills revert.
///         The shell has no swap, unlock-forwarding, delegatecall, arbitrary-call or privileged path.
contract GenerativeHook is BaseHook {
    uint256 public constant POLICY_REVISION = 3;
    using SafeCast for uint256;
    using SafeCast for int256;
    using LPFeeLibrary for uint24;

    uint256 public immutable CHAIN_ID;
    address public immutable CANONICAL_POOL_MANAGER;
    address public immutable OPENING_TAX_RECIPIENT;
    address public immutable PLATFORM_RECIPIENT;
    address public immutable platformFeeRouter;
    bytes32 public immutable platformFeeRouterCodeHash;
    uint16 public constant PLATFORM_FEE_BPS = 30;
    uint16 public constant HOLDER_FEE_BPS = 30;
    uint16 public constant FEE_DENOMINATOR = 10_000;
    bytes32 public constant FEE_PROFILE = keccak256("programmable.protected-native-fee.v1.gross-native.ceil-per-trade");

    struct PoolConfig {
        address token;
        uint24 lpFee;
        int24 tickSpacing;
        uint160 initialSqrtPriceX96;
        address initializer;
        address creatorFeeRecipient;
        uint16 creatorBuyFeeBps;
        uint16 creatorSellFeeBps;
        address module;
        uint24 maxModuleLpFeePips;
    }

    address public immutable token;
    uint24 public immutable lpFee;
    int24 public immutable tickSpacing;
    uint160 public immutable initialSqrtPriceX96;
    address public immutable initializer;
    uint16 public immutable creatorBuyFeeBps;
    uint16 public immutable creatorSellFeeBps;
    address public immutable module;
    bytes32 public immutable moduleCodeHash;
    uint24 public immutable maxModuleLpFeePips;
    AutomaticNativeFeeVaultV2 public immutable feeVault;
    AutomaticNativeFeeVaultV2 public immutable openingTaxVault;
    address public immutable holderVault;
    uint24 private activeOpeningTaxPpm;
    address private activeBuyer;
    mapping(address => uint256) public boughtDuringProtection;
    bool public initialized;
    bool private swapActive;
    bytes32 private activeSwap;
    uint256 private expectedNativePoolAmount;

    error InvalidConfiguration();
    error UnexpectedPool();
    error UnauthorizedInitializer();
    error UninitializedPool();
    error ReentrantSwap();
    error InvalidSwapContext();
    error PartialFillUnsupported(uint256 expected, uint256 actual);
    error UnsupportedCustomDelta();
    error InvalidModuleResponse();
    error ModuleCodeChanged();
    error InvalidDynamicFeeOverride();
    error NoTrade();
    error BuyerLimitExceeded(address buyer, uint256 attempted, uint256 limit);

    event NativeFeesAccrued(
        bytes32 indexed poolId,
        address indexed sender,
        bool isBuy,
        uint256 grossNative,
        uint256 platformFee,
        uint256 creatorFee
    );

    event OpeningTaxAccrued(bytes32 indexed poolId, address indexed sender, uint256 grossNative, uint256 amount);

    event HolderFeesAccrued(bytes32 indexed poolId, address indexed sender, bool isBuy, uint256 grossNative, uint256 amount);

    constructor(
        IPoolManager manager,
        PoolConfig memory config,
        address developer,
        address router,
        bytes32 routerCodeHash,
        address[6] memory exemptWallets,
        address platformFeeRouter_,
        bytes32 platformFeeRouterCodeHash_,
        address holderVault_
    ) BaseHook(manager) {
        CHAIN_ID = block.chainid;
        CANONICAL_POOL_MANAGER = block.chainid == 1
            ? 0x000000000004444c5dc75cB358380D2e3dE08A90
            : block.chainid == 4663
                ? 0x8366a39CC670B4001A1121B8F6A443A643e40951
                : block.chainid == 8453
                    ? 0x498581fF718922c3f8e6A244956aF099B2652b2b
                    : block.chainid == 999
                        ? 0x12D4Fd9C5DeDd00ab8a0bCe2CF0167bbf94b6B1F
                        : block.chainid == 99_901 ? 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1 : address(0);
        if (
            CANONICAL_POOL_MANAGER == address(0) || address(manager) != CANONICAL_POOL_MANAGER
                || address(manager).code.length == 0 || config.lpFee != 0 || config.tickSpacing != 60
                || config.module != address(0) || config.creatorBuyFeeBps > 1000 || config.creatorSellFeeBps > 1000
                || config.token == address(0) || config.initializer == address(0)
                || config.creatorFeeRecipient == address(0) || config.initialSqrtPriceX96 == 0
                || config.tickSpacing <= 0 || config.maxModuleLpFeePips != 0
                || uint256(config.creatorBuyFeeBps) + PLATFORM_FEE_BPS + HOLDER_FEE_BPS >= FEE_DENOMINATOR
                || uint256(config.creatorSellFeeBps) + PLATFORM_FEE_BPS + HOLDER_FEE_BPS >= FEE_DENOMINATOR
                || holderVault_ == address(0) || holderVault_.code.length == 0
                || holderVault_ == config.creatorFeeRecipient
        ) revert InvalidConfiguration();
        config.lpFee.getInitialLPFee();
        if (
            ProtectedLaunchTokenV1(config.token).initializer() != config.initializer
                || ProtectedLaunchTokenV1(config.token).poolManager() != address(manager)
                || IGenerativeTokenVault(config.token).holderVault() != holderVault_
        ) {
            revert InvalidConfiguration();
        }
        token = config.token;
        lpFee = config.lpFee;
        tickSpacing = config.tickSpacing;
        initialSqrtPriceX96 = config.initialSqrtPriceX96;
        initializer = config.initializer;
        creatorBuyFeeBps = config.creatorBuyFeeBps;
        creatorSellFeeBps = config.creatorSellFeeBps;
        holderVault = holderVault_;
        // Keep the normal fee vault as CREATE child 1 for canonical native-fee proof compatibility.
        feeVault = new AutomaticNativeFeeVaultV2(
            manager, config.creatorFeeRecipient, platformFeeRouter_, platformFeeRouterCodeHash_
        );
        platformFeeRouter = feeVault.PLATFORM_RECIPIENT();
        PLATFORM_RECIPIENT = platformFeeRouter;
        platformFeeRouterCodeHash = platformFeeRouterCodeHash_;
        OPENING_TAX_RECIPIENT = platformFeeRouter;
        // The module's "creator" buy rate is our whole project buy fee (creator + holders), so the opening
        // total starts at exactly 99% and decays to the normal 4.6%.
        address protection = address(
            new AutomaticLaunchProtectionModuleV2(
                address(this),
                ProtectedLaunchTokenV1(config.token),
                developer,
                router,
                routerCodeHash,
                config.creatorBuyFeeBps + HOLDER_FEE_BPS,
                exemptWallets
            )
        );
        module = protection;
        moduleCodeHash = protection.codehash;
        maxModuleLpFeePips = 0;
        openingTaxVault = new AutomaticNativeFeeVaultV2(
            manager, feeVault.TEAM_WALLET(), platformFeeRouter_, platformFeeRouterCodeHash_
        );
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), lpFee, tickSpacing, IHooks(address(this)));
    }

    /// @notice Gross native trade value and fee allocations in wei (reference signature).
    /// @dev `creatorFee` here is the whole project fee (creator + holders); `quoteFeeSplit` separates them.
    ///      Neither can reduce the platform's independent ceil(gross * 30 / 10000).
    function quoteFees(uint256 amount, bool amountIsNet, bool isBuy)
        public
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee)
    {
        uint256 holderFee;
        (gross, platformFee, creatorFee, holderFee,) = _quoteTradeFees(amount, amountIsNet, isBuy, 0);
        creatorFee += holderFee;
    }

    /// @notice Gross value with the creator and holder shares separated, outside the opening window.
    function quoteFeeSplit(uint256 amount, bool amountIsNet, bool isBuy)
        external
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 holderFee)
    {
        (gross, platformFee, creatorFee, holderFee,) = _quoteTradeFees(amount, amountIsNet, isBuy, 0);
    }

    function previewTradeFees(uint256 amount, bool amountIsNet, bool isBuy, address buyer)
        external
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 openingTax)
    {
        uint24 taxPpm = isBuy ? AutomaticLaunchProtectionModuleV2(module).additionalTaxPpmForBuyer(buyer) : 0;
        uint256 holderFee;
        (gross, platformFee, creatorFee, holderFee, openingTax) = _quoteTradeFees(amount, amountIsNet, isBuy, taxPpm);
        creatorFee += holderFee;
    }

    function _quoteTradeFees(uint256 amount, bool amountIsNet, bool isBuy, uint24 taxPpm)
        private
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 holderFee, uint256 openingTax)
    {
        uint256 normalPpm =
            (PLATFORM_FEE_BPS + HOLDER_FEE_BPS + uint256(isBuy ? creatorBuyFeeBps : creatorSellFeeBps)) * 100;
        uint256 totalPpm = normalPpm + taxPpm;
        if (totalPpm >= 1_000_000) revert InvalidConfiguration();
        gross = amountIsNet ? Math.mulDiv(amount, 1_000_000, 1_000_000 - totalPpm, Math.Rounding.Ceil) : amount;
        uint256 totalFee = amountIsNet ? gross - amount : Math.mulDiv(gross, totalPpm, 1_000_000, Math.Rounding.Ceil);
        uint256 normalFee = Math.mulDiv(gross, normalPpm, 1_000_000, Math.Rounding.Ceil);
        platformFee = Math.mulDiv(gross, PLATFORM_FEE_BPS, FEE_DENOMINATOR, Math.Rounding.Ceil);
        // Rounded down: ceil(platform) + floor(holders) <= ceil(normal), so the creator share never underflows.
        holderFee = Math.mulDiv(gross, HOLDER_FEE_BPS, FEE_DENOMINATOR);
        creatorFee = normalFee - platformFee - holderFee;
        openingTax = totalFee - normalFee;
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 price) internal override returns (bytes4) {
        _requirePool(key);
        if (initialized || sender != initializer || price != initialSqrtPriceX96) revert UnauthorizedInitializer();
        initialized = true;
        return IHooks.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24 overrideFee)
    {
        _requirePool(key);
        if (!initialized) revert UninitializedPool();
        if (swapActive) revert ReentrantSwap();
        if (params.amountSpecified == 0) revert NoTrade();
        swapActive = true;
        activeSwap = keccak256(abi.encode(sender, key, params, data));
        overrideFee = _beforeModule(sender, key, params, data);
        if (params.zeroForOne && block.timestamp < ProtectedLaunchTokenV1(token).startedAt() + 300) {
            activeBuyer = AutomaticLaunchProtectionModuleV2(module).protectedBuyer(sender);
        }
        activeOpeningTaxPpm =
            params.zeroForOne ? AutomaticLaunchProtectionModuleV2(module).openingTaxPpmForSender(sender) : 0;
        bool nativeIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        if (!nativeIsSpecified) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
        uint256 nativeAmount = _absolute(params.amountSpecified);
        (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 holderFee, uint256 openingTax) =
            _quoteTradeFees(nativeAmount, params.amountSpecified > 0, params.zeroForOne, activeOpeningTaxPpm);
        uint256 total = platformFee + creatorFee + holderFee + openingTax;
        if (params.amountSpecified < 0 && total >= nativeAmount) revert NoTrade();
        expectedNativePoolAmount = params.amountSpecified > 0 ? gross : nativeAmount - total;
        if (expectedNativePoolAmount == 0) revert NoTrade();
        _accrue(sender, key, params.zeroForOne, gross, platformFee, creatorFee, holderFee, openingTax);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(total.toInt256().toInt128(), 0), overrideFee);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) internal override returns (bytes4, int128) {
        _requirePool(key);
        if (!swapActive || activeSwap != keccak256(abi.encode(sender, key, params, data))) revert InvalidSwapContext();
        uint256 nativeAmount = _absolute(int256(delta.amount0()));
        if (nativeAmount == 0 || delta.amount1() == 0) revert NoTrade();
        bool nativeIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        uint256 total;
        if (nativeIsSpecified) {
            if (nativeAmount != expectedNativePoolAmount) {
                revert PartialFillUnsupported(expectedNativePoolAmount, nativeAmount);
            }
        } else {
            (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 holderFee, uint256 openingTax) =
                _quoteTradeFees(nativeAmount, params.amountSpecified > 0, params.zeroForOne, activeOpeningTaxPpm);
            total = platformFee + creatorFee + holderFee + openingTax;
            if (params.amountSpecified < 0 && total >= nativeAmount) revert NoTrade();
            _accrue(sender, key, params.zeroForOne, gross, platformFee, creatorFee, holderFee, openingTax);
        }
        if (activeBuyer != address(0)) {
            if (delta.amount1() <= 0) revert NoTrade();
            uint256 bought = boughtDuringProtection[activeBuyer] + uint256(uint128(delta.amount1()));
            uint256 limit = ProtectedLaunchTokenV1(token).walletTokenLimit();
            if (bought > limit) revert BuyerLimitExceeded(activeBuyer, bought, limit);
            boughtDuringProtection[activeBuyer] = bought;
            activeBuyer = address(0);
        }
        _afterModule(sender, key, params, delta, data);
        expectedNativePoolAmount = 0;
        activeSwap = bytes32(0);
        activeOpeningTaxPpm = 0;
        swapActive = false;
        return (IHooks.afterSwap.selector, total.toInt256().toInt128());
    }

    function _beforeModule(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        private
        view
        returns (uint24 overrideFee)
    {
        if (module == address(0)) return 0;
        _requireModuleCode();
        (bytes4 selector, BeforeSwapDelta customDelta, uint24 fee) =
            AutomaticLaunchProtectionModuleV2(module).beforeSwap(sender, key, params, data);
        if (selector != AutomaticLaunchProtectionModuleV2.beforeSwap.selector) revert InvalidModuleResponse();
        if (BeforeSwapDelta.unwrap(customDelta) != 0) revert UnsupportedCustomDelta();
        if (fee != 0) {
            if (!lpFee.isDynamicFee() || !fee.isOverride()) revert InvalidDynamicFeeOverride();
            if (fee.removeOverrideFlagAndValidate() > maxModuleLpFeePips) revert InvalidDynamicFeeOverride();
        }
        return fee;
    }

    function _afterModule(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) private view {
        if (module == address(0)) return;
        _requireModuleCode();
        (bytes4 selector, int128 customDelta) =
            AutomaticLaunchProtectionModuleV2(module).afterSwap(sender, key, params, delta, data);
        if (selector != AutomaticLaunchProtectionModuleV2.afterSwap.selector) revert InvalidModuleResponse();
        if (customDelta != 0) revert UnsupportedCustomDelta();
    }

    function _requireModuleCode() private view {
        if (module.codehash != moduleCodeHash) revert ModuleCodeChanged();
    }

    function _requirePool(PoolKey calldata key) private view {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != token || key.fee != lpFee
                || key.tickSpacing != tickSpacing || address(key.hooks) != address(this)
        ) revert UnexpectedPool();
    }

    function _accrue(
        address sender,
        PoolKey calldata key,
        bool isBuy,
        uint256 gross,
        uint256 platformFee,
        uint256 creatorFee,
        uint256 holderFee,
        uint256 openingTax
    ) private {
        bytes32 id = keccak256(abi.encode(key));
        uint256 total = platformFee + creatorFee;
        total.toInt256().toInt128();
        poolManager.mint(address(feeVault), 0, total);
        feeVault.recordFees(platformFee, creatorFee);
        emit NativeFeesAccrued(id, sender, isBuy, gross, platformFee, creatorFee);
        if (holderFee != 0) {
            holderFee.toInt256().toInt128();
            poolManager.mint(holderVault, 0, holderFee);
            IGenerativeHolderVault(holderVault).notifyFee(holderFee);
            emit HolderFeesAccrued(id, sender, isBuy, gross, holderFee);
        }
        if (openingTax != 0) {
            openingTax.toInt256().toInt128();
            poolManager.mint(address(openingTaxVault), 0, openingTax);
            openingTaxVault.recordFees(openingTax, 0);
            emit OpeningTaxAccrued(id, sender, gross, openingTax);
        }
    }

    function _absolute(int256 amount) private pure returns (uint256) {
        if (amount == type(int256).min) revert InvalidConfiguration();
        return uint256(amount < 0 ? -amount : amount);
    }
}
