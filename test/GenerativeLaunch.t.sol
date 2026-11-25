// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { GenerativeToken } from "../src/GenerativeToken.sol";
import { GenerativeHook } from "../src/GenerativeHook.sol";
import { GenerativeInitializer, ILaunchUsdFeedV1, IGenerativeLaunchHook, IGenerativeLaunchToken } from
    "../src/GenerativeInitializer.sol";
import { HolderVault, IGenerativeNFTOwner } from "../src/HolderVault.sol";
import { ChildLauncher, IGenerativeNFTBurn, IHolderVaultRetire, IChildFactory } from "../src/ChildLauncher.sol";
import { AutomaticNativeFeeVaultV2 } from "../src/programmable/automatic-platform-fees-v2/AutomaticNativeFeeVaultV2.sol";
import { AutomaticLaunchProtectionModuleV2 } from
    "../src/programmable/automatic-platform-fees-v2/AutomaticLaunchProtectionModuleV2.sol";

/// Stand-in for the 281-piece NFT (the real one is SeaDrop, built with solc 0.8.17).
contract MockGenNFT is ERC721 {
    address public launcher;
    constructor() ERC721("Generative", "GEN") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
    function setLauncher(address l) external { launcher = l; }
    function burnByLauncher(uint256 id) external {
        require(msg.sender == launcher, "not launcher");
        _burn(id);
    }
}

contract MockChildFactory is IChildFactory {
    function launchChild(address, bytes calldata) external returns (address) { return address(0xC41D); }
}

