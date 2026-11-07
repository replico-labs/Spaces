// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @dev Minimal ERC20 mock used only to test Treasury's ERC20 handling
///      without pulling in the full GovernanceToken/ERC20Votes stack.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A target contract used to test Treasury.execute() against an
///      arbitrary call.
contract CallTarget {
    uint256 public lastValue;
    bytes public lastData;

    function ping(uint256 value) external payable returns (uint256) {
        lastValue = value;
        return value * 2;
    }

    receive() external payable {}
}

contract TreasuryTest is Test {
    Treasury internal treasury;
    MockERC20 internal mockToken;
    CallTarget internal callTarget;

    address internal governance = makeAddr("governance");
    address internal outsider = makeAddr("outsider");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        treasury = Treasury(payable(Clones.clone(address(new Treasury()))));
        treasury.initialize(governance);
        mockToken = new MockERC20();
        callTarget = new CallTarget();

        vm.deal(address(treasury), 10 ether);
        mockToken.mint(address(treasury), 1_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_RevertsOnZeroGovernance() public {
        Treasury freshTreasury = Treasury(payable(Clones.clone(address(new Treasury()))));
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        freshTreasury.initialize(address(0));
    }

    function test_Constructor_SetsGovernance() public view {
        assertEq(treasury.governance(), governance);
    }

    /*//////////////////////////////////////////////////////////////
                            ETH HANDLING
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveETH_EmitsEvent() public {
        vm.deal(outsider, 1 ether);

        vm.expectEmit(true, false, false, true);
        emit ITreasury.ETHReceived(outsider, 1 ether);

        vm.prank(outsider);
        (bool ok, ) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_EthBalance_ReflectsDeposits() public view {
        assertEq(treasury.ethBalance(), 10 ether);
    }

    function test_TransferETH_OnlyGovernance() public {
        vm.prank(outsider);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.transferETH(payable(recipient), 1 ether);
    }

    function test_TransferETH_RevertsOnZeroRecipient() public {
        vm.prank(governance);
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        treasury.transferETH(payable(address(0)), 1 ether);
    }

    function test_TransferETH_RevertsOnInsufficientBalance() public {
        vm.prank(governance);
        vm.expectRevert(ITreasury.InsufficientBalance.selector);
        treasury.transferETH(payable(recipient), 100 ether);
    }

    function test_TransferETH_Succeeds() public {
        vm.prank(governance);
        treasury.transferETH(payable(recipient), 1 ether);

        assertEq(recipient.balance, 1 ether);
        assertEq(treasury.ethBalance(), 9 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 HANDLING
    //////////////////////////////////////////////////////////////*/

    function test_TransferERC20_OnlyGovernance() public {
        vm.prank(outsider);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.transferERC20(address(mockToken), recipient, 100 ether);
    }

    function test_TransferERC20_RevertsOnZeroToken() public {
        vm.prank(governance);
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        treasury.transferERC20(address(0), recipient, 100 ether);
    }

    function test_TransferERC20_RevertsOnZeroRecipient() public {
        vm.prank(governance);
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        treasury.transferERC20(address(mockToken), address(0), 100 ether);
    }

    function test_TransferERC20_Succeeds() public {
        vm.prank(governance);
        treasury.transferERC20(address(mockToken), recipient, 100 ether);

        assertEq(mockToken.balanceOf(recipient), 100 ether);
        assertEq(treasury.tokenBalance(address(mockToken)), 900 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        ARBITRARY EXECUTION
    //////////////////////////////////////////////////////////////*/

    function test_Execute_OnlyGovernance() public {
        vm.prank(outsider);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.execute(address(callTarget), 0, abi.encodeWithSelector(CallTarget.ping.selector, 5));
    }

    function test_Execute_RevertsOnZeroTarget() public {
        vm.prank(governance);
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        treasury.execute(address(0), 0, "");
    }

    function test_Execute_ForwardsCallAndValue() public {
        vm.prank(governance);
        bytes memory result = treasury.execute(
            address(callTarget),
            1 ether,
            abi.encodeWithSelector(CallTarget.ping.selector, 5)
        );

        assertEq(abi.decode(result, (uint256)), 10);
        assertEq(callTarget.lastValue(), 5);
        assertEq(address(callTarget).balance, 1 ether);
        assertEq(treasury.ethBalance(), 9 ether);
    }

    function test_Execute_RevertsOnTargetFailure() public {
        vm.prank(governance);
        vm.expectRevert(ITreasury.TransferFailed.selector);
        // No such selector on callTarget -> underlying call reverts.
        treasury.execute(address(callTarget), 0, abi.encodeWithSignature("doesNotExist()"));
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE HANDOFF
    //////////////////////////////////////////////////////////////*/

    function test_TransferGovernance_OnlyCurrentGovernance() public {
        vm.prank(outsider);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.transferGovernance(outsider);
    }

    function test_TransferGovernance_RevertsOnZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        treasury.transferGovernance(address(0));
    }

    function test_TransferGovernance_UpdatesGovernanceAndEmits() public {
        address newGovernance = makeAddr("newGovernance");

        vm.expectEmit(true, true, false, true);
        emit ITreasury.OwnershipTransferred(governance, newGovernance);

        vm.prank(governance);
        treasury.transferGovernance(newGovernance);

        assertEq(treasury.governance(), newGovernance);
    }

    function test_TransferGovernance_OldGovernanceLosesAccess() public {
        address newGovernance = makeAddr("newGovernance");

        vm.prank(governance);
        treasury.transferGovernance(newGovernance);

        vm.prank(governance);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.transferETH(payable(recipient), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            ALLOWANCES
    //////////////////////////////////////////////////////////////*/

    function _allow(address token, uint256 amount, uint256 months) internal returns (uint256 id) {
        vm.prank(governance);
        id = treasury.createAllowance(recipient, token, amount, uint64(block.timestamp + months * 30 days));
    }

    function test_Allowance_PaysOncePerPeriodInTokens() public {
        uint256 id = _allow(address(mockToken), 100 ether, 3);
        assertEq(id, 1);
        assertEq(treasury.allowanceCount(), 1);

        vm.prank(recipient);
        assertEq(treasury.claimAllowance(id), 100 ether);
        assertEq(mockToken.balanceOf(recipient), 100 ether);

        // Same period again: refused, naming when the next one opens.
        uint256 start = block.timestamp;
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(ITreasury.AllowanceAlreadyClaimed.selector, start + 30 days));
        treasury.claimAllowance(id);

        vm.warp(start + 30 days);
        vm.prank(recipient);
        treasury.claimAllowance(id);
        assertEq(mockToken.balanceOf(recipient), 200 ether);
    }

    function test_Allowance_MissedPeriodsLapse() public {
        uint256 id = _allow(address(mockToken), 100 ether, 6);
        vm.warp(block.timestamp + 95 days); // periods 1-3 never claimed; now in period 4
        (uint256 due,) = treasury.claimableAllowance(id);
        assertEq(due, 100 ether, "only the current period");
        vm.prank(recipient);
        treasury.claimAllowance(id);
        assertEq(mockToken.balanceOf(recipient), 100 ether);
        (due,) = treasury.claimableAllowance(id);
        assertEq(due, 0);
    }

    function test_Allowance_NativeCoin() public {
        uint256 id = _allow(address(0), 1 ether, 1);
        uint256 before = recipient.balance;
        vm.prank(recipient);
        treasury.claimAllowance(id);
        assertEq(recipient.balance - before, 1 ether);
    }

    function test_Allowance_OnlyRecipientClaims() public {
        uint256 id = _allow(address(mockToken), 1 ether, 1);
        vm.prank(outsider);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.claimAllowance(id);
    }

    function test_Allowance_OnlyGovernanceGrantsChangesAndRevokes() public {
        vm.prank(outsider);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.createAllowance(recipient, address(mockToken), 1 ether, uint64(block.timestamp + 30 days));

        uint256 id = _allow(address(mockToken), 1 ether, 2);
        vm.startPrank(outsider);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.updateAllowance(id, 2 ether, uint64(block.timestamp + 30 days));
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.revokeAllowance(id);
        vm.stopPrank();
    }

    function test_Allowance_EndsAndRevokes() public {
        uint256 id = _allow(address(mockToken), 1 ether, 1);
        vm.warp(block.timestamp + 30 days);
        vm.prank(recipient);
        vm.expectRevert(ITreasury.AllowanceEnded.selector);
        treasury.claimAllowance(id);

        uint256 id2 = _allow(address(mockToken), 1 ether, 2);
        vm.prank(governance);
        treasury.revokeAllowance(id2);
        vm.prank(recipient);
        vm.expectRevert(ITreasury.AllowanceEnded.selector);
        treasury.claimAllowance(id2);
    }

    function test_Allowance_UpdateKeepsPaidPeriods() public {
        uint256 id = _allow(address(mockToken), 1 ether, 3);
        vm.prank(recipient);
        treasury.claimAllowance(id);
        vm.prank(governance);
        treasury.updateAllowance(id, 5 ether, uint64(block.timestamp + 60 days));
        vm.prank(recipient);
        vm.expectRevert(); // period 1 already paid
        treasury.claimAllowance(id);
        vm.warp(block.timestamp + 30 days);
        vm.prank(recipient);
        assertEq(treasury.claimAllowance(id), 5 ether);
    }

    function test_Allowance_TermsChecked() public {
        vm.startPrank(governance);
        vm.expectRevert(ITreasury.InvalidAllowance.selector);
        treasury.createAllowance(recipient, address(mockToken), 0, uint64(block.timestamp + 30 days));
        vm.expectRevert(ITreasury.InvalidAllowance.selector);
        treasury.createAllowance(recipient, address(mockToken), 1, uint64(block.timestamp + 366 days));
        vm.expectRevert(ITreasury.InvalidAllowance.selector);
        treasury.createAllowance(recipient, address(mockToken), 1, uint64(block.timestamp));
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        treasury.createAllowance(address(0), address(mockToken), 1, uint64(block.timestamp + 30 days));
        vm.stopPrank();
        vm.prank(recipient);
        vm.expectRevert(ITreasury.AllowanceNotFound.selector);
        treasury.claimAllowance(7);
    }

    function test_Allowance_ManyRecipientsAtOnce() public {
        address other = makeAddr("contractor2");
        vm.startPrank(governance);
        uint256 a = treasury.createAllowance(recipient, address(mockToken), 1 ether, uint64(block.timestamp + 30 days));
        uint256 b = treasury.createAllowance(other, address(mockToken), 2 ether, uint64(block.timestamp + 30 days));
        uint256 c = treasury.createAllowance(recipient, address(0), 0.1 ether, uint64(block.timestamp + 30 days));
        vm.stopPrank();
        vm.prank(recipient);
        treasury.claimAllowance(a);
        vm.prank(other);
        treasury.claimAllowance(b);
        vm.prank(recipient);
        treasury.claimAllowance(c);
        assertEq(mockToken.balanceOf(recipient), 1 ether);
        assertEq(mockToken.balanceOf(other), 2 ether);
    }
}

