// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GovernanceToken} from "../src/token/GovernanceToken.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {PropFirmVault} from "../src/vault/PropFirmVault.sol";
import {VaultFactory} from "../src/vault/VaultFactory.sol";
import {HyperCoreValuer} from "../src/vault/HyperCoreValuer.sol";
import {PerplValuer, IPerplExchange} from "../src/vault/PerplValuer.sol";
import {IValuer} from "../src/vault/IValuer.sol";

contract USDC6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A venue whose value the test sets.
contract MockValuer is IValuer {
    uint256 public v;
    bool public ok = true;

    function set(uint256 v_, bool ok_) external {
        v = v_;
        ok = ok_;
    }

    function value() external view returns (uint256, bool) {
        return (v, ok);
    }
}

contract MockPerpl {
    IPerplExchange.AccountInfo internal _acct;
    mapping(uint256 => IPerplExchange.PositionInfo) internal _pos;
    mapping(uint256 => uint256) internal _mark;
    mapping(uint256 => bool) internal _markValid;
    bool public hasAccount;

    function setAccount(uint256 id, uint256 balance) external {
        _acct.accountId = id;
        _acct.balanceCNS = balance;
        hasAccount = true;
    }

    function setPosition(uint256 perp, uint8 kind, uint256 deposit, uint256 entry, uint256 lots, uint256 mark, bool valid) external {
        _pos[perp].positionType = kind;
        _pos[perp].depositCNS = deposit;
        _pos[perp].pricePNS = entry;
        _pos[perp].lotLNS = lots;
        _mark[perp] = mark;
        _markValid[perp] = valid;
    }

    function getAccountByAddr(address) external view returns (IPerplExchange.AccountInfo memory) {
        require(hasAccount, "no account");
        return _acct;
    }

    function getPosition(uint256 perp, uint256) external view returns (IPerplExchange.PositionInfo memory, uint256, bool) {
        return (_pos[perp], _mark[perp], _markValid[perp]);
    }

    function getPerpetualInfo(uint256) external pure returns (IPerplExchange.PerpetualInfo memory p) {
        p.priceDecimals = 2;
        p.lotDecimals = 3;
    }

    function getExchangeInfo() external pure returns (uint256, uint256, uint256, uint256, address, address) {
        return (0, 0, 0, 6, address(0), address(0));
    }
}

