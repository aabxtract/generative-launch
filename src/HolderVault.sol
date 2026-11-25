// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

interface IGenerativeNFTOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IGenerativeTokenInfo {
    function holderVault() external view returns (address);
    function HOLDER_ESCROW() external view returns (uint256);
    function startedAt() external view returns (uint256);
}

/// @title HolderVault
/// @notice Holds the 0.3% holder fee (in ETH) and the 2% GENV escrow for the 281 Generative NFTs.
///         Everything is keyed by NFT token ID, so the rights follow the NFT when it is sold.
/// @dev    Fees arrive as fully backed native-ETH claims (ERC-6909 id 0) minted to this vault by the hook
///         inside each swap, and are paid out through PoolManager.unlock, the same pattern as Programmable's
///         AutomaticNativeFeeVaultV2. They are split across the live (unburned) NFTs.
///         Escrow: 71,174 GENV per NFT, minted here by the token at deploy, vesting linearly over 7 days from
///         the moment trading starts.
///         If every NFT has been retired (liveSupply == 0), the holder share of later trades is kept as
///         `residualFees` and can be sent by anyone, only to the fixed `residualRecipient` (the creator fee
///         wallet, set at deploy). Trades never revert because of it, and Programmable's 0.3% is not touched:
///         that is paid by the hook into Programmable's fee vault and never passes through this contract.
///         Retirement (before an NFT is burned for a child launch) is decided only by the NFT's current holder:
///         they call `retire` themselves and name the recipient of its ETH fees and vested GENV.
///         There is no owner and no admin: nobody can move fees or escrow, or retire someone else's NFT.
contract HolderVault is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_TOKENS = 281;
    uint256 public constant ESCROW_PER_TOKEN = 71_174e18;
    uint256 public constant VEST_DURATION = 7 days;
    uint256 private constant ACC = 1e36;

    IGenerativeNFTOwner public immutable nft;
    IPoolManager public immutable poolManager;
    /// @notice The launch's graph factory: the only caller allowed to bind the hook and token.
    address public immutable graphFactory;
    /// @notice Where the holder share goes once no NFT is left in the split (the creator fee wallet).
    address public immutable residualRecipient;

    address public hook;
    IERC20 public escrowToken;

    uint256 public liveSupply = MAX_TOKENS;
    uint256 public accPerNft; // accumulated ETH fee per NFT, scaled by ACC
    mapping(uint256 => uint256) public paidPerNft; // tokenId => accPerNft already paid
    uint256 public feeLiability; // ETH fees received and not yet paid out
    uint256 public totalFeesIn;
    uint256 public residualFees; // holder fees that arrived while liveSupply == 0, owed to residualRecipient
    mapping(uint256 => uint256) public escrowClaimed;
    mapping(uint256 => bool) public retired;

    bool private _payoutActive;
    bytes32 private _payout;

    event Bound(address hook, address token);
    event FeeIn(uint256 amount);
    event FeesClaimed(uint256 indexed tokenId, address indexed to, uint256 amount);
    event EscrowClaimed(uint256 indexed tokenId, address indexed to, uint256 amount);
    event Retired(uint256 indexed tokenId, address indexed to, uint256 fees, uint256 escrow);
    event ResidualFeeIn(uint256 amount);
    event ResidualSent(address indexed to, uint256 amount);

    error Unauthorized();
    error AlreadySet();
    error ZeroRecipient();
    error InvalidConfiguration();
    error NotTokenOwner(uint256 tokenId);
    error TokenRetired(uint256 tokenId);
    error BadTokenId(uint256 tokenId);
    error InsufficientFeeBacking();
    error VestingNotStarted();
    error VestingNotDone();
    error InvalidPayout();

    constructor(
        IGenerativeNFTOwner nft_,
        IPoolManager manager_,
        address graphFactory_,
        address residualRecipient_
    ) {
        if (
            address(nft_).code.length == 0 || address(manager_).code.length == 0 || graphFactory_ == address(0)
                || residualRecipient_ == address(0) || residualRecipient_ == address(this)
        ) revert InvalidConfiguration();
        nft = nft_;
        poolManager = manager_;
        graphFactory = graphFactory_;
        residualRecipient = residualRecipient_;
    }

    // ------------------------------------------------------------------ wiring
    /// @notice Run once by the graph factory in the launch transaction (hook and vault reference each other).
    function bind(address hook_, address token_) external {
        if (msg.sender != graphFactory) revert Unauthorized();
        if (hook != address(0)) revert AlreadySet();
        if (
            hook_.code.length == 0 || IGenerativeTokenInfo(token_).holderVault() != address(this)
                || IGenerativeTokenInfo(token_).HOLDER_ESCROW() != ESCROW_PER_TOKEN * MAX_TOKENS
                || IERC20(token_).balanceOf(address(this)) != ESCROW_PER_TOKEN * MAX_TOKENS
        ) revert InvalidConfiguration();
        hook = hook_;
        escrowToken = IERC20(token_);
        emit Bound(hook_, token_);
    }

    // ------------------------------------------------------------------ fees in
    /// @notice Called by the hook after it minted `amount` of native-ETH claims to this vault.
    function notifyFee(uint256 amount) external {
        if (msg.sender != hook) revert Unauthorized();
        if (amount == 0) return;
        feeLiability += amount;
        totalFeesIn += amount;
        if (liveSupply == 0) {
            // No NFT left to share it: hold it for the residual recipient. Nothing is paid out inside the swap.
            residualFees += amount;
            emit ResidualFeeIn(amount);
        } else {
            accPerNft += amount * ACC / liveSupply;
            emit FeeIn(amount);
        }
        _requireBacking();
    }

    /// @notice Sends the holder fees that arrived after the last NFT retired to `residualRecipient`.
    ///         Anyone can call it; the destination is fixed at deploy.
    function sendResidual() external nonReentrant {
        uint256 amount = residualFees;
        if (amount == 0) return;
        residualFees = 0;
        _payNative(residualRecipient, amount);
        emit ResidualSent(residualRecipient, amount);
    }

    // ------------------------------------------------------------------ claims
    /// @notice Claim fees for NFTs you hold. Paid to you in ETH.
    function claimFees(uint256[] calldata tokenIds) external nonReentrant {
        uint256 total;
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (_checkLive(id) != msg.sender) revert NotTokenOwner(id);
            uint256 amt = _settleFees(id);
            total += amt;
            emit FeesClaimed(id, msg.sender, amt);
        }
        _payNative(msg.sender, total);
    }

    /// @notice Anyone can trigger, but each NFT's fees always go to its current owner.
    function claimFeesFor(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            address owner_ = _checkLive(id);
            uint256 amt = _settleFees(id);
            emit FeesClaimed(id, owner_, amt);
            _payNative(owner_, amt);
        }
    }

    function claimEscrow(uint256[] calldata tokenIds) external nonReentrant {
        if (vestStart() == 0) revert VestingNotStarted();
        uint256 total;
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (_checkLive(id) != msg.sender) revert NotTokenOwner(id);
            uint256 amt = _settleEscrow(id);
            total += amt;
            emit EscrowClaimed(id, msg.sender, amt);
        }
        if (total > 0) escrowToken.safeTransfer(msg.sender, total);
    }

    /// @notice Same as claimEscrow, triggered by anyone, always paid to each NFT's current owner.
    function claimEscrowFor(uint256[] calldata tokenIds) external nonReentrant {
        if (vestStart() == 0) revert VestingNotStarted();
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            address owner_ = _checkLive(id);
            uint256 amt = _settleEscrow(id);
            if (amt > 0) escrowToken.safeTransfer(owner_, amt);
            emit EscrowClaimed(id, owner_, amt);
        }
    }

    /// @notice Retire an NFT you hold, before burning it for a child launch: pays everything it is owed (ETH fees
    ///         and the fully vested GENV) to `to`, a recipient you choose, and removes it from the fee split for good.
    ///         Only the NFT's current holder can call it, and only once the 7-day escrow has fully vested.
    ///         The child launcher only accepts NFTs their holder has retired here.
    function retire(uint256 tokenId, address to) external nonReentrant {
        if (_checkLive(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if (to == address(0)) revert ZeroRecipient();
        if (!vestingDone()) revert VestingNotDone();
        uint256 fees = _settleFees(tokenId);
        uint256 esc = _settleEscrow(tokenId);
        retired[tokenId] = true;
        liveSupply -= 1;
        _payNative(to, fees);
        // The last NFT is out: every NFT has been paid in full, so what is still held is only rounding dust
        // from the per-NFT split. It joins the residual so nothing is stranded.
        if (liveSupply == 0) residualFees = feeLiability;
        if (esc > 0) escrowToken.safeTransfer(to, esc);
        emit Retired(tokenId, to, fees, esc);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_payoutActive || keccak256(data) != _payout) revert InvalidPayout();
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        _payout = bytes32(0);
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), to, amount);
        return "";
    }

    // ------------------------------------------------------------------ views
    function pendingFees(uint256 tokenId) public view returns (uint256) {
        if (retired[tokenId]) return 0;
        return (accPerNft - paidPerNft[tokenId]) / ACC;
    }

    /// @notice When trading started (the token's atomic start); 0 before launch.
    function vestStart() public view returns (uint256) {
        if (address(escrowToken) == address(0)) return 0;
        return IGenerativeTokenInfo(address(escrowToken)).startedAt();
    }

    function vestedEscrow(uint256 tokenId) public view returns (uint256) {
        uint256 start = vestStart();
        if (start == 0 || retired[tokenId]) return 0;
        uint256 elapsed = block.timestamp - start;
        if (elapsed > VEST_DURATION) elapsed = VEST_DURATION;
        return ESCROW_PER_TOKEN * elapsed / VEST_DURATION;
    }

    function claimableEscrow(uint256 tokenId) external view returns (uint256) {
        uint256 v = vestedEscrow(tokenId);
        return v > escrowClaimed[tokenId] ? v - escrowClaimed[tokenId] : 0;
    }

    function vestingDone() public view returns (bool) {
        uint256 start = vestStart();
        return start != 0 && block.timestamp >= start + VEST_DURATION;
    }

    // ------------------------------------------------------------------ internal
    function _checkLive(uint256 id) internal view returns (address owner_) {
        if (id == 0 || id > MAX_TOKENS) revert BadTokenId(id);
        if (retired[id]) revert TokenRetired(id);
        owner_ = nft.ownerOf(id);
    }

    function _settleFees(uint256 id) internal returns (uint256 amt) {
        amt = pendingFees(id);
        paidPerNft[id] = accPerNft;
    }

    function _settleEscrow(uint256 id) internal returns (uint256 amt) {
        uint256 v = vestedEscrow(id);
        amt = v - escrowClaimed[id];
        escrowClaimed[id] = v;
    }

    function _payNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        feeLiability -= amount;
        bytes memory data = abi.encode(to, amount);
        _payout = keccak256(data);
        _payoutActive = true;
        bytes memory result = poolManager.unlock(data);
        if (result.length != 0 || _payout != bytes32(0)) revert InvalidPayout();
        _payoutActive = false;
        _requireBacking();
    }

    function _requireBacking() internal view {
        if (poolManager.balanceOf(address(this), 0) < feeLiability) revert InsufficientFeeBacking();
    }
}
