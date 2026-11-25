// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { GenerativeHook } from "../src/GenerativeHook.sol";

/// LOCAL MAINNET FORK ONLY. Some buys and sells through a test router once the 5-minute protection window has
/// passed (before that only Programmable's own trade router may buy). Env: HOOK, PRIVATE_KEY.
contract LocalTrades is Script {
    address constant PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        GenerativeHook hook = GenerativeHook(vm.envAddress("HOOK"));
        PoolKey memory key = hook.poolKey();
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });

        vm.startBroadcast(pk);
        PoolSwapTest swapper = new PoolSwapTest(IPoolManager(PM));
        token.approve(address(swapper), type(uint256).max);
        for (uint256 i; i < 4; ++i) {
            swapper.swap{ value: 0.5 ether }(
                key, SwapParams(true, -0.5 ether, TickMath.MIN_SQRT_PRICE + 1), st, ""
            );
            uint256 bal = token.balanceOf(vm.addr(pk));
            swapper.swap(key, SwapParams(false, -int256(bal / 3), TickMath.MAX_SQRT_PRICE - 1), st, "");
        }
        vm.stopBroadcast();
        console2.log("SWAP_ROUTER=%s", address(swapper));
    }
}
