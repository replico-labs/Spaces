// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GovernanceToken} from "../src/token/GovernanceToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract GovernanceTokenTest is Test {
    GovernanceToken internal token;

    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
    uint256 internal constant MAX_SUPPLY = 10_000 ether;

    function setUp() public {
        token = GovernanceToken(Clones.clone(address(new GovernanceToken())));
        token.initialize(
            "Test Token",
            "TT",
            INITIAL_SUPPLY,
            MAX_SUPPLY,
            recipient,
            owner
        );
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_MintsInitialSupplyToRecipient() public view {
        assertEq(token.balanceOf(recipient), INITIAL_SUPPLY);
        assertEq(token.balanceOf(owner), 0);
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(token.owner(), owner);
    }

    function test_Constructor_SetsMaxSupply() public view {
        assertEq(token.maxSupply(), MAX_SUPPLY);
    }

    function test_Constructor_RevertsOnZeroRecipient() public {
        GovernanceToken freshToken = GovernanceToken(Clones.clone(address(new GovernanceToken())));
        vm.expectRevert(bytes("Zero recipient"));
        freshToken.initialize("Test Token", "TT", INITIAL_SUPPLY, MAX_SUPPLY, address(0), owner);
    }

    function test_Constructor_RevertsOnZeroOwner() public {
        // Ownable(initialOwner_) is a base initializer and runs before our
        // own require() in initialize()'s body, so it's Ownable's own
        // error that actually surfaces here.
        GovernanceToken freshToken = GovernanceToken(Clones.clone(address(new GovernanceToken())));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0))
        );
        freshToken.initialize("Test Token", "TT", INITIAL_SUPPLY, MAX_SUPPLY, recipient, address(0));
    }

    function test_Constructor_RevertsWhenInitialSupplyExceedsMax() public {
        GovernanceToken freshToken = GovernanceToken(Clones.clone(address(new GovernanceToken())));
        vm.expectRevert(bytes("Invalid supply"));
        freshToken.initialize("Test Token", "TT", MAX_SUPPLY + 1, MAX_SUPPLY, recipient, owner);
    }

    /*//////////////////////////////////////////////////////////////
                                MINTING
    //////////////////////////////////////////////////////////////*/

    function test_Mint_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(GovernanceToken.NotAllowed.selector);
        token.mint(alice, 100 ether);
    }

    function test_Mint_IncreasesBalanceAndSupply() public {
        vm.prank(owner);
        token.mint(alice, 500 ether);

        assertEq(token.balanceOf(alice), 500 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + 500 ether);
    }

    function test_Mint_RevertsWhenExceedingMaxSupply() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Max supply exceeded"));
        token.mint(alice, MAX_SUPPLY - INITIAL_SUPPLY + 1);
    }

    function test_Mint_AllowsExactlyUpToMaxSupply() public {
        vm.prank(owner);
        token.mint(alice, MAX_SUPPLY - INITIAL_SUPPLY);

        assertEq(token.totalSupply(), MAX_SUPPLY);
    }

    /*//////////////////////////////////////////////////////////////
                                BURNING
    //////////////////////////////////////////////////////////////*/

    function test_Burn_ReducesCallerBalance() public {
        vm.prank(recipient);
        token.burn(200 ether);

        assertEq(token.balanceOf(recipient), INITIAL_SUPPLY - 200 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 200 ether);
    }

    function test_Burn_RevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.burn(1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP TRANSFER (GOVERNANCE HANDOFF)
    //////////////////////////////////////////////////////////////*/

    function test_TransferOwnership_MovesMintRights() public {
        vm.prank(owner);
        token.transferOwnership(alice);

        assertEq(token.owner(), alice);

        vm.prank(alice);
        token.mint(bob, 10 ether);
        assertEq(token.balanceOf(bob), 10 ether);

        vm.prank(owner);
        vm.expectRevert(GovernanceToken.NotAllowed.selector);
        token.mint(bob, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        VOTING POWER / DELEGATION
    //////////////////////////////////////////////////////////////*/

    function test_GetVotes_ZeroBeforeDelegation() public view {
        assertEq(token.getVotes(recipient), 0);
    }

    function test_Delegate_ActivatesOwnVotingPower() public {
        vm.prank(recipient);
        token.delegate(recipient);

        assertEq(token.getVotes(recipient), INITIAL_SUPPLY);
        assertEq(token.delegates(recipient), recipient);
    }

    function test_Transfer_MovesVotingPowerOnlyIfDelegated() public {
        vm.prank(recipient);
        token.delegate(recipient);

        vm.prank(recipient);
        bool ok = token.transfer(alice, 300 ether);
        assertTrue(ok);

        // Alice hasn't delegated yet - balance moved but voting power did not.
        assertEq(token.balanceOf(alice), 300 ether);
        assertEq(token.getVotes(alice), 0);
        assertEq(token.getVotes(recipient), INITIAL_SUPPLY - 300 ether);

        vm.prank(alice);
        token.delegate(alice);
        assertEq(token.getVotes(alice), 300 ether);
    }

    function test_GetPastVotes_ReflectsHistoricalCheckpoint() public {
        vm.prank(recipient);
        token.delegate(recipient);

        uint256 blockAtDelegation = vm.getBlockNumber();
        vm.roll(vm.getBlockNumber() + 1);

        vm.prank(recipient);
        bool ok = token.transfer(alice, 500 ether);
        assertTrue(ok);

        vm.roll(vm.getBlockNumber() + 1);

        // Past checkpoint still reflects the pre-transfer balance.
        assertEq(token.getPastVotes(recipient, blockAtDelegation), INITIAL_SUPPLY);
    }

    function test_GetPastTotalSupply_ReflectsMintHistory() public {
        uint256 blockBeforeMint = vm.getBlockNumber();
        vm.roll(vm.getBlockNumber() + 1);

        vm.prank(owner);
        token.mint(alice, 100 ether);

        vm.roll(vm.getBlockNumber() + 1);

        assertEq(token.getPastTotalSupply(blockBeforeMint), INITIAL_SUPPLY);
        assertEq(token.getPastTotalSupply(vm.getBlockNumber() - 1), INITIAL_SUPPLY + 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         MINTER (PROP-FIRM VAULT)
    //////////////////////////////////////////////////////////////*/

    function test_Minter_SetByOwnerMintsWithinMaxSupply() public {
        address vault = makeAddr("vault");
        vm.prank(alice);
        vm.expectRevert(GovernanceToken.NotAllowed.selector);
        token.setMinter(vault);
        vm.prank(owner);
        token.setMinter(vault);
        vm.prank(vault);
        token.mint(bob, 5 ether);
        assertEq(token.balanceOf(bob), 5 ether);
        uint256 max = token.maxSupply();
        vm.prank(vault);
        vm.expectRevert("Max supply exceeded");
        token.mint(bob, max);
    }

    function test_Minter_SetupWindowOnlyForContractsAndOnlyThisBlock() public {
        vm.prank(owner);
        token.setSetupAuthority(alice); // a wallet: ignored
        assertEq(token.setupAuthority(), address(0));

        address launcher = address(new GovernanceToken()); // any contract
        vm.prank(owner);
        token.setSetupAuthority(launcher);
        vm.prank(launcher);
        token.setMinter(makeAddr("vault"));
        vm.roll(block.number + 1);
        vm.prank(launcher);
        vm.expectRevert(GovernanceToken.NotAllowed.selector);
        token.setMinter(launcher);
    }
}

