// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import "./Distributor.sol";
import "./Raise.sol";

/// @title DistributionFactory
/// @notice One per network. Makes Distributors (and raises, below) as
///         EIP-1167 clones, at addresses fixed by the caller and a salt so
///         one proposal can create one and fund it in its next action.
/// @dev Anyone may create a Distributor for any Treasury: it's inert until
///      the DAO funds it, and its admin is always whoever the Treasury
///      answers to. The operator and allocators are part of the salt,
///      so a Distributor the bot uses is always one made with its own
///      operator.
contract DistributionFactory {
    using Clones for address;

    address public immutable distributorImplementation;
    address public immutable raiseImplementation;

    mapping(address => bool) public isFromFactory;

    event DistributorCreated(address indexed deployer, address indexed treasury, address indexed token, address distributor);
    event RaiseCreated(address indexed deployer, address indexed decider, address raise);

    error ZeroImplementation();

    constructor(address distributorImplementation_, address raiseImplementation_) {
        if (distributorImplementation_ == address(0) || raiseImplementation_ == address(0)) revert ZeroImplementation();
        distributorImplementation = distributorImplementation_;
        raiseImplementation = raiseImplementation_;
    }

    /// @notice A raise on `terms`, decided by the caller (the DAO's
    ///         governance or council wrapper inside a proposal, or a
    ///         Launcher), at predictRaise(msg.sender, salt).
    function createRaise(Raise.Terms calldata terms, bytes32 salt) external returns (address raise) {
        raise = raiseImplementation.cloneDeterministic(keccak256(abi.encode(bytes32("raise"), msg.sender, salt)));
        Raise(raise).initialize(terms, msg.sender);
        isFromFactory[raise] = true;
        emit RaiseCreated(msg.sender, msg.sender, raise);
    }

    function predictRaise(address deployer, bytes32 salt) external view returns (address) {
        return raiseImplementation.predictDeterministicAddress(keccak256(abi.encode(bytes32("raise"), deployer, salt)), address(this));
    }

    /// @notice A Distributor of `token` for `treasury`'s DAO, at
    ///         predictDistributor(msg.sender, token, treasury, operator, allocators, salt).
    function createDistributor(
        address token,
        address treasury,
        address operator,
        address[] calldata allocators,
        uint64 claimDeadline,
        bytes32 salt
    ) external returns (address distributor) {
        distributor = distributorImplementation.cloneDeterministic(_distributorSalt(msg.sender, token, treasury, operator, allocators, salt));
        Distributor(distributor).initialize(token, treasury, operator, allocators, claimDeadline);
        isFromFactory[distributor] = true;
        emit DistributorCreated(msg.sender, treasury, token, distributor);
    }

    function predictDistributor(
        address deployer,
        address token,
        address treasury,
        address operator,
        address[] calldata allocators,
        bytes32 salt
    ) external view returns (address) {
        return distributorImplementation.predictDeterministicAddress(_distributorSalt(deployer, token, treasury, operator, allocators, salt), address(this));
    }

    function _distributorSalt(
        address deployer,
        address token,
        address treasury,
        address operator,
        address[] calldata allocators,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(bytes32("distributor"), deployer, token, treasury, operator, allocators, salt));
    }
}
