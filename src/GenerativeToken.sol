// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title GenerativeToken ($GENV)
/// @notice Fixed 1,000,000,000 supply, no mint after deploy, no owner.
///         At deploy: the holders' 2% (281 x 71,174 GENV) is minted to HolderVault and the rest to the
///         launch initializer, which seeds it as permanently locked liquidity.
/// @dev    Follows Programmable's ProtectedLaunchTokenV1 (same getters, so their launch protection module
///         works with it): nothing moves before the atomic start except the initializer's seed into the
///         PoolManager, and for the first five minutes each wallet can receive at most 2% of the supply
///         in total. Selling, burning or forwarding doesn't refill that budget. No wallet is whitelisted.
contract GenerativeToken is ERC20 {
    uint256 public constant POLICY_REVISION = 2;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant HOLDER_ESCROW = 281 * 71_174e18; // 19,999,894 GENV for the 281 NFTs
    uint256 public constant WALLET_LIMIT_BPS = 200;
    uint256 public constant PROTECTION_SECONDS = 300;

    address public immutable initializer;
    address public immutable poolManager;
    address public immutable holderVault;
    /// @notice Total supply; the opening valuation is computed on it.
    uint256 public immutable launchSupply;
    /// @notice The part minted to the initializer to seed the pool.
    uint256 public immutable seedSupply;
    uint256 public immutable walletTokenLimit;
    uint256 public startedAt;
    mapping(address => uint256) public receivedDuringProtection;

    error InvalidConfiguration();
    error NotInitializer();
    error AlreadyStarted();
    error TradingNotStarted();
    error WalletLimitExceeded(address recipient, uint256 attempted, uint256 limit);

    constructor(address initializer_, address manager_, address holderVault_) ERC20("Generative", "GENV") {
        if (
            initializer_ == address(0) || manager_.code.length == 0 || initializer_ == manager_
                || holderVault_ == address(0) || holderVault_ == initializer_ || holderVault_ == manager_
        ) revert InvalidConfiguration();
        initializer = initializer_;
        poolManager = manager_;
        holderVault = holderVault_;
        launchSupply = TOTAL_SUPPLY;
        seedSupply = TOTAL_SUPPLY - HOLDER_ESCROW;
        walletTokenLimit = TOTAL_SUPPLY * WALLET_LIMIT_BPS / 10_000;
        _mint(holderVault_, HOLDER_ESCROW);
        _mint(initializer_, TOTAL_SUPPLY - HOLDER_ESCROW);
    }

    /// @notice Called once by the initializer in the launch transaction, after the pool is seeded.
    function start() external {
        if (msg.sender != initializer) revert NotInitializer();
        if (startedAt != 0) revert AlreadyStarted();
        if (block.timestamp == 0) revert InvalidConfiguration();
        startedAt = block.timestamp;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && amount != 0) {
            if (startedAt == 0) {
                // Only the seed settlement may move tokens before the atomic start.
                if (from != initializer || to != poolManager) revert TradingNotStarted();
            } else if (block.timestamp < startedAt + PROTECTION_SECONDS && to != poolManager) {
                // Self-transfers cannot create headroom, and don't consume it either.
                if (from != to) {
                    uint256 received = receivedDuringProtection[to] + amount;
                    if (received > walletTokenLimit) revert WalletLimitExceeded(to, received, walletTokenLimit);
                    receivedDuringProtection[to] = received;
                }
            }
        }
        super._update(from, to, amount);
    }
}
