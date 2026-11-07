// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import "./GuardWrapper.sol";
import "../marketplace/NFTMarketplaceWrapper.sol";
import "../converter/StakeConverter.sol";

/// @title WrapperFactory
/// @notice One per network. Makes the per-DAO helpers that hold or guard
///         DAO assets as cheap EIP-1167 clones of one implementation
///         each: GuardWrapper (a security council), NFTMarketplaceWrapper
///         and StakeConverter.
/// @dev Every clone lands at an address fixed by the caller and a salt
///      (predict* below), so one proposal can create a helper and use it
///      in the actions after - e.g. create a GuardWrapper and hand it the
///      Treasury, token and staking contract in the same execution.
///      These aren't shared contracts like the price adapters: each DAO
///      keeps its own clone and storage, so a problem stays in one DAO.
contract WrapperFactory {
    using Clones for address;

    address public immutable guardWrapperImplementation;
    address public immutable nftWrapperImplementation;
    address public immutable converterImplementation;

    /// @notice Every helper this factory made.
    mapping(address => bool) public isFromFactory;

    event GuardWrapperCreated(address indexed deployer, address indexed governance, address wrapper);
    event NFTWrapperCreated(address indexed deployer, address indexed governance, address wrapper);
    event ConverterCreated(address indexed deployer, address indexed treasury, address converter);

    error ZeroImplementation();

    constructor(address guardWrapperImplementation_, address nftWrapperImplementation_, address converterImplementation_) {
        if (guardWrapperImplementation_ == address(0) || nftWrapperImplementation_ == address(0) || converterImplementation_ == address(0)) {
            revert ZeroImplementation();
        }
        guardWrapperImplementation = guardWrapperImplementation_;
        nftWrapperImplementation = nftWrapperImplementation_;
        converterImplementation = converterImplementation_;
    }

    /// @notice A GuardWrapper answering to `governance`, at
    ///         predictGuardWrapper(msg.sender, salt).
    function createGuardWrapper(
        address governance,
        address[] calldata signers,
        uint256 requiredApprovals,
        uint256 tenureLength,
        bytes32 salt
    ) external returns (address wrapper) {
        wrapper = guardWrapperImplementation.cloneDeterministic(_salt("guard", msg.sender, salt));
        GuardWrapper(payable(wrapper)).initialize(governance, signers, requiredApprovals, tenureLength);
        isFromFactory[wrapper] = true;
        emit GuardWrapperCreated(msg.sender, governance, wrapper);
    }

    function predictGuardWrapper(address deployer, bytes32 salt) external view returns (address) {
        return guardWrapperImplementation.predictDeterministicAddress(_salt("guard", deployer, salt), address(this));
    }

    /// @notice An NFTMarketplaceWrapper for `governance` and `treasury`,
    ///         at predictNFTWrapper(msg.sender, salt).
    function createNFTWrapper(address governance, address treasury, bytes32 salt) external returns (address wrapper) {
        wrapper = nftWrapperImplementation.cloneDeterministic(_salt("nft", msg.sender, salt));
        NFTMarketplaceWrapper(payable(wrapper)).initialize(governance, treasury);
        isFromFactory[wrapper] = true;
        emit NFTWrapperCreated(msg.sender, governance, wrapper);
    }

    function predictNFTWrapper(address deployer, bytes32 salt) external view returns (address) {
        return nftWrapperImplementation.predictDeterministicAddress(_salt("nft", deployer, salt), address(this));
    }

    /// @notice A StakeConverter from staking contract `from` to `to` at
    ///         `rateNum` new per `rateDen` old, paying old tokens to
    ///         `treasury`, at predictConverter(msg.sender, salt). The DAO
    ///         funds it with the new token afterwards.
    function createConverter(address from, address to, uint256 rateNum, uint256 rateDen, address treasury, bytes32 salt)
        external
        returns (address converter)
    {
        converter = converterImplementation.cloneDeterministic(_salt("converter", msg.sender, salt));
        StakeConverter(converter).initialize(from, to, rateNum, rateDen, treasury);
        isFromFactory[converter] = true;
        emit ConverterCreated(msg.sender, treasury, converter);
    }

    function predictConverter(address deployer, bytes32 salt) external view returns (address) {
        return converterImplementation.predictDeterministicAddress(_salt("converter", deployer, salt), address(this));
    }

    function _salt(bytes32 kind, address deployer, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(kind, deployer, salt));
    }
}
