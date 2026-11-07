// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {GovernanceToken} from "../src/token/GovernanceToken.sol";
import {StakedGovernanceToken} from "../src/token/StakedGovernanceToken.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";

import {Governance} from "../src/governance/Governance.sol";
import {ProposalThresholdNotMet} from "../src/governance/GovernanceErrors.sol";
import {QuadraticGovernance} from "../src/governance/quadratic/QuadraticGovernance.sol";
import {LiquidGovernance} from "../src/governance/liquid/LiquidGovernance.sol";
import {OptimisticGovernance} from "../src/governance/optimistic/OptimisticGovernance.sol";
import {SowellianGovernance} from "../src/governance/sowellian/SowellianGovernance.sol";
import {ConvictionGovernance} from "../src/governance/conviction/ConvictionGovernance.sol";
import {DelegateGovernance} from "../src/governance/delegate/DelegateGovernance.sol";
import {SortitionGovernance} from "../src/governance/sortition/SortitionGovernance.sol";
import {DecisionMarketsGovernance} from "../src/governance/futarchy/DecisionMarketsGovernance.sol";
import {BoardGovernance} from "../src/governance/board/BoardGovernance.sol";
import {ConditionalToken} from "../src/governance/futarchy/ConditionalToken.sol";
import {ConditionalVault} from "../src/governance/futarchy/ConditionalVault.sol";
import {DecisionMarketPair} from "../src/governance/futarchy/DecisionMarketPair.sol";

import {DAOFactory} from "../src/factory/DAOFactory.sol";
import {DAOFactoryLib} from "../src/factory/DAOFactoryLib.sol";
import {QuadraticDAOFactory} from "../src/factory/QuadraticDAOFactory.sol";
import {LiquidDAOFactory} from "../src/factory/LiquidDAOFactory.sol";
import {OptimisticDAOFactory} from "../src/factory/OptimisticDAOFactory.sol";
import {SowellianDAOFactory} from "../src/factory/SowellianDAOFactory.sol";
import {ConvictionDAOFactory} from "../src/factory/ConvictionDAOFactory.sol";
import {DelegateDAOFactory} from "../src/factory/DelegateDAOFactory.sol";
import {SortitionDAOFactory} from "../src/factory/SortitionDAOFactory.sol";
import {DecisionMarketsDAOFactory} from "../src/factory/DecisionMarketsDAOFactory.sol";
import {BoardDAOFactory} from "../src/factory/BoardDAOFactory.sol";
import {WrapperFactory} from "../src/wrapper/WrapperFactory.sol";
import {GuardWrapper} from "../src/wrapper/GuardWrapper.sol";
import {NFTMarketplaceWrapper} from "../src/marketplace/NFTMarketplaceWrapper.sol";
import {StakeConverter} from "../src/converter/StakeConverter.sol";

import "../src/governance/Types.sol";

contract SwitchRandomnessSource {
    function requestRandomness(bytes32) external payable {}
    function isFulfilled(bytes32) external pure returns (bool) {
        return false;
    }
    function getRandomness(bytes32) external pure returns (uint256) {
        return 0;
    }
}