contract PropFirmVaultTest is Test {
    USDC6 internal usdc;
    GovernanceToken internal token;
    Treasury internal treasury;
    PropFirmVault internal vault;
    MockValuer internal desk;
    VaultFactory internal factory;

    address internal gov = makeAddr("governance");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal trader = makeAddr("trader");

    uint256 internal constant SHARE = 1e12; // shares per USDC unit at the start

    function _config() internal pure returns (PropFirmVault.Config memory c) {
        c.interval = 30 days;
        c.freezeBefore = 1 days;
        c.settleDelay = 1 hours;
        c.managementBps = 0;
        c.performanceBps = 0;
        c.maxDrawdownBps = 2_000;
        c.openToAll = true;
    }

    function setUp() public {
        usdc = new USDC6();
        treasury = Treasury(payable(Clones.clone(address(new Treasury()))));
        treasury.initialize(gov);
        token = GovernanceToken(Clones.clone(address(new GovernanceToken())));
        token.initialize("Firm", "FIRM", 0, type(uint128).max, gov, gov);
        factory = new VaultFactory(address(new PropFirmVault()));
        PropFirmVault.FeeSplit[] memory none = new PropFirmVault.FeeSplit[](0);
        vault = PropFirmVault(payable(factory.createVault(address(usdc), address(token), address(treasury), address(0), _config(), none, bytes32("v"))));
        vm.prank(gov);
        token.setMinter(address(vault));
        desk = new MockValuer();
        vm.prank(gov);
        vault.setValuer(address(desk), true);
        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            usdc.mint(who, 10_000e6);
            vm.prank(who);
            usdc.approve(address(vault), type(uint256).max);
            vm.prank(who);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function _toWindow() internal {
        vm.warp(vault.nextWindowAt());
    }

    function test_DepositPricedAtTheWindowThenClaimed() public {
        vm.prank(alice);
        vault.requestDeposit(1_000e6);
        assertEq(vault.totalValue(), 0, "pending deposits aren't part of the value");
        vm.expectRevert(abi.encodeWithSelector(PropFirmVault.WindowNotDue.selector, vault.nextWindowAt()));
        vault.processWindow();

        _toWindow();
        vault.processWindow();
        vm.prank(alice);
        vault.claimShares(1);
        assertEq(token.balanceOf(alice), 1_000e6 * SHARE, "one share per USDC to start");
        assertEq(vault.epoch(), 2);
    }

    function test_ProfitRaisesThePriceForNewcomers_AndRedemptionsAreOwedAtThatPrice() public {
        vm.prank(alice);
        vault.requestDeposit(1_000e6);
        _toWindow();
        vault.processWindow();
        vm.prank(alice);
        vault.claimShares(1);

        // The desk takes the money and makes 10%: 1,100 USDC on the venue, nothing idle.
        vm.prank(address(vault));
        usdc.transfer(trader, 1_000e6);
        desk.set(1_100e6, true);

        vm.prank(bob);
        vault.requestDeposit(1_100e6);
        vm.prank(alice);
        vault.requestRedeem(500e6 * SHARE);
        _toWindow();
        vault.processWindow();

        vm.prank(bob);
        vault.claimShares(2);
        assertEq(token.balanceOf(bob), 1_000e6 * SHARE, "1,100 USDC buys 1,000 shares at 1.10");
        assertEq(vault.owedAssets(), 550e6, "500 shares redeem for 550");

        vm.prank(alice);
        vault.claimRedemption(2);
        assertEq(usdc.balanceOf(alice), 9_000e6 + 550e6);
    }

    function test_RedemptionsPaidAsMoneyComesBack() public {
        vm.prank(alice);
        vault.requestDeposit(1_000e6);
        _toWindow();
        vault.processWindow();
        vm.prank(alice);
        vault.claimShares(1);
        vm.prank(address(vault));
        usdc.transfer(trader, 900e6); // 900 out on the desk, 100 idle
        desk.set(900e6, true);

        vm.prank(alice);
        vault.requestRedeem(400e6 * SHARE);
        _toWindow();
        vault.processWindow();
        vm.prank(alice);
        assertEq(vault.claimRedemption(2), 100e6, "only what's idle");
        vm.prank(trader);
        usdc.transfer(address(vault), 300e6); // the desk sends money back
        vm.prank(alice);
        assertEq(vault.claimRedemption(2), 300e6, "the rest");
        vm.prank(alice);
        vm.expectRevert(PropFirmVault.NothingToClaim.selector);
        vault.claimRedemption(2);
    }

    function test_StalePriceMakesTheWindowWait() public {
        vm.prank(alice);
        vault.requestDeposit(1_000e6);
        desk.set(0, false);
        _toWindow();
        vm.expectRevert(abi.encodeWithSelector(PropFirmVault.StalePrice.selector, address(desk)));
        vault.processWindow();
        desk.set(0, true);
        vault.processWindow();
    }

    function test_MovesFreezeBeforeAWindowAndTheWindowWaitsForThemToSettle() public {
        uint64 at = vault.nextWindowAt();
        vm.warp(at - 1 days);
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(PropFirmVault.MovesFrozen.selector, at));
        vault.execute(address(usdc), 0, abi.encodeCall(usdc.transfer, (trader, 0)));

        vm.warp(at - 2 days);
        vm.prank(gov);
        vault.execute(address(usdc), 0, abi.encodeCall(usdc.transfer, (trader, 0)));
        vm.warp(at);
        vault.processWindow(); // a day later: settled

        vm.prank(alice);
        vm.expectRevert(PropFirmVault.Unauthorized.selector);
        vault.execute(address(usdc), 0, "");

        // Never the share token: the vault is its minter.
        vm.prank(gov);
        vm.expectRevert(PropFirmVault.Unauthorized.selector);
        vault.execute(address(token), 0, abi.encodeCall(token.mint, (gov, 1)));
    }

    function test_SettleDelayAfterALateMove() public {
        PropFirmVault.Config memory c = _config();
        c.freezeBefore = 0;
        vm.prank(gov);
        vault.setConfig(c);
        uint64 at = vault.nextWindowAt();
        vm.warp(at - 10);
        vm.prank(gov);
        vault.execute(address(usdc), 0, abi.encodeCall(usdc.transfer, (trader, 0)));
        vm.warp(at);
        vm.expectRevert(abi.encodeWithSelector(PropFirmVault.Settling.selector, uint64(at - 10 + 1 hours)));
        vault.processWindow();
    }

    function test_DrawdownPausesTradingUntilAProposalResumes() public {
        vm.prank(alice);
        vault.requestDeposit(1_000e6);
        _toWindow();
        vault.processWindow();
        vm.prank(address(vault));
        usdc.transfer(trader, 1_000e6);
        desk.set(700e6, true); // down 30%, past the 20% limit
        assertTrue(vault.checkDrawdown());
        assertTrue(vault.paused());
        vm.prank(alice);
        vm.expectRevert(PropFirmVault.Unauthorized.selector);
        vault.resume();
        vm.prank(gov);
        vault.resume();
        assertFalse(vault.paused());
    }

    function test_FeesSplitBetweenTraderAndTreasury() public {
        PropFirmVault.Config memory c = _config();
        c.managementBps = 200; // 2% a year
        c.performanceBps = 2_000; // 20% of gains
        PropFirmVault.FeeSplit[] memory splits = new PropFirmVault.FeeSplit[](2);
        splits[0] = PropFirmVault.FeeSplit(trader, 5_000);
        splits[1] = PropFirmVault.FeeSplit(address(treasury), 5_000);
        vm.startPrank(gov);
        vault.setConfig(c);
        vault.setFeeSplits(splits);
        vm.stopPrank();

        vm.prank(alice);
        vault.requestDeposit(1_000e6);
        _toWindow();
        vault.processWindow(); // no shares yet, so no fees
        assertEq(token.balanceOf(trader), 0);

        vm.prank(address(vault));
        usdc.transfer(makeAddr("venue"), 1_000e6);
        desk.set(1_200e6, true); // +20%
        _toWindow();
        vault.processWindow();
        uint256 traderShares = token.balanceOf(trader);
        uint256 treasuryShares = token.balanceOf(address(treasury));
        assertGt(traderShares, 0);
        assertApproxEqAbs(traderShares, treasuryShares, 1);
        // Fees: management ~2% x 30/365 of 1,200 (~1.97) plus 20% of the ~198 gain (~39.6): ~41.6 USDC of value.
        uint256 feeValue = ((traderShares + treasuryShares) * 1_200e6) / token.totalSupply();
        assertApproxEqRel(feeValue, 41.6e6, 0.01e18);
        assertGt(vault.highWater(), 1e6, "the high water mark moved up");
    }

    function test_AllowedOnlyWhenNotOpenToAll() public {
        PropFirmVault.Config memory c = _config();
        c.openToAll = false;
        vm.prank(gov);
        vault.setConfig(c);
        vm.prank(alice);
        vm.expectRevert(PropFirmVault.NotAllowed.selector);
        vault.requestDeposit(1e6);
        vm.prank(gov);
        vault.setAllowed(alice, true);
        vm.prank(alice);
        vault.requestDeposit(1e6);
    }

    function test_CancelBeforeTheWindow() public {
        vm.prank(alice);
        vault.requestDeposit(1_000e6);
        vm.prank(alice);
        vault.cancelDeposit();
        assertEq(usdc.balanceOf(alice), 10_000e6);
        assertEq(vault.pendingDepositAssets(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                VALUERS
    //////////////////////////////////////////////////////////////*/

    function test_HyperCoreValuer_SpotPlusPerpAccountValue() public {
        address v = factory.createHyperCoreValuer(address(vault), 0, 0, 6, 6);
        HyperCoreValuer.TokenInfo memory info;
        info.weiDecimals = 8;
        vm.mockCall(address(0x80C), abi.encode(uint64(0)), abi.encode(info));
        vm.mockCall(address(0x801), abi.encode(address(vault), uint64(0)), abi.encode(HyperCoreValuer.SpotBalance(250e8, 0, 0)));
        vm.mockCall(address(0x80F), abi.encode(uint32(0), address(vault)), abi.encode(HyperCoreValuer.AccountMarginSummary(1_500e6, 0, 0, 0)));
        (uint256 assets, bool valid) = HyperCoreValuer(v).value();
        assertTrue(valid);
        assertEq(assets, 1_750e6, "250 spot USDC + 1,500 perp account value");

        vm.mockCall(address(0x80F), abi.encode(uint32(0), address(vault)), abi.encode(HyperCoreValuer.AccountMarginSummary(-5e6, 0, 0, 0)));
        (assets,) = HyperCoreValuer(v).value();
        assertEq(assets, 250e6, "a negative perp account counts as nothing");
    }

    function test_PerplValuer_BalanceMarginAndMarkPnl() public {
        MockPerpl ex = new MockPerpl();
        uint256[] memory markets = new uint256[](2);
        (markets[0], markets[1]) = (16, 32);
        address v = factory.createPerplValuer(IPerplExchange(address(ex)), address(this), markets, 6);
        (uint256 assets, bool valid) = PerplValuer(v).value();
        assertEq(assets, 0, "no account yet");
        assertTrue(valid);

        ex.setAccount(7, 100e6);
        // Long 2.000 lots from 50,000.00 to 51,000.00: +2,000 USDC on 500 margin.
        ex.setPosition(16, 0, 500e6, 5_000_000, 2_000, 5_100_000, true);
        // Short 1.000 lot from 3,000.00 to 3,100.00: -100 on 300 margin.
        ex.setPosition(32, 1, 300e6, 300_000, 1_000, 310_000, true);
        (assets, valid) = PerplValuer(v).value();
        assertTrue(valid);
        assertEq(assets, 100e6 + 500e6 + 2_000e6 + 300e6 - 100e6);

        ex.setPosition(32, 1, 300e6, 300_000, 1_000, 310_000, false);
        (, valid) = PerplValuer(v).value();
        assertFalse(valid, "an invalid mark makes the window wait");
    }
}
