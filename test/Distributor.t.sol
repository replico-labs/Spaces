// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Distributor} from "../src/distribution/Distributor.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {DistributionFactory} from "../src/distribution/DistributionFactory.sol";
import {Raise} from "../src/distribution/Raise.sol";

contract DistToken is ERC20 {
    constructor() ERC20("Dist", "DST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for Delegate governance: a council.
contract CouncilGov {
    mapping(address => bool) public isCouncilMember;

    function seat(address who) external {
        isCouncilMember[who] = true;
    }
}

/// @dev Stands in for a security council's wrapper.
contract Wrapper {
    address public governance;

    constructor(address g) {
        governance = g;
    }
}

contract DistributorTest is Test {
    Distributor internal dist;
    Treasury internal treasury;
    DistToken internal token;
    CouncilGov internal gov;

    address internal operator = makeAddr("operator");
    address internal raise = makeAddr("raise");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal councillor = makeAddr("councillor");
    bytes32 internal constant ALICE_ACCOUNT = keccak256("telegram:1001");
    bytes32 internal constant BOB_ACCOUNT = keccak256("telegram:1002");

    function setUp() public {
        gov = new CouncilGov();
        gov.seat(councillor);
        treasury = Treasury(payable(Clones.clone(address(new Treasury()))));
        treasury.initialize(address(gov));
        token = new DistToken();
        dist = Distributor(Clones.clone(address(new Distributor())));
        address[] memory allocators = new address[](1);
        allocators[0] = raise;
        dist.initialize(address(token), address(treasury), operator, allocators, uint64(block.timestamp + 400 days));
        token.mint(address(dist), 1_000 ether);
    }

    function test_AdminFollowsTheTreasury() public {
        assertEq(dist.admin(), address(gov));
        assertEq(dist.governanceContract(), address(gov));
        Wrapper w = new Wrapper(address(gov));
        vm.prank(address(gov));
        treasury.transferGovernance(address(w));
        assertEq(dist.admin(), address(w), "a council's wrapper administers it");
        assertEq(dist.governanceContract(), address(gov), "and the governance is found through it");
    }

    function test_AllocatorsAndAdminAllocate_OthersCannot() public {
        vm.prank(raise);
        dist.allocate(alice, ALICE_ACCOUNT, 100 ether, uint64(block.timestamp), 0, 0);
        vm.prank(address(gov));
        dist.allocate(bob, bytes32(0), 100 ether, uint64(block.timestamp), 0, 0);
        vm.prank(alice);
        vm.expectRevert(Distributor.Unauthorized.selector);
        dist.allocate(alice, bytes32(0), 1 ether, uint64(block.timestamp), 0, 0);
        assertEq(dist.outstanding(), 200 ether);
        assertEq(dist.unpromised(), 800 ether);
    }

    function test_CannotPromiseMoreThanItHolds() public {
        vm.prank(raise);
        vm.expectRevert(abi.encodeWithSelector(Distributor.NotFunded.selector, 1_000 ether, 1_001 ether));
        dist.allocate(alice, bytes32(0), 1_001 ether, uint64(block.timestamp), 0, 0);
    }

    function test_OwnerClaimsAndVestingIsLinearAfterTheCliff() public {
        uint64 start = uint64(block.timestamp);
        vm.prank(raise);
        uint256 id = dist.allocate(alice, bytes32(0), 120 ether, start, 30 days, 120 days);

        vm.prank(alice);
        vm.expectRevert(Distributor.NothingToClaim.selector);
        dist.claim(id);

        vm.warp(start + 30 days);
        assertEq(dist.claimable(id), 30 ether, "a quarter at the cliff");
        vm.prank(alice);
        dist.claim(id);
        vm.warp(start + 60 days);
        vm.prank(alice);
        dist.claim(id);
        assertEq(token.balanceOf(alice), 60 ether);
        vm.warp(start + 200 days);
        vm.prank(alice);
        dist.claim(id);
        assertEq(token.balanceOf(alice), 120 ether);
        assertEq(dist.outstanding(), 0);

        vm.prank(bob);
        vm.expectRevert(Distributor.Unauthorized.selector);
        dist.claim(id);
    }

    function test_OperatorClaimsAnAccountIntoTheMembersWallet() public {
        vm.prank(raise);
        uint256 id = dist.allocate(address(0), ALICE_ACCOUNT, 50 ether, uint64(block.timestamp), 0, 0);
        address wallet = makeAddr("aliceProteanWallet");
        vm.prank(alice);
        vm.expectRevert(Distributor.Unauthorized.selector);
        dist.claimFor(id, wallet);
        vm.prank(operator);
        dist.claimFor(id, wallet);
        assertEq(token.balanceOf(wallet), 50 ether);

        // An address-only allocation can't be redirected by the operator.
        vm.prank(raise);
        uint256 own = dist.allocate(bob, bytes32(0), 5 ether, uint64(block.timestamp), 0, 0);
        vm.prank(operator);
        vm.expectRevert(Distributor.NotForAccounts.selector);
        dist.claimFor(own, wallet);
    }

    function test_WelcomeGrants_ApprovedByACouncilMember() public {
        vm.prank(councillor);
        vm.expectRevert(Distributor.WelcomeOff.selector);
        dist.grantWelcome(alice, ALICE_ACCOUNT);

        vm.prank(address(gov));
        dist.setWelcome(10 ether, 15 ether);

        vm.prank(alice);
        vm.expectRevert(Distributor.NotCouncilMember.selector);
        dist.grantWelcome(alice, ALICE_ACCOUNT);

        vm.prank(councillor);
        uint256 id = dist.grantWelcome(alice, ALICE_ACCOUNT);
        vm.prank(alice);
        dist.claim(id);
        assertEq(token.balanceOf(alice), 10 ether);

        vm.prank(councillor);
        vm.expectRevert(Distributor.AlreadyWelcomed.selector);
        dist.grantWelcome(makeAddr("aliceAgain"), ALICE_ACCOUNT);

        vm.prank(councillor);
        vm.expectRevert(Distributor.WelcomeCapReached.selector);
        dist.grantWelcome(bob, BOB_ACCOUNT);
    }

    function test_WelcomeGrants_ThroughACouncilWrapper() public {
        vm.prank(address(gov));
        dist.setWelcome(10 ether, 100 ether);
        Wrapper w = new Wrapper(address(gov));
        vm.prank(address(gov));
        treasury.transferGovernance(address(w));
        vm.prank(councillor);
        dist.grantWelcome(bob, BOB_ACCOUNT);
        assertEq(dist.outstanding(), 10 ether);
    }

    function test_ReturnAndClose() public {
        vm.prank(raise);
        dist.allocate(alice, bytes32(0), 100 ether, uint64(block.timestamp), 0, 0);
        vm.prank(address(gov));
        dist.returnUnpromised();
        assertEq(token.balanceOf(address(treasury)), 900 ether);
        assertEq(token.balanceOf(address(dist)), 100 ether, "promised tokens stay");

        uint64 deadline = dist.claimDeadline();
        vm.prank(address(gov));
        vm.expectRevert(abi.encodeWithSelector(Distributor.TooEarly.selector, deadline));
        dist.close();

        vm.warp(dist.claimDeadline());
        vm.prank(address(gov));
        dist.close();
        assertEq(token.balanceOf(address(treasury)), 1_000 ether);
        vm.prank(alice);
        vm.expectRevert(Distributor.DistributorClosed.selector);
        dist.claim(1);
    }

    function test_OnlyAdminConfigures() public {
        vm.startPrank(alice);
        vm.expectRevert(Distributor.Unauthorized.selector);
        dist.setWelcome(1, 1);
        vm.expectRevert(Distributor.Unauthorized.selector);
        dist.setAllocator(alice, true);
        vm.expectRevert(Distributor.Unauthorized.selector);
        dist.setOperator(alice);
        vm.expectRevert(Distributor.Unauthorized.selector);
        dist.returnUnpromised();
        vm.stopPrank();
    }

    function test_FactoryMakesOneAtThePredictedAddress() public {
        DistributionFactory f = new DistributionFactory(address(new Distributor()), address(new Raise()));
        address[] memory none = new address[](0);
        address predicted = f.predictDistributor(alice, address(token), address(treasury), operator, none, bytes32("x"));
        vm.prank(alice);
        address made = f.createDistributor(address(token), address(treasury), operator, none, 0, bytes32("x"));
        assertEq(made, predicted);
        assertTrue(f.isFromFactory(made));
        assertEq(Distributor(made).operator(), operator);
        // Another operator means another address: nobody can pre-empt the bot's with their own operator.
        assertTrue(f.predictDistributor(alice, address(token), address(treasury), bob, none, bytes32("x")) != predicted);
    }
}

