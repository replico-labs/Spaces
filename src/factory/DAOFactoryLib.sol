// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../token/GovernanceToken.sol";
import "../token/StakedGovernanceToken.sol";
import "../treasury/Treasury.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title DAOFactoryLib
/// @notice Shared deployment helper used by every per-model DAO factory in
///         this system - deploys and wires the three pieces every
///         token-based governance model needs (GovernanceToken,
///         StakedGovernanceToken, Treasury), exactly matching the
///         original DAOFactory's own deployment order and temporary-
///         controller handoff pattern. Every factory in this codebase
///         behaves identically for this shared part, regardless of which
///         governance model it ultimately wires up - only what happens
///         after this point (deploying the specific governance contract
///         and handing off control) differs per model.
/// @dev Library functions here are internal, so they compile inline into
///      each calling factory's own bytecode rather than requiring a
///      separate deployed library contract - `address(this)` inside
///      deployCore correctly resolves to whichever factory called it,
///      not to the library itself, since there is no DELEGATECALL
///      boundary for internal library calls.
///
///      Clone-based deployment: this used to `new` all three contracts
///      directly, which - because these functions are inlined into every
///      calling factory - meant every factory using this library embedded
///      all three contracts' full creation bytecode in its own bytecode.
///      Deploying from inside deployCore itself doesn't help either way
///      (inlined or not, the child's creation bytecode still has to be
///      present somewhere in the caller's bytecode) - the three
///      implementations must be deployed once, separately, outside any
///      factory, and their addresses passed in here to be cloned instead.
library DAOFactoryLib {
    using Clones for address;

    function deployCore(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 maxSupply,
        address creator,
        address governanceTokenImplementation,
        address stakedGovernanceTokenImplementation,
        address treasuryImplementation
    ) internal returns (GovernanceToken token, StakedGovernanceToken stakedToken, Treasury treasury) {
        // Initial supply goes to the DAO creator; the factory is only the
        // temporary Ownable owner so it can hand off minting rights to
        // governance once governance exists.
        token = GovernanceToken(governanceTokenImplementation.clone());
        token.initialize(name, symbol, initialSupply, maxSupply, creator, address(this));

        stakedToken = StakedGovernanceToken(stakedGovernanceTokenImplementation.clone());
        stakedToken.initialize(
            address(token),
            string.concat("Staked ", name),
            string.concat("s", symbol),
            address(this)
        );

        treasury = Treasury(payable(treasuryImplementation.clone()));
        treasury.initialize(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            MODEL SWITCHING
    //////////////////////////////////////////////////////////////*/

    error NotTreasuryGovernance();
    error StakingTokenMismatch();
    error StakingNotOwned();
    error UnexpectedGovernanceAddress();

    /// @dev A switch is called from inside an executed proposal of the
    ///      DAO's current governance, which must still control the
    ///      Treasury. Staking, when given, must wrap the given token.
    function checkSwitch(address treasury, address token, address stakedToken) internal view {
        if (Treasury(payable(treasury)).governance() != msg.sender) revert NotTreasuryGovernance();
        if (stakedToken != address(0) && address(StakedGovernanceToken(stakedToken).underlying()) != token) {
            revert StakingTokenMismatch();
        }
    }

    /// @dev Locking models need the old governance to own the staking
    ///      contract, so the same proposal can make the new one its locker.
    function checkStakingOwned(address stakedToken) internal view {
        if (StakedGovernanceToken(stakedToken).owner() != msg.sender) revert StakingNotOwned();
    }

    function switchSalt(address previousGovernance, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(previousGovernance, nonce));
    }

    /// @dev The address the next switch away from `previousGovernance`
    ///      deploys to, so the switch proposal can name it in the
    ///      handover actions that follow the deploy.
    function predictSwitch(address implementation, address previousGovernance, uint256 nonce)
        internal
        view
        returns (address)
    {
        return implementation.predictDeterministicAddress(switchSalt(previousGovernance, nonce), address(this));
    }

    /// @dev Reverts unless the clone lands where the proposal expects, so
    ///      the handover actions after it can never point at an empty
    ///      address.
    function cloneForSwitch(address implementation, uint256 nonce, address expectedGovernance)
        internal
        returns (address governance)
    {
        governance = implementation.cloneDeterministic(switchSalt(msg.sender, nonce));
        if (governance != expectedGovernance) revert UnexpectedGovernanceAddress();
    }
}
