// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DecisionMarketsGovernance} from "../src/governance/futarchy/DecisionMarketsGovernance.sol";
import {ConditionalVault} from "../src/governance/futarchy/ConditionalVault.sol";
import {ConditionalToken} from "../src/governance/futarchy/ConditionalToken.sol";
import {DecisionMarketPair} from "../src/governance/futarchy/DecisionMarketPair.sol";
import {WMON} from "../src/governance/futarchy/WMON.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract MockGovernanceToken {
    string public name = "Gov";
    string public symbol = "GOV";
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DecisionMarketsGovernanceTest is Test {
    DecisionMarketsGovernance internal gov;
    MockGovernanceToken internal govToken;
    WMON internal wmon;

    address internal creator = makeAddr("creator");
    address internal treasury = makeAddr("treasury");
    address internal proposer = makeAddr("proposer");
    address internal alice = makeAddr("alice"); // bullish on pass
    address internal bob = makeAddr("bob"); // bullish on fail
    address internal recipient = makeAddr("recipient");

    function defaultConfig() internal pure returns (DecisionMarketsGovernance.DecisionMarketsConfig memory) {
        return DecisionMarketsGovernance.DecisionMarketsConfig({
            tradingPeriod: 3 days,
            thresholdBps: 300, // pass must beat fail by 3%, matching MetaDAO's real community-proposal threshold
            timelockDelay: 1 days,
            executionPeriod: 7 days
        });
    }

    function setUp() public {
        govToken = new MockGovernanceToken();
        wmon = new WMON();

        ConditionalToken tokenImpl = new ConditionalToken();
        ConditionalVault vaultImpl = new ConditionalVault();
        DecisionMarketPair pairImpl = new DecisionMarketPair();

        gov = DecisionMarketsGovernance(payable(Clones.clone(address(new DecisionMarketsGovernance()))));
        gov.initialize(
            "Test DAO",
            creator,
            address(govToken),
            treasury,
            address(wmon),
            address(tokenImpl),
            address(vaultImpl),
            address(pairImpl),
            defaultConfig()
        );

        govToken.mint(proposer, 10_000 ether);
        govToken.mint(alice, 10_000 ether);
        govToken.mint(bob, 10_000 ether);
        vm.deal(proposer, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _singleAction() internal view returns (DecisionMarketsGovernance.ProposalAction[] memory actions) {
        actions = new DecisionMarketsGovernance.ProposalAction[](1);
        actions[0] = DecisionMarketsGovernance.ProposalAction({target: recipient, value: 1 ether, data: ""});
    }

    function _propose(uint256 baseSeed, uint256 quoteSeed) internal returns (uint256 id) {
        vm.startPrank(proposer);
        govToken.approve(address(gov), baseSeed);
        id = gov.propose{value: quoteSeed}(_singleAction(), "ipfs://p1", baseSeed);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            PROPOSAL CREATION
    //////////////////////////////////////////////////////////////*/

    function test_Propose_CreatesTwoDistinctSeededPools() public {
        uint256 id = _propose(1_000 ether, 10 ether);

        DecisionMarketsGovernance.Proposal memory p = gov.getProposal(id);
        assertTrue(p.passPool != address(0));
        assertTrue(p.failPool != address(0));
        assertTrue(p.passPool != p.failPool);

        DecisionMarketPair passPool = DecisionMarketPair(p.passPool);
        (uint112 r0, uint112 r1, ) = passPool.getReserves();
        assertEq(uint256(r0), 1_000 ether);
        assertEq(uint256(r1), 10 ether);
    }

    function test_Propose_RevertsOnZeroSeed() public {
        vm.startPrank(proposer);
        govToken.approve(address(gov), 1_000 ether);
        vm.expectRevert(DecisionMarketsGovernance.ZeroSeedAmount.selector);
        gov.propose{value: 0}(_singleAction(), "ipfs://p1", 1_000 ether);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
        FULL LIFECYCLE: TRADING PUSHES PASS HIGHER -> PROPOSAL PASSES
    //////////////////////////////////////////////////////////////*/

    function test_FullLifecycle_PassWinsWhenTradedHigher() public {
        uint256 id = _propose(1_000 ether, 10 ether);
        DecisionMarketsGovernance.Proposal memory p = gov.getProposal(id);

        // Alice believes this will pass - she buys pass-base-token with
        // pass-quote-token, pushing the pass market's price up.
        ConditionalVault quoteVault = ConditionalVault(p.quoteVault);
        vm.startPrank(alice);
        wmon.deposit{value: 5 ether}();
        wmon.approve(address(quoteVault), 5 ether);
        quoteVault.splitTokens(5 ether); // alice now holds 5 pass-quote + 5 fail-quote

        ConditionalToken passQuote = ConditionalVault(p.quoteVault).passToken();
        passQuote.approve(address(gov), 5 ether);
        gov.trade(id, DecisionMarketsGovernance.Market.Pass, DecisionMarketsGovernance.Side.Quote, 5 ether, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + defaultConfig().tradingPeriod + 1);
        gov.finalizeProposal(id);

        p = gov.getProposal(id);
        assertTrue(p.finalized);
        assertTrue(p.passed);
        assertTrue(p.passTWAP > p.failTWAP);

        // Resolution reached both vaults.
        assertTrue(ConditionalVault(p.baseVault).resolved());
        assertTrue(ConditionalVault(p.quoteVault).resolved());
        assertEq(ConditionalVault(p.baseVault).payoutPassNumerator(), 1);

        vm.warp(block.timestamp + defaultConfig().timelockDelay + 1);
        uint256 recipientBefore = recipient.balance;
        gov.executeProposal{value: 1 ether}(id);

        p = gov.getProposal(id);
        assertTrue(p.executed);
        assertEq(recipient.balance, recipientBefore + 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
            FULL LIFECYCLE: NO TRADING -> FAILS (BELOW THRESHOLD)
    //////////////////////////////////////////////////////////////*/

    function test_FullLifecycle_FailsWhenNeitherMarketClearsThreshold() public {
        // Symmetric seeding, nobody trades - both TWAPs stay identical,
        // and identical does not clear a positive threshold.
        uint256 id = _propose(1_000 ether, 10 ether);

        vm.warp(block.timestamp + defaultConfig().tradingPeriod + 1);
        gov.finalizeProposal(id);

        DecisionMarketsGovernance.Proposal memory p = gov.getProposal(id);
        assertTrue(p.finalized);
        assertFalse(p.passed);
        assertEq(p.passTWAP, p.failTWAP); // symmetric, untouched pools

        assertEq(ConditionalVault(p.baseVault).payoutPassNumerator(), 0);
        assertEq(ConditionalVault(p.baseVault).payoutFailNumerator(), 1);
    }

    function test_ExecuteProposal_RevertsIfProposalDidNotPass() public {
        uint256 id = _propose(1_000 ether, 10 ether);
        vm.warp(block.timestamp + defaultConfig().tradingPeriod + 1);
        gov.finalizeProposal(id);

        vm.expectRevert(DecisionMarketsGovernance.ProposalDidNotPass.selector);
        gov.executeProposal(id);
    }

    /*//////////////////////////////////////////////////////////////
                            FINALIZATION GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_FinalizeProposal_RevertsBeforeTradingDeadline() public {
        uint256 id = _propose(1_000 ether, 10 ether);
        vm.expectRevert(DecisionMarketsGovernance.TradingWindowStillOpen.selector);
        gov.finalizeProposal(id);
    }

    /// @dev The deadline check is the very first thing trade() does, before
    ///      any token transfer or pool interaction - so this needs no
    ///      approvals or conditional-token setup to reach the revert.
    function test_Trade_RevertsAfterTradingDeadline() public {
        uint256 id = _propose(1_000 ether, 10 ether);
        vm.warp(block.timestamp + defaultConfig().tradingPeriod + 1);

        vm.expectRevert(DecisionMarketsGovernance.TradingWindowClosed.selector);
        gov.trade(id, DecisionMarketsGovernance.Market.Pass, DecisionMarketsGovernance.Side.Quote, 5 ether, 0);
    }

    function test_FinalizeProposal_RevertsOnDoubleFinalize() public {
        uint256 id = _propose(1_000 ether, 10 ether);
        vm.warp(block.timestamp + defaultConfig().tradingPeriod + 1);
        gov.finalizeProposal(id);

        vm.expectRevert(DecisionMarketsGovernance.AlreadyFinalized.selector);
        gov.finalizeProposal(id);
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDITY RECLAMATION
    //////////////////////////////////////////////////////////////*/

    function test_ReclaimLiquidity_RevertsBeforeFinalization() public {
        uint256 id = _propose(1_000 ether, 10 ether);
        vm.expectRevert(DecisionMarketsGovernance.NotFinalized.selector);
        gov.reclaimLiquidity(id);
    }

    function test_ReclaimLiquidity_RevertsOnDoubleReclaim() public {
        uint256 id = _propose(1_000 ether, 10 ether);
        vm.warp(block.timestamp + defaultConfig().tradingPeriod + 1);
        gov.finalizeProposal(id);

        gov.reclaimLiquidity(id);

        vm.expectRevert(DecisionMarketsGovernance.AlreadyReclaimed.selector);
        gov.reclaimLiquidity(id);
    }

    function test_ReclaimLiquidity_SendsRecoveredValueToProposer() public {
        uint256 id = _propose(1_000 ether, 10 ether);
        vm.warp(block.timestamp + defaultConfig().tradingPeriod + 1);
        gov.finalizeProposal(id); // untouched pools, fails - still fully reclaimable

        uint256 proposerBaseBefore = govToken.balanceOf(proposer);
        uint256 proposerQuoteBefore = wmon.balanceOf(proposer);

        gov.reclaimLiquidity(id);

        // With no trading at all, essentially the full original seed
        // (minus the permanently-locked MINIMUM_LIQUIDITY sliver on each
        // pool) comes back - a large, clearly nonzero recovery, not just
        // dust.
        assertTrue(govToken.balanceOf(proposer) > proposerBaseBefore + 900 ether);
        assertTrue(wmon.balanceOf(proposer) > proposerQuoteBefore + 9 ether);
    }

    function test_ReclaimLiquidity_WorksRegardlessOfPassOrFail() public {
        // Pass-outcome scenario (mirrors test_FullLifecycle_PassWinsWhenTradedHigher).
        uint256 id = _propose(1_000 ether, 10 ether);
        DecisionMarketsGovernance.Proposal memory p = gov.getProposal(id);

        ConditionalVault quoteVault = ConditionalVault(p.quoteVault);
        vm.startPrank(alice);
        wmon.deposit{value: 5 ether}();
        wmon.approve(address(quoteVault), 5 ether);
        quoteVault.splitTokens(5 ether);
        ConditionalToken passQuote = ConditionalVault(p.quoteVault).passToken();
        passQuote.approve(address(gov), 5 ether);
        gov.trade(id, DecisionMarketsGovernance.Market.Pass, DecisionMarketsGovernance.Side.Quote, 5 ether, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + defaultConfig().tradingPeriod + 1);
        gov.finalizeProposal(id);

        p = gov.getProposal(id);
        assertTrue(p.passed);

        // Reclaiming should succeed cleanly even though the pools' ratios
        // are no longer equal, post-trade.
        gov.reclaimLiquidity(id);

        p = gov.getProposal(id);
        assertTrue(p.liquidityReclaimed);
    }

    /*//////////////////////////////////////////////////////////////
                    GOVERNANCE-ONLY ADMIN (self-call)
    //////////////////////////////////////////////////////////////*/

    function test_UpdateConfig_RevertsForExternalCaller() public {
        vm.expectRevert(DecisionMarketsGovernance.Unauthorized.selector);
        gov.updateConfig(defaultConfig());
    }
}