/// Runs on a mainnet fork: real PoolManager, Chainlink ETH/USD, Programmable's trade router and team wallet.
/// This test contract plays Programmable's Graph Factory (deploys the graph and calls the initializers).
///   forge test --match-path test/GenerativeLaunch.t.sol            (FORK_RPC_URL overrides the public RPC)
contract GenerativeLaunchTest is Test {
    address constant PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant TRADE_ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    address constant TEAM_WALLET = 0x9F5856A3578Faba96A6E8Dfd9C10563A1E598f62;
    int24 constant START_TICK = 177_240; // about 20 ETH fully diluted at open
    uint256 constant INITIAL_BUY = 0.05 ether;

    address creator = makeAddr("creatorWallet");
    address developer = makeAddr("developer");
    address teamOwner = makeAddr("teamOwner");
    address alice = makeAddr("alice"); // holds NFTs 1-3
    address bob = makeAddr("bob"); // holds NFT 4

    MockGenNFT nft;
    HolderVault vault;
    GenerativeInitializer init;
    GenerativeToken token;
    GenerativeHook hook;
    PoolSwapTest swapper;
    PoolKey key;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FORK_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        // Some test addresses exist on mainnet with delegated code; make them plain wallets here.
        address[5] memory people = [creator, developer, teamOwner, alice, bob];
        for (uint256 i; i < people.length; ++i) vm.etch(people[i], "");
        nft = new MockGenNFT();
        for (uint256 i = 1; i <= 281; ++i) nft.mint(i <= 3 ? alice : i == 4 ? bob : address(uint160(0x1000 + i)), i);

        // Graph, in constructor-dependency order
        vault = new HolderVault(IGenerativeNFTOwner(address(nft)), IPoolManager(PM), address(this), creator);
        init = new GenerativeInitializer(IPoolManager(PM), address(this), ILaunchUsdFeedV1(FEED), FEED.codehash);
        token = new GenerativeToken(address(init), PM, address(vault));
        hook = _deployHook();

        // Initializers, as the graph factory runs them
        vault.bind(address(hook), address(token));
        vm.deal(address(this), 100 ether);
        init.initialize{ value: INITIAL_BUY }(
            IGenerativeLaunchHook(address(hook)), IGenerativeLaunchToken(address(token)), START_TICK, developer, 1
        );

        key = hook.poolKey();
        swapper = new PoolSwapTest(IPoolManager(PM));
    }

    function _deployHook() internal returns (GenerativeHook h) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address target = address(uint160(0x4444 << 144) | flags);
        GenerativeHook.PoolConfig memory cfg = GenerativeHook.PoolConfig({
            token: address(token),
            lpFee: 0,
            tickSpacing: 60,
            initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(START_TICK),
            initializer: address(init),
            creatorFeeRecipient: creator,
            creatorBuyFeeBps: 400,
            creatorSellFeeBps: 400,
            module: address(0),
            maxModuleLpFeePips: 0
        });
        address[6] memory exempt;
        bytes memory args = abi.encode(
            IPoolManager(PM), cfg, developer, TRADE_ROUTER, TRADE_ROUTER.codehash, exempt, address(0), bytes32(0), address(vault)
        );
        deployCodeTo("GenerativeHook.sol:GenerativeHook", args, target);
        h = GenerativeHook(target);
    }

    function _buy(uint256 ethIn) internal returns (uint256 tokensOut) {
        uint256 before = token.balanceOf(address(this));
        swapper.swap{ value: ethIn }(
            key,
            SwapParams({ zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        tokensOut = token.balanceOf(address(this)) - before;
    }

    function _sell(uint256 tokensIn) internal returns (uint256 ethOut) {
        token.approve(address(swapper), tokensIn);
        uint256 before = address(this).balance;
        swapper.swap(
            key,
            SwapParams({ zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        ethOut = address(this).balance - before;
    }

    receive() external payable {}

    // ------------------------------------------------------------------ launch

    function test_launch_seedsLockedLiquidityAndInitialBuy() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(vault)), 281 * 71_174e18, "holders' 2% in the vault");
        assertGt(token.balanceOf(developer), 0, "developer got the initial buy");
        assertLe(token.balanceOf(developer), token.walletTokenLimit());
        assertGt(token.startedAt(), 0);
        assertTrue(init.initialized());
        assertGt(init.lockedLiquidity(), 0);
        assertGe(init.openingFdvUsd(), 15_000);
        assertTrue(hook.initialized());
    }

    function test_launch_initialBuyPaysAllFees() public view {
        // 0.05 ETH gross: Programmable ceil(0.3%), holders floor(0.3%), creator the rest of ceil(4.6%)
        AutomaticNativeFeeVaultV2 fv = hook.feeVault();
        assertEq(fv.totalPlatformPaid(), 150_000_000_000_000, "0.3% pushed to Programmable");
        assertEq(fv.creatorAccrued(), 2_000_000_000_000_000, "4% creator");
        assertEq(vault.totalFeesIn(), 150_000_000_000_000, "0.3% holders");
    }

    function test_graph_cannotBeRunTwice() public {
        vm.expectRevert(GenerativeInitializer.AlreadyInitialized.selector);
        init.initialize{ value: 1 }(IGenerativeLaunchHook(address(hook)), IGenerativeLaunchToken(address(token)), START_TICK, developer, 1);
        vm.expectRevert(HolderVault.AlreadySet.selector);
        vault.bind(address(hook), address(token));
    }

    function test_initializer_onlyGraphFactory() public {
        vm.prank(alice);
        vm.expectRevert(GenerativeInitializer.Unauthorized.selector);
        init.initialize{ value: 0 }(IGenerativeLaunchHook(address(hook)), IGenerativeLaunchToken(address(token)), START_TICK, developer, 1);
    }

    // ------------------------------------------------------------------ fees

    function test_buy_feeSplitExact() public {
        vm.warp(block.timestamp + 301);
        AutomaticNativeFeeVaultV2 fv = hook.feeVault();
        uint256 team0 = TEAM_WALLET.balance;
        uint256 creator0 = fv.creatorAccrued();
        uint256 holders0 = vault.totalFeesIn();
        uint256 out = _buy(1 ether);
        assertGt(out, 0);
        assertEq(TEAM_WALLET.balance - team0, 0.003 ether, "Programmable 0.3% paid in the swap, as ETH");
        assertEq(fv.creatorAccrued() - creator0, 0.04 ether, "creator 4%");
        assertEq(vault.totalFeesIn() - holders0, 0.003 ether, "holders 0.3%");
        assertEq(fv.platformAccrued(), 0, "nothing left owed to Programmable");
    }

    function test_sell_feesOnGrossEthOut() public {
        vm.warp(block.timestamp + 301);
        uint256 got = _buy(2 ether);
        uint256 team0 = TEAM_WALLET.balance;
        uint256 holders0 = vault.totalFeesIn();
        uint256 creator0 = hook.feeVault().creatorAccrued();
        uint256 ethOut = _sell(got / 2);
        uint256 platform = TEAM_WALLET.balance - team0;
        uint256 holders = vault.totalFeesIn() - holders0;
        uint256 creatorFee = hook.feeVault().creatorAccrued() - creator0;
        uint256 gross = ethOut + platform + holders + creatorFee;
        assertEq(platform, (gross * 30 + 9_999) / 10_000, "ceil 0.3% of gross");
        assertEq(holders, gross * 30 / 10_000, "floor 0.3% of gross");
        assertEq(platform + holders + creatorFee, (gross * 460 + 9_999) / 10_000, "ceil 4.6% of gross");
    }

    function test_quoteFeeSplit_matchesConstants() public view {
        (uint256 gross, uint256 p, uint256 c, uint256 h) = hook.quoteFeeSplit(1 ether, false, true);
        assertEq(gross, 1 ether);
        assertEq(p, 0.003 ether);
        assertEq(c, 0.04 ether);
        assertEq(h, 0.003 ether);
    }

    /// Any trade size: Programmable gets exactly ceil(0.3%), holders floor(0.3%), total ceil(4.6%), creator >= 0.
    function testFuzz_feeRounding(uint128 gross, bool isBuy) public view {
        vm.assume(gross > 0);
        (uint256 g, uint256 p, uint256 c, uint256 h) = hook.quoteFeeSplit(gross, false, isBuy);
        assertEq(g, gross);
        assertEq(p, (uint256(gross) * 30 + 9_999) / 10_000);
        assertEq(h, uint256(gross) * 30 / 10_000);
        assertEq(p + c + h, (uint256(gross) * 460 + 9_999) / 10_000);
        assertLe(p + h, p + c + h);
    }

    function test_creatorClaim_paysCreatorWallet() public {
        vm.warp(block.timestamp + 301);
        _buy(1 ether);
        AutomaticNativeFeeVaultV2 fv = hook.feeVault();
        uint256 owed = fv.creatorAccrued();
        vm.prank(alice); // anyone can trigger; money only goes to the fixed creator wallet
        fv.claimCreator();
        assertEq(creator.balance, owed);
    }

    // ------------------------------------------------------------------ launch protection

    function test_protection_onlyProgrammableRouterInFirstFiveMinutes() public {
        vm.warp(block.timestamp + 60);
        SwapParams memory p =
            SwapParams({ zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        PoolSwapTest.TestSettings memory st = PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });
        vm.expectRevert(); // AutomaticLaunchProtectionModuleV2.UnsupportedRouter, wrapped by the PoolManager
        swapper.swap{ value: 0.01 ether }(key, p, st, "");
        vm.warp(block.timestamp + 241);
        assertGt(_buy(0.01 ether), 0, "open to any router after five minutes");
    }

    function test_protection_walletReceiveCapForFiveMinutes() public {
        uint256 cap = token.walletTokenLimit();
        uint256 devBal = token.balanceOf(developer);
        vm.prank(developer);
        token.transfer(alice, devBal / 2);
        // alice can't receive more than 2% in total during protection
        deal(address(token), bob, cap * 2, false);
        vm.prank(bob);
        vm.expectRevert();
        token.transfer(alice, cap);
    }

    function test_token_frozenBeforeStart_noOwner() public {
        // nothing like owner(), mint or pause exists; the supply is fixed
        (bool ok,) = address(token).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(hook).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ holders

    function test_holderFees_claimInEth() public {
        vm.warp(block.timestamp + 301);
        _buy(1 ether);
        uint256 per = vault.pendingFees(1);
        assertGt(per, 0);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;
        vm.prank(alice);
        vault.claimFees(ids);
        assertEq(alice.balance, per * 3, "alice paid in ETH for her three NFTs");
        assertEq(vault.pendingFees(1), 0);
        assertApproxEqAbs(vault.pendingFees(4), per, 1);
    }

    function test_holderFees_claimForPaysOwner() public {
        vm.warp(block.timestamp + 301);
        _buy(1 ether);
        uint256 per = vault.pendingFees(4);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 4;
        vm.prank(alice);
        vault.claimFeesFor(ids);
        assertEq(bob.balance, per);
    }

    function test_holderFees_notYoursReverts() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 4;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HolderVault.NotTokenOwner.selector, 4));
        vault.claimFees(ids);
    }

    function test_escrow_vestsOverSevenDaysFromLaunch() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.warp(token.startedAt() + 3.5 days);
        assertEq(vault.claimableEscrow(1), 71_174e18 / 2);
        vm.prank(alice);
        vault.claimEscrow(ids);
        assertEq(token.balanceOf(alice), 71_174e18 / 2);
        vm.warp(token.startedAt() + 30 days);
        vm.prank(alice);
        vault.claimEscrow(ids);
        assertEq(token.balanceOf(alice), 71_174e18);
        assertTrue(vault.vestingDone());
    }

    function test_childLaunch_retiresAndBurns() public {
        ChildLauncher launcher = new ChildLauncher(IGenerativeNFTBurn(address(nft)), IHolderVaultRetire(address(vault)), teamOwner);
        MockChildFactory factory = new MockChildFactory();
        vm.prank(teamOwner);
        launcher.setFactory(factory);
        nft.setLauncher(address(launcher));
        vm.warp(block.timestamp + 301);
        _buy(1 ether);
        vm.warp(token.startedAt() + 7 days);
        uint256 fees = vault.pendingFees(4);
        vm.prank(bob);
        vm.expectRevert(ChildLauncher.NotRetired.selector); // the holder must retire it in the vault first
        launcher.launchChild(4, "");
        address payout = makeAddr("bobsColdWallet");
        vm.prank(bob);
        vault.retire(4, payout); // bob decides, and names the recipient
        assertEq(payout.balance, fees, "fees paid to the recipient bob chose");
        assertEq(token.balanceOf(payout), 71_174e18, "full escrow paid to the recipient bob chose");
        assertEq(vault.liveSupply(), 280);
        vm.prank(bob);
        launcher.launchChild(4, "");
        vm.expectRevert();
        nft.ownerOf(4);
    }

    /// Reviewer case: every eligible NFT retired (liveSupply == 0). Buys and sells keep working, Programmable's
    /// 0.3% is still paid in the swap, and the holder 0.3% goes to the fixed residual recipient (creator wallet).
    function test_allNftsRetired_buyAndSellStillWork() public {
        vm.warp(token.startedAt() + 7 days); // retire needs the vest done (and clears the 5-minute protection)
        for (uint256 i = 1; i <= 281; ++i) {
            address holder = nft.ownerOf(i);
            vm.prank(holder);
            vault.retire(i, holder);
        }
        assertEq(vault.liveSupply(), 0);
        uint256 dust = vault.residualFees(); // rounding dust from the per-NFT split, moved to the residual
        assertEq(dust, vault.feeLiability());
        assertLt(dust, 281, "less than 1 wei per NFT");

        AutomaticNativeFeeVaultV2 fv = hook.feeVault();
        uint256 team0 = TEAM_WALLET.balance;
        uint256 creator0 = fv.creatorAccrued();
        uint256 got = _buy(1 ether);
        assertGt(got, 0, "buy works");
        assertEq(TEAM_WALLET.balance - team0, 0.003 ether, "Programmable 0.3% paid on the buy");
        assertEq(fv.creatorAccrued() - creator0, 0.04 ether, "creator 4% on the buy");
        assertEq(vault.residualFees() - dust, 0.003 ether, "holder 0.3% held for the residual recipient");

        uint256 team1 = TEAM_WALLET.balance;
        uint256 res1 = vault.residualFees();
        uint256 creator1 = fv.creatorAccrued();
        uint256 ethOut = _sell(got / 2);
        assertGt(ethOut, 0, "sell works");
        uint256 platform = TEAM_WALLET.balance - team1;
        uint256 holders = vault.residualFees() - res1;
        uint256 gross = ethOut + platform + holders + (fv.creatorAccrued() - creator1);
        assertEq(platform, (gross * 30 + 9_999) / 10_000, "Programmable ceil 0.3% on the sell");
        assertEq(holders, gross * 30 / 10_000, "holder 0.3% of the sell held as residual");

        uint256 owed = vault.residualFees();
        uint256 c0 = creator.balance;
        vm.prank(alice); // anyone can trigger; it only goes to the fixed recipient
        vault.sendResidual();
        assertEq(creator.balance - c0, owed, "residual paid to the creator wallet");
        assertEq(vault.residualFees(), 0);
        assertEq(vault.feeLiability(), 0, "nothing owed");
        assertEq(IPoolManager(PM).balanceOf(address(vault), 0), 0, "vault holds no ETH claims");
        assertEq(vault.residualRecipient(), creator);
    }

    /// Reviewer request: only the current holder retires an NFT and chooses the payout recipient.
    function test_retire_onlyHolderDecides() public {
        vm.warp(block.timestamp + 301);
        _buy(1 ether);
        vm.warp(token.startedAt() + 7 days);
        address launcherLike = makeAddr("launcher");
        // nobody else can retire bob's NFT: not alice, not a launcher, not the team, not the deployer
        address[4] memory others = [alice, launcherLike, teamOwner, address(this)];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(HolderVault.NotTokenOwner.selector, 4));
            vault.retire(4, others[i]);
        }
        vm.prank(bob);
        vm.expectRevert(HolderVault.ZeroRecipient.selector);
        vault.retire(4, address(0));
        // after a sale, only the new holder decides
        vm.prank(bob);
        nft.transferFrom(bob, alice, 4);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HolderVault.NotTokenOwner.selector, 4));
        vault.retire(4, bob);
        uint256 fees = vault.pendingFees(4);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        vault.retire(4, alice);
        assertEq(alice.balance - a0, fees);
        assertEq(token.balanceOf(alice), 71_174e18);
        assertTrue(vault.retired(4));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HolderVault.TokenRetired.selector, 4));
        vault.retire(4, alice);
    }

    function test_retire_notBeforeVestDone() public {
        vm.prank(bob);
        vm.expectRevert(HolderVault.VestingNotDone.selector);
        vault.retire(4, bob);
    }

    function test_vault_hasNoOwner() public view {
        (bool ok,) = address(vault).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(vault).staticcall(abi.encodeWithSignature("launcher()"));
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ pool lock

    function test_hook_rejectsSecondPool() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        IPoolManager(PM).initialize(other, TickMath.getSqrtPriceAtTick(0));
    }

    function test_module_isProgrammablesV2() public view {
        AutomaticLaunchProtectionModuleV2 m = AutomaticLaunchProtectionModuleV2(hook.module());
        assertEq(m.kernel(), address(hook));
        assertEq(m.developer(), developer);
        assertEq(m.normalBuyFeePpm(), 46_000, "opening tax decays to the full 4.6%");
        assertEq(hook.PLATFORM_RECIPIENT(), TEAM_WALLET);
    }
}
