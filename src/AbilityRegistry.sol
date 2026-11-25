// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title AbilityRegistry (v1 scaffold)
/// @notice Records which pool abilities are active. The owner must be a TimelockController,
///         so every change the keeper agent proposes is delayed and visible before it applies.
/// TODO(decision): ability NFTs (separate collection vs traits of the 281), crafting, merging,
/// staking and the season 1-2 ability list. This scaffold only fixes the interface the hook will read.
contract AbilityRegistry is Ownable {
    mapping(uint256 => bool) public isActive;

    event AbilitySet(uint256 indexed abilityId, bool active);

    constructor(address timelock) Ownable(timelock) {}

    function setAbility(uint256 abilityId, bool active) external onlyOwner {
        isActive[abilityId] = active;
        emit AbilitySet(abilityId, active);
    }
}
