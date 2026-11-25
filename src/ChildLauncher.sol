// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IGenerativeNFTBurn {
    function ownerOf(uint256 tokenId) external view returns (address);
    function burnByLauncher(uint256 tokenId) external;
}

interface IHolderVaultRetire {
    function retired(uint256 tokenId) external view returns (bool);
    function vestingDone() external view returns (bool);
}

/// @notice Adapter for Programmable's launch contract on Ethereum.
/// TODO(decision): replace with Programmable's real interface once confirmed. The adapter must
/// launch the child token + pool for `creator` and route 20% of child-pool fees to the buyback wallet.
interface IChildFactory {
    function launchChild(address creator, bytes calldata params) external returns (address childToken);
}

/// @title ChildLauncher
/// @notice Burn a Generative NFT to launch a child token. One launch every 2 hours across everyone.
///         Child launches open only after the 7-day escrow vest is done.
///         Step 1, by the holder: HolderVault.retire(tokenId, recipient) pays out the NFT's fees and escrow.
///         Step 2, by the same holder: launchChild(tokenId, ...) burns it. This contract never decides a payout.
contract ChildLauncher is Ownable, ReentrancyGuard {
    uint256 public constant COOLDOWN = 2 hours;

    IGenerativeNFTBurn public immutable nft;
    IHolderVaultRetire public immutable vault;
    IChildFactory public factory;
    uint256 public lastLaunch;

    event ChildLaunched(uint256 indexed burnedTokenId, address indexed creator, address childToken);

    error FactoryNotSet();
    error FactoryAlreadySet();
    error NotTokenOwner();
    error VestingNotDone();
    error NotRetired();
    error CooldownActive(uint256 nextAllowed);

    constructor(IGenerativeNFTBurn _nft, IHolderVaultRetire _vault, address initialOwner) Ownable(initialOwner) {
        nft = _nft;
        vault = _vault;
    }

    function setFactory(IChildFactory _factory) external onlyOwner {
        if (address(factory) != address(0)) revert FactoryAlreadySet();
        factory = _factory;
    }

    function nextLaunchAt() public view returns (uint256) {
        return lastLaunch == 0 ? 0 : lastLaunch + COOLDOWN;
    }

    function launchChild(uint256 tokenId, bytes calldata params) external nonReentrant returns (address child) {
        if (address(factory) == address(0)) revert FactoryNotSet();
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!vault.vestingDone()) revert VestingNotDone();
        if (block.timestamp < nextLaunchAt()) revert CooldownActive(nextLaunchAt());

        if (!vault.retired(tokenId)) revert NotRetired(); // the holder retired it (and chose the payout) in the vault

        lastLaunch = block.timestamp;
        nft.burnByLauncher(tokenId);
        child = factory.launchChild(msg.sender, params);
        emit ChildLaunched(tokenId, msg.sender, child);
    }
}
