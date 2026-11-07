// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GovernanceTestBase} from "./GovernanceTestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAOFactory} from "../src/factory/DAOFactory.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {Distributor} from "../src/distribution/Distributor.sol";
import {DistributionFactory} from "../src/distribution/DistributionFactory.sol";
import {Raise} from "../src/distribution/Raise.sol";
import {Launcher} from "../src/distribution/Launcher.sol";
import {VaultFactory} from "../src/vault/VaultFactory.sol";
import {PropFirmVault} from "../src/vault/PropFirmVault.sol";

contract USDCMock is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RaiseTest is GovernanceTestBase {
    DistributionFactory internal dfactory;
    Launcher internal launcher;
    USDCMock internal usdc;

    address internal operator = makeAddr("operator");
    address internal founder = makeAddr("founder");
    address internal a = makeAddr("contributorA");
    address internal b = makeAddr("contributorB");
    address internal c = makeAddr("contributorC");
    address internal dev = makeAddr("developer");
    bytes32 internal constant A_ACCOUNT = keccak256("telegram:1");

    uint256 internal constant SALE = 300_000 ether;

    function setUp() public override {
        super.setUp();
        dfactory = new DistributionFactory(address(new Distributor()), address(new Raise()));
        launcher = new Launcher(dfactory, new VaultFactory(address(new PropFirmVault())), address(this));
        launcher.approveFactory(address(factory), true);
        usdc = new USDCMock();
        for (uint256 i = 0; i < 3; i++) {
            address who = [a, b, c][i];
            vm.deal(who, 100 ether);
            usdc.mint(who, 1_000_000 ether);
        }
    }

    function _terms(address currency, address fundsTo) internal view returns (Raise.Terms memory t) {
        t.currency = currency;
        t.softCap = 10 ether;
        t.hardCap = 50 ether;
        t.start = uint64(block.timestamp);
        t.end = uint64(block.timestamp + 7 days);
        t.saleSupply = SALE;
        t.vestCliff = 0;
        t.vestDuration = 0;
        t.decisionWindow = 7 days;
        t.fundsTo = fundsTo;
    }

    /// An existing DAO's raise: its governance decides, the money goes to its Treasury.
    function _daoRaise(Raise.Terms memory t) internal returns (Raise r, Distributor d) {
        vm.prank(address(gov));
        r = Raise(dfactory.createRaise(t, bytes32("r1")));
        address[] memory allocators = new address[](1);
        allocators[0] = address(r);
        d = Distributor(dfactory.createDistributor(address(underlying), address(treasury), operator, allocators, 0, bytes32("d1")));
        vm.prank(creator);
        underlying.transfer(address(d), SALE);
    }

    function test_ProRata_AboveTheHardCap() public {
        (Raise r, Distributor d) = _daoRaise(_terms(address(0), address(treasury)));
        vm.prank(a);
        r.contribute{value: 30 ether}(30 ether, A_ACCOUNT);
        vm.prank(b);
        r.contribute{value: 20 ether}(20 ether, bytes32(0));
        vm.prank(c);
        r.contribute{value: 10 ether}(10 ether, bytes32(0));
        assertEq(r.totalContributed(), 60 ether, "contributions continue past the 50 hard cap");

        vm.warp(block.timestamp + 7 days);
        vm.prank(a);
        vm.expectRevert(Raise.Unauthorized.selector);
        r.accept(55 ether, address(treasury), address(d));

        uint256 before = address(treasury).balance;
        vm.prank(address(gov));
        r.accept(55 ether, address(treasury), address(d)); // above the hard cap: allowed
        assertEq(address(treasury).balance - before, 55 ether);

        address[] memory who = new address[](3);
        (who[0], who[1], who[2]) = (a, b, c);
        r.settle(who);
        // Tokens: half, a third and a sixth of the sale.
        assertEq(d.allocation(1).total, SALE / 2);
        assertEq(d.allocation(1).account, A_ACCOUNT);
        assertEq(d.allocation(2).total, SALE / 3);
        assertEq(d.allocation(3).total, SALE / 6);
        // Refunds: each gets back their share of the 5 not accepted.
        uint256 aBefore = a.balance;
        r.withdrawRefund(a);
        assertEq(a.balance - aBefore, 2.5 ether);
        r.withdrawRefund(b);
        r.withdrawRefund(c);
        assertLe(address(r).balance, 2, "only rounding dust left");
        vm.expectRevert(Raise.NothingOwed.selector);
        r.withdrawRefund(a);

        vm.prank(a);
        d.claim(1);
        assertEq(underlying.balanceOf(a), SALE / 2);
    }

    function test_BelowTheSoftCap_EveryoneRefundedInFull() public {
        (Raise r, Distributor d) = _daoRaise(_terms(address(usdc), address(treasury)));
        vm.startPrank(a);
        usdc.approve(address(r), 5 ether);
        r.contribute(5 ether, bytes32(0));
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        assertTrue(r.failed());
        vm.prank(address(gov));
        vm.expectRevert(abi.encodeWithSelector(Raise.OutOfRange.selector, 10 ether, 5 ether));
        r.accept(5 ether, address(treasury), address(d));
        uint256 before = usdc.balanceOf(a);
        r.withdrawRefund(a);
        assertEq(usdc.balanceOf(a) - before, 5 ether);
    }

    function test_NoDecisionInTime_EveryoneRefundedInFull() public {
        (Raise r, Distributor d) = _daoRaise(_terms(address(0), address(treasury)));
        vm.prank(a);
        r.contribute{value: 20 ether}(20 ether, bytes32(0));
        vm.warp(block.timestamp + 14 days);
        assertTrue(r.failed());
        vm.prank(address(gov));
        vm.expectRevert(Raise.DecisionClosed.selector);
        r.accept(20 ether, address(treasury), address(d));
        uint256 before = a.balance;
        r.withdrawRefund(a);
        assertEq(a.balance - before, 20 ether);
    }

    function test_ContributionRules() public {
        Raise.Terms memory t = _terms(address(0), address(treasury));
        t.minContribution = 1 ether;
        t.maxContribution = 5 ether;
        (Raise r,) = _daoRaise(t);
        vm.startPrank(a);
        vm.expectRevert(abi.encodeWithSelector(Raise.BelowMinimum.selector, 1 ether));
        r.contribute{value: 0.5 ether}(0.5 ether, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Raise.AboveMaximum.selector, 5 ether));
        r.contribute{value: 6 ether}(6 ether, bytes32(0));
        vm.expectRevert(Raise.WrongAmount.selector);
        r.contribute{value: 1 ether}(2 ether, bytes32(0));
        r.contribute{value: 2 ether}(2 ether, A_ACCOUNT);
        vm.expectRevert(Raise.AccountMismatch.selector);
        r.contribute{value: 1 ether}(1 ether, keccak256("someone else"));
        vm.stopPrank();
        vm.warp(t.end);
        vm.prank(b);
        vm.expectRevert(Raise.NotOpen.selector);
        r.contribute{value: 1 ether}(1 ether, bytes32(0));
    }

    function test_TheMoneyOnlyGoesToTheDaosTreasury() public {
        (Raise r, Distributor d) = _daoRaise(_terms(address(0), address(treasury)));
        vm.prank(a);
        r.contribute{value: 20 ether}(20 ether, bytes32(0));
        vm.warp(block.timestamp + 7 days);
        vm.prank(address(gov));
        vm.expectRevert(Raise.WrongTreasury.selector);
        r.accept(20 ether, address(gov), address(d));
    }

    /*//////////////////////////////////////////////////////////////
                                LAUNCH
    //////////////////////////////////////////////////////////////*/

    function _noPropFirm() internal pure returns (Launcher.PropFirm memory p) {}

    function _launch() internal returns (uint256 id, Raise r) {
        bytes memory createCall = abi.encodeCall(DAOFactory.createDAO, ("Launched", "LCH", INITIAL_SUPPLY, MAX_SUPPLY, defaultConfig()));
        Launcher.Share[] memory shares = new Launcher.Share[](1);
        shares[0] = Launcher.Share({owner: founder, account: bytes32(0), amount: 100_000 ether, cliff: 90 days, duration: 360 days});
        Launcher.AllowanceTerm[] memory allowances = new Launcher.AllowanceTerm[](2);
        allowances[0] = Launcher.AllowanceTerm({recipient: dev, token: address(0), daoToken: false, amount: 1 ether, duration: 180 days});
        allowances[1] = Launcher.AllowanceTerm({recipient: dev, token: address(0), daoToken: true, amount: 1_000 ether, duration: 365 days});
        vm.prank(founder);
        address raise;
        (id, raise) = launcher.createLaunch(address(factory), createCall, _terms(address(0), address(0)), shares, allowances, operator, 0, _noPropFirm());
        r = Raise(raise);
    }

    function test_Launch_EverythingInOneGo() public {
        (uint256 id, Raise r) = _launch();
        vm.prank(a);
        r.contribute{value: 40 ether}(40 ether, A_ACCOUNT);
        vm.prank(b);
        r.contribute{value: 40 ether}(40 ether, bytes32(0));
        vm.warp(block.timestamp + 7 days);

        vm.prank(a);
        vm.expectRevert(Launcher.NotFounder.selector);
        launcher.finish(id, 60 ether);

        vm.prank(founder);
        launcher.finish(id, 60 ether);
        Launcher.Launch memory l = launcher.launch(id);
        Treasury t = Treasury(payable(l.treasury));
        IERC20 tok = IERC20(l.token);

        assertEq(t.governance(), l.governance, "the new governance runs the Treasury");
        assertEq(l.treasury.balance, 60 ether, "the accepted money is in the Treasury");
        assertEq(founder.balance, 0, "and none of it went to the founder");
        assertEq(tok.balanceOf(l.distributor), SALE + 100_000 ether, "sale and team share in the Distributor");
        assertEq(tok.balanceOf(l.treasury), INITIAL_SUPPLY - SALE - 100_000 ether, "the rest in the Treasury");
        assertEq(t.allowanceCount(), 2, "the agreed allowances are set");
        assertEq(t.allowance(2).token, l.token, "one in the DAO's own token");
        assertEq(t.setupAuthority(), address(0), "and the launch window is closed");

        // Team share vests: nothing before the cliff.
        Distributor d = Distributor(l.distributor);
        assertEq(d.allocation(1).owner, founder);
        assertEq(d.claimable(1), 0);

        // Contributors settle, claim their tokens and get the unaccepted quarter back.
        address[] memory who = new address[](2);
        (who[0], who[1]) = (a, b);
        r.settle(who);
        vm.prank(operator);
        d.claimFor(2, makeAddr("aWallet"));
        assertEq(tok.balanceOf(makeAddr("aWallet")), SALE / 2);
        uint256 before = b.balance;
        r.withdrawRefund(b);
        assertEq(b.balance - before, 10 ether);

        // The developer claims their allowance from the Treasury.
        vm.prank(dev);
        t.claimAllowance(1);
        assertEq(dev.balance, 1 ether);

        vm.prank(founder);
        vm.expectRevert(Launcher.AlreadyFinished.selector);
        launcher.finish(id, 60 ether);
    }

    function test_Launch_FailedRaiseRefundsAndNoDao() public {
        (uint256 id, Raise r) = _launch();
        vm.prank(a);
        r.contribute{value: 5 ether}(5 ether, bytes32(0));
        vm.warp(block.timestamp + 7 days);
        vm.prank(founder);
        vm.expectRevert(); // below the soft cap: accept refuses and nothing is created
        launcher.finish(id, 5 ether);
        r.withdrawRefund(a);
        assertEq(a.balance, 100 ether);
    }

    function test_Launch_OnlyApprovedFactories() public {
        Launcher.Share[] memory none;
        Launcher.AllowanceTerm[] memory noAllowances;
        vm.expectRevert(Launcher.FactoryNotApproved.selector);
        launcher.createLaunch(address(0xBEEF), "", _terms(address(0), address(0)), none, noAllowances, operator, 0, _noPropFirm());
    }

    function test_AWalletCreatorGetsNoSetupWindow() public view {
        assertEq(treasury.setupAuthority(), address(0), "the creator of the base DAO is a wallet");
    }

    function test_PropFirmLaunch_TheMoneyBecomesVaultShares() public {
        bytes memory createCall = abi.encodeCall(DAOFactory.createDAO, ("Firm", "FIRM", 0, type(uint128).max, defaultConfig()));
        Raise.Terms memory t = _terms(address(usdc), address(0));
        t.saleSupply = 0; // the shares come from the accepted money
        Launcher.PropFirm memory pf;
        pf.enabled = true;
        pf.config.interval = 30 days;
        pf.config.freezeBefore = 1 days;
        pf.config.openToAll = true;
        Launcher.Share[] memory none;
        Launcher.AllowanceTerm[] memory noAllowances;

        // A prop firm takes no team shares and needs a token, not the native coin.
        Raise.Terms memory nativeTerms = _terms(address(0), address(0));
        nativeTerms.saleSupply = 0;
        vm.prank(founder);
        vm.expectRevert(Launcher.InvalidPropFirm.selector);
        launcher.createLaunch(address(factory), createCall, nativeTerms, none, noAllowances, operator, 0, pf);

        vm.prank(founder);
        (uint256 id, address raiseAddr) = launcher.createLaunch(address(factory), createCall, t, none, noAllowances, operator, 0, pf);
        Raise r = Raise(raiseAddr);
        vm.startPrank(a);
        usdc.approve(address(r), 30 ether);
        r.contribute(30 ether, A_ACCOUNT);
        vm.stopPrank();
        vm.startPrank(b);
        usdc.approve(address(r), 10 ether);
        r.contribute(10 ether, bytes32(0));
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);

        vm.prank(founder);
        launcher.finish(id, 20 ether);
        Launcher.Launch memory l = launcher.launch(id);
        PropFirmVault vault = PropFirmVault(payable(l.vault));
        IERC20 shares = IERC20(l.token);

        assertEq(usdc.balanceOf(l.vault), 20 ether, "the accepted money is in the vault");
        assertEq(usdc.balanceOf(founder), 0);
        assertEq(shares.balanceOf(l.distributor), 20 ether, "its shares wait in the Distributor (1 share per unit for an 18-decimal asset)");
        assertEq(r.saleSupply(), 20 ether);
        assertEq(address(vault.shares()), l.token, "the vault's shares are the DAO's token");

        address[] memory who = new address[](2);
        (who[0], who[1]) = (a, b);
        r.settle(who);
        vm.prank(operator);
        Distributor(l.distributor).claimFor(1, makeAddr("aWallet"));
        assertEq(shares.balanceOf(makeAddr("aWallet")), 15 ether, "three quarters of the shares");
        uint256 before = usdc.balanceOf(b);
        r.withdrawRefund(b);
        assertEq(usdc.balanceOf(b) - before, 5 ether, "half of b's 10 back");

        // The vault then runs normally: a later deposit is priced at its window.
        vm.startPrank(c);
        usdc.approve(address(vault), 10 ether);
        vault.requestDeposit(10 ether);
        vm.stopPrank();
        vm.warp(vault.nextWindowAt());
        vault.processWindow();
        vm.prank(c);
        vault.claimShares(1);
        assertEq(shares.balanceOf(c), 10 ether);
    }
}