/// @title ModelSwitchTest
/// @notice A DAO switching governance models: one proposal on the current
///         governance deploys the new one through the target factory's
///         createForSwitch() and hands it the Treasury, token and staking
///         contract. Members keep their staked balances and voting power.
contract ModelSwitchTest is Test {
    enum Model {
        TokenWeighted,
        Quadratic,
        Liquid,
        Optimistic,
        Sowellian,
        Conviction,
        Delegate,
        Sortition,
        DecisionMarkets,
        Board
    }

    DAOFactory internal twFactory;
    QuadraticDAOFactory internal quadraticFactory;
    LiquidDAOFactory internal liquidFactory;
    OptimisticDAOFactory internal optimisticFactory;
    SowellianDAOFactory internal sowellianFactory;
    ConvictionDAOFactory internal convictionFactory;
    DelegateDAOFactory internal delegateFactory;
    SortitionDAOFactory internal sortitionFactory;
    DecisionMarketsDAOFactory internal dmFactory;
    BoardDAOFactory internal boardFactory;
    SwitchRandomnessSource internal randomness;
    WrapperFactory internal wrapperFactory;

    Governance internal gov;
    Treasury internal treasury;
    StakedGovernanceToken internal staking;
    GovernanceToken internal token;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal recipient = makeAddr("recipient");
    address[] internal council;

    uint256 internal constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 internal constant MAX_SUPPLY = 10_000_000 ether;

    function setUp() public {
        address tokenImpl = address(new GovernanceToken());
        address stakingImpl = address(new StakedGovernanceToken());
        address treasuryImpl = address(new Treasury());

        twFactory = new DAOFactory(tokenImpl, stakingImpl, treasuryImpl, address(new Governance()));
        quadraticFactory =
            new QuadraticDAOFactory(tokenImpl, stakingImpl, treasuryImpl, address(new QuadraticGovernance()));
        liquidFactory = new LiquidDAOFactory(tokenImpl, stakingImpl, treasuryImpl, address(new LiquidGovernance()));
        optimisticFactory =
            new OptimisticDAOFactory(tokenImpl, stakingImpl, treasuryImpl, address(new OptimisticGovernance()));
        sowellianFactory =
            new SowellianDAOFactory(tokenImpl, stakingImpl, treasuryImpl, address(new SowellianGovernance()));
        convictionFactory =
            new ConvictionDAOFactory(tokenImpl, stakingImpl, treasuryImpl, address(new ConvictionGovernance()));
        delegateFactory =
            new DelegateDAOFactory(tokenImpl, stakingImpl, treasuryImpl, address(new DelegateGovernance()), address(0));
        sortitionFactory =
            new SortitionDAOFactory(tokenImpl, stakingImpl, treasuryImpl, address(new SortitionGovernance()));
        dmFactory = new DecisionMarketsDAOFactory(
            tokenImpl,
            stakingImpl,
            treasuryImpl,
            address(new DecisionMarketsGovernance()),
            makeAddr("wmon"),
            address(new ConditionalToken()),
            address(new ConditionalVault()),
            address(new DecisionMarketPair())
        );
        boardFactory = new BoardDAOFactory(treasuryImpl, address(new BoardGovernance()));
        randomness = new SwitchRandomnessSource();
        wrapperFactory = new WrapperFactory(
            address(new GuardWrapper()), address(new NFTMarketplaceWrapper()), address(new StakeConverter())
        );

        council.push(alice);
        council.push(bob);
        council.push(carol);

        vm.prank(creator);
        gov = Governance(twFactory.createDAO("Switch DAO", "SWD", INITIAL_SUPPLY, MAX_SUPPLY, twConfig()));
        treasury = Treasury(payable(gov.treasury()));
        staking = StakedGovernanceToken(gov.governanceToken());
        token = GovernanceToken(address(staking.underlying()));

        _stake(alice, 150_000 ether);
        _stake(bob, 100_000 ether);
        _stake(carol, 50_000 ether);
        vm.deal(address(treasury), 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIGS
    //////////////////////////////////////////////////////////////*/

    function twConfig() internal pure returns (GovernanceConfig memory) {
        return GovernanceConfig({
            quorumBps: 1_000,
            approvalThresholdBps: 6_000,
            votingDelay: 1,
            votingPeriod: 100,
            timelockDelay: 1 days,
            executionPeriod: 7 days,
            proposalThreshold: 1 ether
        });
    }

    function convictionConfig() internal pure returns (ConvictionGovernance.ConvictionGovernanceConfig memory) {
        return ConvictionGovernance.ConvictionGovernanceConfig({
            convictionGrowthRate: 1e15,
            minThresholdConviction: 100 ether,
            thresholdMultiplier: 10,
            proposalThreshold: 1 ether,
            timelockDelay: 1 days,
            executionPeriod: 7 days
        });
    }

    function boardConfig() internal pure returns (BoardGovernance.BoardGovernanceConfig memory) {
        return BoardGovernance.BoardGovernanceConfig({requiredApprovals: 2, timelockDelay: 1 days, executionPeriod: 7 days});
    }

    /// @dev The createForSwitch call for `model`, plus the factory to send
    ///      it to and the governance address it will deploy.
    function _deployCall(Model model, address previous)
        internal
        view
        returns (address factory, address predicted, bytes memory data)
    {
        address t = address(treasury);
        address u = address(token);
        address s = address(staking);
        if (model == Model.TokenWeighted) {
            factory = address(twFactory);
            predicted = twFactory.predictSwitchGovernance(previous);
            data = abi.encodeCall(twFactory.createForSwitch, ("Switch DAO", t, u, s, twConfig(), predicted));
        } else if (model == Model.Quadratic) {
            factory = address(quadraticFactory);
            predicted = quadraticFactory.predictSwitchGovernance(previous);
            QuadraticGovernance.QuadraticGovernanceConfig memory c = QuadraticGovernance.QuadraticGovernanceConfig({
                quorumBps: 1_000,
                approvalThresholdBps: 6_000,
                votingDelay: 1,
                votingPeriod: 100,
                timelockDelay: 1 days,
                executionPeriod: 7 days,
                proposalThreshold: 1 ether
            });
            data = abi.encodeCall(quadraticFactory.createForSwitch, ("Switch DAO", t, u, s, c, predicted));
        } else if (model == Model.Liquid) {
            factory = address(liquidFactory);
            predicted = liquidFactory.predictSwitchGovernance(previous);
            LiquidGovernance.LiquidGovernanceConfig memory c = LiquidGovernance.LiquidGovernanceConfig({
                quorumBps: 1_000,
                approvalThresholdBps: 6_000,
                votingDelay: 1,
                votingPeriod: 100,
                timelockDelay: 1 days,
                executionPeriod: 7 days,
                proposalThreshold: 1 ether
            });
            data = abi.encodeCall(liquidFactory.createForSwitch, ("Switch DAO", t, u, s, c, predicted));
        } else if (model == Model.Optimistic) {
            factory = address(optimisticFactory);
            predicted = optimisticFactory.predictSwitchGovernance(previous);
            OptimisticGovernance.OptimisticGovernanceConfig memory c = OptimisticGovernance
                .OptimisticGovernanceConfig({
                challengePeriod: 100,
                challengeBond: 100 ether,
                quorumBps: 1_000,
                approvalThresholdBps: 6_000,
                votingPeriod: 100,
                timelockDelay: 1 days,
                executionPeriod: 7 days,
                proposalThreshold: 1 ether
            });
            data = abi.encodeCall(optimisticFactory.createForSwitch, ("Switch DAO", t, u, s, c, predicted));
        } else if (model == Model.Sowellian) {
            factory = address(sowellianFactory);
            predicted = sowellianFactory.predictSwitchGovernance(previous);
            SowellianGovernance.SowellianConfig memory c = SowellianGovernance.SowellianConfig({
                proposalBondAmount: 100 ether,
                approvalVotingDelay: 1,
                approvalVotingPeriod: 100,
                approvalQuorumBps: 1_000,
                approvalThresholdBps: 6_000,
                positionsWindow: 7 days,
                executionTimelockDelay: 1 days,
                resolutionBondAmount: 100 ether,
                challengePeriod: 3 days,
                challengeBondAmount: 100 ether,
                adjudicationVotingPeriod: 100,
                adjudicationQuorumBps: 1_000,
                adjudicationThresholdBps: 6_000,
                maxOracleStaleness: 1 hours
            });
            data = abi.encodeCall(sowellianFactory.createForSwitch, ("Switch DAO", t, u, s, c, predicted));
        } else if (model == Model.Conviction) {
            factory = address(convictionFactory);
            predicted = convictionFactory.predictSwitchGovernance(previous);
            data = abi.encodeCall(
                convictionFactory.createForSwitch, ("Switch DAO", t, u, s, convictionConfig(), predicted)
            );
        } else if (model == Model.Delegate) {
            factory = address(delegateFactory);
            predicted = delegateFactory.predictSwitchGovernance(previous);
            DelegateGovernance.DelegateGovernanceConfig memory c = DelegateGovernance.DelegateGovernanceConfig({
                councilSize: 3,
                termLength: 30 days,
                candidacyThreshold: 0,
                candidacyPeriod: 100,
                electionVotingPeriod: 100,
                councilQuorum: 2,
                councilApprovalThresholdBps: 6_000,
                votingDelay: 1,
                votingPeriod: 100,
                timelockDelay: 1 days,
                executionPeriod: 7 days,
                recallQuorumBps: 1_000,
                recallApprovalThresholdBps: 6_000,
                recallVotingPeriod: 100
            });
            data = abi.encodeCall(delegateFactory.createForSwitch, ("Switch DAO", t, u, s, c, council, predicted));
        } else if (model == Model.Sortition) {
            factory = address(sortitionFactory);
            predicted = sortitionFactory.predictSwitchGovernance(previous);
            SortitionGovernance.SortitionGovernanceConfig memory c = SortitionGovernance.SortitionGovernanceConfig({
                councilSize: 3,
                termLength: 30 days,
                eligibilityThreshold: 0,
                councilQuorum: 2,
                councilApprovalThresholdBps: 6_000,
                votingDelay: 1,
                votingPeriod: 100,
                timelockDelay: 1 days,
                executionPeriod: 7 days
            });
            data = abi.encodeCall(
                sortitionFactory.createForSwitch, ("Switch DAO", t, u, s, address(randomness), c, council, predicted)
            );
        } else if (model == Model.DecisionMarkets) {
            factory = address(dmFactory);
            predicted = dmFactory.predictSwitchGovernance(previous);
            DecisionMarketsGovernance.DecisionMarketsConfig memory c = DecisionMarketsGovernance.DecisionMarketsConfig({
                tradingPeriod: 3 days,
                thresholdBps: 300,
                timelockDelay: 1 days,
                executionPeriod: 7 days
            });
            data = abi.encodeCall(dmFactory.createForSwitch, ("Switch DAO", t, u, s, c, predicted));
        } else {
            factory = address(boardFactory);
            predicted = boardFactory.predictSwitchGovernance(previous);
            data = abi.encodeCall(boardFactory.createForSwitch, ("Switch DAO", t, u, s, boardConfig(), council, predicted));
        }
    }

    /// @dev The whole switch, as the actions of one proposal on `previous`.
    function _switchActions(Model model, address previous)
        internal
        view
        returns (ProposalAction[] memory actions, address newGov)
    {
        (address factory, address predicted, bytes memory deploy) = _deployCall(model, previous);
        newGov = predicted;
        address locker = model == Model.Conviction ? newGov : address(0);

        actions = new ProposalAction[](5);
        actions[0] = ProposalAction(factory, 0, deploy);
        actions[1] = ProposalAction(address(treasury), 0, abi.encodeCall(Treasury.transferGovernance, (newGov)));
        actions[2] = ProposalAction(address(token), 0, abi.encodeWithSignature("transferOwnership(address)", newGov));
        actions[3] = ProposalAction(address(staking), 0, abi.encodeCall(StakedGovernanceToken.setAuthorizedLocker, (locker)));
        actions[4] = ProposalAction(address(staking), 0, abi.encodeCall(StakedGovernanceToken.transferOwnership, (newGov)));
    }

    /// @dev Runs the actions exactly as an executed proposal would: one
    ///      call each from the governance contract, all or nothing.
    function _executeAs(address governance, ProposalAction[] memory actions) internal {
        for (uint256 i = 0; i < actions.length; i++) {
            vm.prank(governance);
            (bool ok, bytes memory ret) = actions[i].target.call{value: actions[i].value}(actions[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function _switch(Model model, address previous) internal returns (address newGov) {
        ProposalAction[] memory actions;
        (actions, newGov) = _switchActions(model, previous);
        _executeAs(previous, actions);
    }

    function _stake(address account, uint256 amount) internal {
        vm.prank(creator);
        token.transfer(account, amount);
        vm.startPrank(account);
        token.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _assertHandedOver(address newGov) internal view {
        assertEq(treasury.governance(), newGov, "treasury");
        assertEq(token.owner(), newGov, "token");
        assertEq(staking.owner(), newGov, "staking");
    }

    /*//////////////////////////////////////////////////////////////
                    A REAL SWITCH PROPOSAL, END TO END
    //////////////////////////////////////////////////////////////*/

    function test_Switch_TokenWeightedToQuadratic_ThroughRealProposal() public {
        (ProposalAction[] memory actions, address newGov) = _switchActions(Model.Quadratic, address(gov));

        vm.prank(alice);
        uint256 id = gov.propose(actions, "ipfs://switch-to-quadratic");
        vm.roll(vm.getBlockNumber() + 2);
        vm.prank(alice);
        gov.castVote(id, VoteType.For);
        vm.prank(bob);
        gov.castVote(id, VoteType.For);
        vm.roll(gov.getProposal(id).endBlock + 1);
        gov.queueProposal(id);
        vm.warp(gov.executableAfter(id) + 1);
        gov.executeProposal(id);

        _assertHandedOver(newGov);
        QuadraticGovernance q = QuadraticGovernance(newGov);
        assertEq(q.governanceToken(), address(staking));
        assertEq(q.treasury(), address(treasury));
        assertEq(quadraticFactory.predecessorOf(newGov), address(gov));
        (,, address regStaking, address regToken, address regGov, address regTreasury,) =
            quadraticFactory.daos(quadraticFactory.daoCount());
        assertEq(regStaking, address(staking));
        assertEq(regToken, address(token));
        assertEq(regGov, newGov);
        assertEq(regTreasury, address(treasury));

        // Members keep their stake and voting power; nobody re-stakes.
        assertEq(staking.balanceOf(alice), 150_000 ether);
        assertEq(staking.getVotes(alice), 150_000 ether);

        // The old governance has lost the Treasury.
        vm.prank(address(gov));
        vm.expectRevert();
        treasury.transferETH(payable(recipient), 1 ether);
    }

    function test_Switch_NewGovernanceRunsItsOwnProposal() public {
        address newGov = _switch(Model.Quadratic, address(gov));
        QuadraticGovernance q = QuadraticGovernance(newGov);

        ProposalAction[] memory pay = new ProposalAction[](1);
        pay[0] = ProposalAction(
            address(treasury), 0, abi.encodeWithSelector(ITreasury.transferETH.selector, payable(recipient), 1 ether)
        );
        vm.prank(alice);
        uint256 id = q.propose(abi.decode(abi.encode(pay), (QuadraticGovernance.ProposalAction[])), "ipfs://pay");
        vm.roll(vm.getBlockNumber() + 2);
        vm.prank(alice);
        q.castVote(id, QuadraticGovernance.VoteType.For);
        vm.prank(bob);
        q.castVote(id, QuadraticGovernance.VoteType.For);
        vm.roll(q.getProposal(id).endBlock + 1);
        q.queueProposal(id);
        vm.warp(q.executableAfter(id) + 1);
        q.executeProposal(id);

        assertEq(recipient.balance, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        INTO EVERY MODEL
    //////////////////////////////////////////////////////////////*/

    function test_Switch_ToTokenWeighted() public {
        _assertHandedOver(_switch(Model.TokenWeighted, address(gov)));
    }

    function test_Switch_ToLiquid() public {
        address g = _switch(Model.Liquid, address(gov));
        _assertHandedOver(g);
        assertEq(LiquidGovernance(g).governanceToken(), address(staking));
    }

    function test_Switch_ToOptimistic() public {
        address g = _switch(Model.Optimistic, address(gov));
        _assertHandedOver(g);
        assertEq(OptimisticGovernance(g).governanceToken(), address(staking));
    }

    function test_Switch_ToSowellian() public {
        address g = _switch(Model.Sowellian, address(gov));
        _assertHandedOver(g);
        assertEq(SowellianGovernance(g).governanceToken(), address(staking));
    }

    function test_Switch_ToConviction() public {
        address g = _switch(Model.Conviction, address(gov));
        _assertHandedOver(g);
        assertEq(staking.authorizedLocker(), g);
        assertEq(ConvictionGovernance(g).governanceToken(), address(staking));
    }

    function test_Switch_ToDelegate() public {
        address g = _switch(Model.Delegate, address(gov));
        _assertHandedOver(g);
        assertEq(DelegateGovernance(g).governanceToken(), address(staking));
    }

    function test_Switch_ToSortition() public {
        address g = _switch(Model.Sortition, address(gov));
        _assertHandedOver(g);
        assertEq(SortitionGovernance(g).governanceToken(), address(staking));
    }

    function test_Switch_ToDecisionMarkets() public {
        address g = _switch(Model.DecisionMarkets, address(gov));
        _assertHandedOver(g);
        assertEq(DecisionMarketsGovernance(payable(g)).governanceToken(), address(staking));
    }

    function test_Switch_ToBoard_RecordsTokenForTheWayBack() public {
        address g = _switch(Model.Board, address(gov));
        _assertHandedOver(g);
        assertTrue(BoardGovernance(g).isSigner(alice));
        (,, address regStaking, address regToken,,,) = boardFactory.daos(boardFactory.daoCount());
        assertEq(regStaking, address(staking));
        assertEq(regToken, address(token));
    }

    /*//////////////////////////////////////////////////////////////
                    BOARD AND BACK, THROUGH A BOARD PROPOSAL
    //////////////////////////////////////////////////////////////*/

    function test_Switch_BoardBackToTokenWeighted_ThroughBoardProposal() public {
        BoardGovernance board = BoardGovernance(_switch(Model.Board, address(gov)));

        (ProposalAction[] memory actions, address newGov) = _switchActions(Model.TokenWeighted, address(board));
        vm.prank(alice);
        uint256 id = board.proposeTransaction(
            abi.decode(abi.encode(actions), (BoardGovernance.ProposalAction[])), "ipfs://back-to-token-weighted"
        );
        vm.prank(bob);
        board.confirmTransaction(id);
        vm.warp(block.timestamp + 1 days + 1);
        board.executeTransaction(id);

        _assertHandedOver(newGov);
        assertEq(twFactory.predecessorOf(newGov), address(board));
        assertEq(staking.getVotes(alice), 150_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                CONVICTION LOCKS SURVIVE A SWITCH AWAY
    //////////////////////////////////////////////////////////////*/

    function test_Switch_AwayFromConviction_SupportersCanStillUnlock() public {
        ConvictionGovernance conviction = ConvictionGovernance(_switch(Model.Conviction, address(gov)));

        ProposalAction[] memory pay = new ProposalAction[](1);
        pay[0] = ProposalAction(
            address(treasury), 0, abi.encodeWithSelector(ITreasury.transferETH.selector, payable(recipient), 0)
        );
        vm.prank(alice);
        uint256 id = conviction.propose(abi.decode(abi.encode(pay), (ConvictionGovernance.ProposalAction[])), "ipfs://c");
        // A lock needs the member's consent.
        vm.prank(alice);
        vm.expectRevert(StakedGovernanceToken.LockerNotApproved.selector);
        conviction.support(id);
        vm.prank(alice);
        staking.approveLocker(address(conviction), true);
        vm.prank(alice);
        conviction.support(id);
        assertEq(staking.lockedBalance(alice), 150_000 ether);

        address next = _switch(Model.TokenWeighted, address(conviction));
        _assertHandedOver(next);
        assertEq(staking.authorizedLocker(), address(0));

        // Still locked until Alice takes her support back from the old
        // governance, which can release what it locked but lock nothing new.
        vm.prank(alice);
        vm.expectRevert(StakedGovernanceToken.InsufficientUnlockedBalance.selector);
        staking.unstake(1 ether);

        vm.prank(alice);
        conviction.withdrawSupport();
        assertEq(staking.lockedBalance(alice), 0);

        vm.prank(alice);
        vm.expectRevert(StakedGovernanceToken.Unauthorized.selector);
        conviction.support(id);

        vm.prank(alice);
        staking.unstake(1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            SAFETY CHECKS
    //////////////////////////////////////////////////////////////*/

    function test_Switch_RevertsWhenCallerDoesNotControlTreasury() public {
        (address factory,, bytes memory data) = _deployCall(Model.Quadratic, alice);
        vm.prank(alice);
        (bool ok, bytes memory ret) = factory.call(data);
        assertFalse(ok);
        assertEq(bytes4(ret), DAOFactoryLib.NotTreasuryGovernance.selector);
    }

    function test_Switch_RevertsWhenAddressIsNotThePredictedOne() public {
        GovernanceConfig memory c = twConfig();
        vm.prank(address(gov));
        vm.expectRevert(DAOFactoryLib.UnexpectedGovernanceAddress.selector);
        twFactory.createForSwitch("Switch DAO", address(treasury), address(token), address(staking), c, alice);
    }

    function test_Switch_RevertsWhenStakingWrapsAnotherToken() public {
        GovernanceConfig memory c = twConfig();
        address predicted = twFactory.predictSwitchGovernance(address(gov));
        vm.prank(address(gov));
        vm.expectRevert(DAOFactoryLib.StakingTokenMismatch.selector);
        twFactory.createForSwitch("Switch DAO", address(treasury), makeAddr("other"), address(staking), c, predicted);
    }

    function test_Switch_IntoConviction_RevertsWithoutStakingOwnership() public {
        // As for DAOs created before factories handed staking to governance.
        vm.prank(address(gov));
        staking.transferOwnership(makeAddr("oldFactory"));

        (ProposalAction[] memory actions,) = _switchActions(Model.Conviction, address(gov));
        ProposalAction[] memory deployOnly = new ProposalAction[](1);
        deployOnly[0] = actions[0];
        vm.expectRevert(DAOFactoryLib.StakingNotOwned.selector);
        this.executeAsExternal(address(gov), deployOnly);
    }

    function test_Switch_WithoutStakingOwnership_OtherModelsStillWork() public {
        vm.prank(address(gov));
        staking.transferOwnership(makeAddr("oldFactory"));

        (ProposalAction[] memory actions, address newGov) = _switchActions(Model.Quadratic, address(gov));
        ProposalAction[] memory noStaking = new ProposalAction[](3);
        for (uint256 i = 0; i < 3; i++) noStaking[i] = actions[i];
        _executeAs(address(gov), noStaking);

        assertEq(treasury.governance(), newGov);
        assertEq(QuadraticGovernance(newGov).governanceToken(), address(staking));
    }

    function test_Switch_PredictionMovesOnAfterEachSwitch() public {
        address first = twFactory.predictSwitchGovernance(address(gov));
        address quad = _switch(Model.Quadratic, address(gov));
        address back = _switch(Model.TokenWeighted, quad);
        assertTrue(back != first);
        // gov regains nothing; a second switch from quad to the same
        // factory gets a fresh address.
        assertTrue(twFactory.predictSwitchGovernance(quad) != back);
        assertEq(twFactory.switchNonce(quad), 1);
    }

    function test_Switch_StaleProposalCannotRunAfterAnotherSwitch() public {
        (ProposalAction[] memory stale,) = _switchActions(Model.Liquid, address(gov));
        _switch(Model.Quadratic, address(gov));

        vm.expectRevert(DAOFactoryLib.NotTreasuryGovernance.selector);
        this.executeAsExternal(address(gov), stale);
    }

    function test_CreateDAO_HandsStakingToGovernance() public view {
        assertEq(staking.owner(), address(gov));
    }

    /*//////////////////////////////////////////////////////////////
            CHANGING THE TOKEN WITHOUT CHANGING GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @dev One proposal's actions: a new token (supply to the Treasury)
    ///      and its staking contract, then the governance pointed at it.
    function _tokenChangeActions(address governance, bytes32 salt)
        internal
        view
        returns (ProposalAction[] memory actions, address newToken, address newStaking)
    {
        (newToken, newStaking) = twFactory.predictTokenForSwitch(governance, salt);
        actions = new ProposalAction[](2);
        actions[0] = ProposalAction(
            address(twFactory),
            0,
            abi.encodeCall(twFactory.createTokenForSwitch, ("New Token", "NEW", 1_000_000 ether, MAX_SUPPLY, address(treasury), salt))
        );
        actions[1] = ProposalAction(governance, 0, abi.encodeCall(Governance.setGovernanceToken, (newStaking)));
    }

    /// @dev Gives `account` `amount` of `newToken` from the Treasury and stakes it in `newStaking`.
    function _stakeNew(address newToken, address newStaking, address account, uint256 amount) internal {
        vm.prank(address(treasury));
        GovernanceToken(newToken).transfer(account, amount);
        vm.startPrank(account);
        GovernanceToken(newToken).approve(newStaking, amount);
        StakedGovernanceToken(newStaking).stake(amount);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
    }

    function test_TokenChange_OpenProposalsKeepTheirToken() public {
        ProposalAction[] memory pay = new ProposalAction[](1);
        pay[0] = ProposalAction(address(treasury), 0, abi.encodeCall(Treasury.transferETH, (payable(recipient), 1 ether)));
        vm.prank(alice);
        uint256 open = gov.propose(pay, "ipfs://open");
        assertEq(gov.proposalToken(open), address(staking));

        (ProposalAction[] memory change, address newToken, address newStaking) = _tokenChangeActions(address(gov), "t1");
        _executeAs(address(gov), change);
        assertEq(gov.governanceToken(), newStaking, "same governance, new token");
        assertEq(GovernanceToken(newToken).balanceOf(address(treasury)), 1_000_000 ether);
        assertEq(GovernanceToken(newToken).owner(), address(gov));
        assertEq(StakedGovernanceToken(newStaking).owner(), address(gov));
        assertEq(address(StakedGovernanceToken(newStaking).underlying()), newToken);

        // The open proposal still votes and counts quorum in the old token.
        vm.roll(vm.getBlockNumber() + 2);
        vm.prank(alice);
        assertEq(gov.castVote(open, VoteType.For), 150_000 ether);
        vm.roll(vm.getBlockNumber() + 101);
        gov.queueProposal(open);
        vm.warp(block.timestamp + 1 days + 1);
        gov.executeProposal(open);
        assertEq(recipient.balance, 1 ether);

        // New proposals need stake in the new token.
        vm.prank(alice);
        vm.expectRevert(ProposalThresholdNotMet.selector);
        gov.propose(pay, "ipfs://needs-new-stake");
        _stakeNew(newToken, newStaking, alice, 10 ether);
        vm.prank(alice);
        uint256 next = gov.propose(pay, "ipfs://new-token");
        assertEq(gov.proposalToken(next), newStaking);

        // Old stake is still the members' to take out.
        vm.prank(bob);
        staking.unstake(100_000 ether);
        assertEq(token.balanceOf(bob), 100_000 ether);
    }

    function test_TokenChange_ConverterMovesStakeAcross() public {
        (ProposalAction[] memory change, address newToken, address newStaking) = _tokenChangeActions(address(gov), "t2");
        address converter = wrapperFactory.predictConverter(address(gov), "c");
        ProposalAction[] memory actions = new ProposalAction[](4);
        actions[0] = change[0];
        actions[1] = change[1];
        actions[2] = ProposalAction(
            address(wrapperFactory),
            0,
            abi.encodeCall(wrapperFactory.createConverter, (address(staking), newStaking, 2, 1, address(treasury), "c"))
        );
        actions[3] = ProposalAction(address(treasury), 0, abi.encodeCall(Treasury.transferERC20, (newToken, converter, 250_000 ether)));
        _executeAs(address(gov), actions);
        StakeConverter c = StakeConverter(converter);
        assertTrue(c.open());

        // Alice converts 100k old stake into 200k new, in one call.
        vm.startPrank(alice);
        staking.approve(converter, 100_000 ether);
        assertEq(c.convert(100_000 ether), 200_000 ether);
        vm.stopPrank();
        assertEq(staking.balanceOf(alice), 50_000 ether);
        assertEq(StakedGovernanceToken(newStaking).balanceOf(alice), 200_000 ether);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(StakedGovernanceToken(newStaking).getVotes(alice), 200_000 ether);
        assertEq(token.balanceOf(address(treasury)), 100_000 ether, "the old tokens go to the Treasury");

        // Only what's funded: 50k left buys 25k old.
        vm.startPrank(bob);
        staking.approve(converter, 100_000 ether);
        vm.expectRevert(StakeConverter.Underfunded.selector);
        c.convert(100_000 ether);
        c.convert(25_000 ether);
        vm.stopPrank();

        vm.prank(carol);
        staking.approve(converter, 1 ether);

        // Only the DAO closes it; what's left goes back to the Treasury.
        vm.prank(alice);
        vm.expectRevert(StakeConverter.Unauthorized.selector);
        c.close();
        uint256 before = GovernanceToken(newToken).balanceOf(address(treasury));
        vm.prank(address(gov));
        c.close();
        assertEq(GovernanceToken(newToken).balanceOf(converter), 0);
        assertEq(GovernanceToken(newToken).balanceOf(address(treasury)), before);
        vm.prank(carol);
        vm.expectRevert(StakeConverter.ConverterClosed.selector);
        c.convert(1 ether);
    }

    function test_TokenChange_ConvictionLocksStayOnTheirToken() public {
        ConvictionGovernance conviction = ConvictionGovernance(_switch(Model.Conviction, address(gov)));
        ProposalAction[] memory pay = new ProposalAction[](1);
        pay[0] = ProposalAction(address(treasury), 0, abi.encodeCall(Treasury.transferETH, (payable(recipient), 0)));
        ConvictionGovernance.ProposalAction[] memory cpay = abi.decode(abi.encode(pay), (ConvictionGovernance.ProposalAction[]));
        vm.prank(alice);
        uint256 old = conviction.propose(cpay, "ipfs://old");
        vm.startPrank(alice);
        staking.approveLocker(address(conviction), true);
        conviction.support(old);
        vm.stopPrank();

        // New token, its staking contract locked by the same governance.
        (address newToken, address newStaking) = convictionFactory.predictTokenForSwitch(address(conviction), "t3");
        ProposalAction[] memory change = new ProposalAction[](3);
        change[0] = ProposalAction(
            address(convictionFactory),
            0,
            abi.encodeCall(convictionFactory.createTokenForSwitch, ("New", "NEW", 1_000_000 ether, MAX_SUPPLY, address(treasury), "t3"))
        );
        change[1] = ProposalAction(newStaking, 0, abi.encodeCall(StakedGovernanceToken.setAuthorizedLocker, (address(conviction))));
        change[2] = ProposalAction(address(conviction), 0, abi.encodeCall(ConvictionGovernance.setGovernanceToken, (newStaking)));
        _executeAs(address(conviction), change);

        _stakeNew(newToken, newStaking, alice, 10 ether);
        vm.prank(alice);
        uint256 fresh = conviction.propose(cpay, "ipfs://new");
        assertEq(conviction.proposalToken(fresh), newStaking);

        // Moving support releases the old token's lock and locks the new one.
        vm.startPrank(alice);
        StakedGovernanceToken(newStaking).approveLocker(address(conviction), true);
        conviction.support(fresh);
        vm.stopPrank();
        assertEq(staking.lockedBalance(alice), 0);
        assertEq(StakedGovernanceToken(newStaking).lockedBalance(alice), 10 ether);
        vm.prank(alice);
        conviction.withdrawSupport();
        assertEq(StakedGovernanceToken(newStaking).lockedBalance(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        BOARD AND THE DAO'S TOKEN
    //////////////////////////////////////////////////////////////*/

    function test_Board_KeepsTheTokenAndChangesIt() public {
        BoardGovernance board = BoardGovernance(_switch(Model.Board, address(gov)));
        assertEq(board.governanceToken(), address(staking));
        assertEq(board.underlyingToken(), address(token));

        (address newToken, address newStaking) = twFactory.predictTokenForSwitch(address(board), "b1");
        ProposalAction[] memory change = new ProposalAction[](2);
        change[0] = ProposalAction(
            address(twFactory),
            0,
            abi.encodeCall(twFactory.createTokenForSwitch, ("New", "NEW", 1_000_000 ether, MAX_SUPPLY, address(treasury), "b1"))
        );
        change[1] = ProposalAction(address(board), 0, abi.encodeCall(BoardGovernance.setGovernanceToken, (newStaking)));
        _executeAs(address(board), change);
        assertEq(board.governanceToken(), newStaking);
        assertEq(board.underlyingToken(), newToken);

        vm.expectRevert(BoardGovernance.Unauthorized.selector);
        board.setGovernanceToken(address(staking));
    }

    function test_BoardBornDAO_SwitchesIntoATokenModelWithANewToken() public {
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;
        vm.prank(creator);
        BoardGovernance board = BoardGovernance(boardFactory.createDAO("Board-born", boardConfig(), signers));
        Treasury t = Treasury(payable(board.treasury()));
        assertEq(board.governanceToken(), address(0));

        (address newToken, address newStaking) = twFactory.predictTokenForSwitch(address(board), "born");
        address predicted = twFactory.predictSwitchGovernance(address(board));
        ProposalAction[] memory actions = new ProposalAction[](5);
        actions[0] = ProposalAction(
            address(twFactory),
            0,
            abi.encodeCall(twFactory.createTokenForSwitch, ("Born", "BRN", 1_000_000 ether, MAX_SUPPLY, address(t), "born"))
        );
        actions[1] = ProposalAction(
            address(twFactory), 0, abi.encodeCall(twFactory.createForSwitch, ("Board-born", address(t), newToken, newStaking, twConfig(), predicted))
        );
        actions[2] = ProposalAction(address(t), 0, abi.encodeCall(Treasury.transferGovernance, (predicted)));
        actions[3] = ProposalAction(newToken, 0, abi.encodeWithSignature("transferOwnership(address)", predicted));
        actions[4] = ProposalAction(newStaking, 0, abi.encodeCall(StakedGovernanceToken.transferOwnership, (predicted)));
        _executeAs(address(board), actions);

        Governance g = Governance(predicted);
        assertEq(t.governance(), predicted);
        assertEq(g.governanceToken(), newStaking);
        assertEq(GovernanceToken(newToken).owner(), predicted);
        assertEq(StakedGovernanceToken(newStaking).owner(), predicted);
        assertEq(GovernanceToken(newToken).balanceOf(address(t)), 1_000_000 ether, "the supply sits in the Treasury");
    }

    /*//////////////////////////////////////////////////////////////
                    THE SECURITY COUNCIL (GUARDWRAPPER)
    //////////////////////////////////////////////////////////////*/

    /// @dev Turns a 2-of-3 council on in one proposal: create the wrapper,
    ///      hand it the Treasury, token and staking contract.
    function _councilOn(address governance) internal returns (GuardWrapper w) {
        address predicted = wrapperFactory.predictGuardWrapper(governance, "council");
        ProposalAction[] memory actions = new ProposalAction[](4);
        actions[0] = ProposalAction(
            address(wrapperFactory), 0, abi.encodeCall(wrapperFactory.createGuardWrapper, (governance, council, 2, 30 days, "council"))
        );
        actions[1] = ProposalAction(address(treasury), 0, abi.encodeCall(Treasury.transferGovernance, (predicted)));
        actions[2] = ProposalAction(address(token), 0, abi.encodeWithSignature("transferOwnership(address)", predicted));
        actions[3] = ProposalAction(address(staking), 0, abi.encodeCall(StakedGovernanceToken.transferOwnership, (predicted)));
        _executeAs(governance, actions);
        w = GuardWrapper(payable(predicted));
    }

    function _batch(GuardWrapper w, address governance, GuardWrapper.Call[] memory calls) internal returns (uint256 id) {
        vm.prank(governance);
        id = w.proposeBatch(calls);
    }

    function test_Council_OnInOneProposal_AndTreasuryActionsNeedIt() public {
        GuardWrapper w = _councilOn(address(gov));
        assertTrue(wrapperFactory.isFromFactory(address(w)));
        assertEq(w.governance(), address(gov));
        _assertHandedOver(address(w));

        // Governance alone can't move funds any more.
        vm.prank(address(gov));
        vm.expectRevert();
        treasury.transferETH(payable(recipient), 1 ether);

        vm.prank(address(gov));
        uint256 id = w.proposeInstruction(address(treasury), 0, abi.encodeCall(Treasury.transferETH, (payable(recipient), 1 ether)));
        vm.prank(alice);
        w.confirmInstruction(id);
        assertEq(recipient.balance, 0, "1 of 2");
        vm.prank(bob);
        w.confirmInstruction(id);
        assertEq(recipient.balance, 1 ether);
    }

    function test_Council_SwitchKeepsTheCouncil() public {
        GuardWrapper w = _councilOn(address(gov));
        (address factory, address next, bytes memory deploy) = _deployCall(Model.Conviction, address(gov));

        // The factory accepts a caller whose Treasury answers to its council.
        vm.prank(address(gov));
        (bool ok,) = factory.call(deploy);
        assertTrue(ok);

        GuardWrapper.Call[] memory calls = new GuardWrapper.Call[](2);
        calls[0] = GuardWrapper.Call(address(w), 0, abi.encodeCall(GuardWrapper.setGovernance, (next)));
        calls[1] = GuardWrapper.Call(address(staking), 0, abi.encodeCall(StakedGovernanceToken.setAuthorizedLocker, (next)));
        uint256 id = _batch(w, address(gov), calls);
        assertEq(w.governance(), address(gov), "nothing until the council confirms");
        vm.prank(alice);
        w.confirmInstruction(id);
        vm.prank(carol);
        w.confirmInstruction(id);

        assertEq(w.governance(), next, "one step");
        assertEq(staking.authorizedLocker(), next);
        _assertHandedOver(address(w));

        // The new governance works through the same council.
        vm.prank(next);
        id = w.proposeInstruction(address(treasury), 0, abi.encodeCall(Treasury.transferETH, (payable(recipient), 2 ether)));
        vm.prank(bob);
        w.confirmInstruction(id);
        vm.prank(carol);
        w.confirmInstruction(id);
        assertEq(recipient.balance, 2 ether);
    }

    function test_Council_RejectedSwitchChangesNothing() public {
        GuardWrapper w = _councilOn(address(gov));
        (address factory, address next, bytes memory deploy) = _deployCall(Model.Quadratic, address(gov));
        vm.prank(address(gov));
        (bool ok,) = factory.call(deploy);
        assertTrue(ok);
        GuardWrapper.Call[] memory calls = new GuardWrapper.Call[](1);
        calls[0] = GuardWrapper.Call(address(w), 0, abi.encodeCall(GuardWrapper.setGovernance, (next)));
        uint256 id = _batch(w, address(gov), calls);
        vm.prank(alice);
        w.rejectInstruction(id);
        vm.prank(bob);
        w.rejectInstruction(id);
        vm.prank(carol);
        vm.expectRevert(GuardWrapper.InstructionAlreadyRejected.selector);
        w.confirmInstruction(id);
        assertEq(w.governance(), address(gov), "the new governance controls nothing");
    }

    function test_Council_OffNeedsTheCouncil_OrANewOneAfterTenure() public {
        GuardWrapper w = _councilOn(address(gov));
        GuardWrapper.Call[] memory off = new GuardWrapper.Call[](3);
        off[0] = GuardWrapper.Call(address(treasury), 0, abi.encodeCall(Treasury.transferGovernance, (address(gov))));
        off[1] = GuardWrapper.Call(address(token), 0, abi.encodeWithSignature("transferOwnership(address)", address(gov)));
        off[2] = GuardWrapper.Call(address(staking), 0, abi.encodeCall(StakedGovernanceToken.transferOwnership, (address(gov))));
        uint256 id = _batch(w, address(gov), off);
        vm.prank(alice);
        w.rejectInstruction(id);
        vm.prank(bob);
        w.rejectInstruction(id);
        _assertHandedOver(address(w));

        // Governance can't replace the signers before their tenure ends...
        address[] memory fresh = new address[](1);
        fresh[0] = recipient;
        vm.prank(address(gov));
        vm.expectRevert(GuardWrapper.TenureNotYetEnded.selector);
        w.replaceSigners(fresh, 1);

        // ...but can after, without them, and the new council turns it off.
        vm.warp(block.timestamp + 30 days);
        vm.prank(address(gov));
        w.replaceSigners(fresh, 1);
        id = _batch(w, address(gov), off);
        vm.prank(recipient);
        w.confirmInstruction(id);
        _assertHandedOver(address(gov));
    }

    function test_Council_BatchIsAllOrNothing() public {
        GuardWrapper w = _councilOn(address(gov));
        GuardWrapper.Call[] memory calls = new GuardWrapper.Call[](2);
        calls[0] = GuardWrapper.Call(address(treasury), 0, abi.encodeCall(Treasury.transferETH, (payable(recipient), 1 ether)));
        calls[1] = GuardWrapper.Call(address(treasury), 0, abi.encodeCall(Treasury.transferETH, (payable(recipient), 100 ether)));
        uint256 id = _batch(w, address(gov), calls);
        vm.prank(alice);
        w.confirmInstruction(id);
        vm.prank(bob);
        vm.expectRevert(GuardWrapper.ExecutionFailed.selector);
        w.confirmInstruction(id);
        assertEq(recipient.balance, 0);

        vm.expectRevert(GuardWrapper.Unauthorized.selector);
        w.runBatch(calls);
        vm.prank(alice);
        vm.expectRevert(GuardWrapper.Unauthorized.selector);
        w.proposeBatch(calls);
    }

    function test_Wrappers_AreClonesAtPredictedAddresses() public {
        address nft = wrapperFactory.predictNFTWrapper(address(gov), "n");
        vm.prank(address(gov));
        assertEq(wrapperFactory.createNFTWrapper(address(gov), address(treasury), "n"), nft);
        assertEq(NFTMarketplaceWrapper(payable(nft)).governance(), address(gov));
        assertLt(nft.code.length, 100, "a minimal proxy");

        // A switch hands the NFT wrapper over too.
        vm.prank(address(gov));
        NFTMarketplaceWrapper(payable(nft)).setGovernance(alice);
        assertEq(NFTMarketplaceWrapper(payable(nft)).governance(), alice);

        // Implementations can't be taken over.
        GuardWrapper impl = GuardWrapper(payable(wrapperFactory.guardWrapperImplementation()));
        vm.expectRevert();
        impl.initialize(alice, council, 1, 1 days);
    }

    function executeAsExternal(address governance, ProposalAction[] memory actions) external {
        _executeAs(governance, actions);
    }
}
