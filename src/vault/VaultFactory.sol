// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import "./PropFirmVault.sol";
import "./HyperCoreValuer.sol";
import "./PerplValuer.sol";

/// @title VaultFactory
/// @notice One per network. Makes prop-firm vaults (EIP-1167 clones) and
///         the valuers that read each venue for them.
contract VaultFactory {
    using Clones for address;

    address public immutable vaultImplementation;
    mapping(address => bool) public isFromFactory;

    event VaultCreated(address indexed deployer, address indexed treasury, address vault);
    event ValuerCreated(address indexed deployer, address indexed account, address valuer, string venue);

    error ZeroImplementation();

    constructor(address vaultImplementation_) {
        if (vaultImplementation_ == address(0)) revert ZeroImplementation();
        vaultImplementation = vaultImplementation_;
    }

    /// @notice A vault over `asset` whose shares are `shares` (the DAO's
    ///         token, which must then make the vault its minter), at
    ///         predictVault(msg.sender, salt).
    function createVault(
        address asset,
        address shares,
        address treasury,
        address seeder,
        PropFirmVault.Config calldata config,
        PropFirmVault.FeeSplit[] calldata feeSplits,
        bytes32 salt
    ) external returns (address vault) {
        vault = vaultImplementation.cloneDeterministic(keccak256(abi.encode(bytes32("vault"), msg.sender, salt)));
        PropFirmVault(payable(vault)).initialize(asset, shares, treasury, seeder, config, feeSplits);
        isFromFactory[vault] = true;
        emit VaultCreated(msg.sender, treasury, vault);
    }

    function predictVault(address deployer, bytes32 salt) external view returns (address) {
        return vaultImplementation.predictDeterministicAddress(keccak256(abi.encode(bytes32("vault"), deployer, salt)), address(this));
    }

    function createHyperCoreValuer(address account, uint32 perpDex, uint64 usdcToken, uint8 perpUsdDecimals, uint8 assetDecimals)
        external
        returns (address valuer)
    {
        valuer = address(new HyperCoreValuer(account, perpDex, usdcToken, perpUsdDecimals, assetDecimals));
        isFromFactory[valuer] = true;
        emit ValuerCreated(msg.sender, account, valuer, "hypercore");
    }

    function createPerplValuer(IPerplExchange exchange, address account, uint256[] calldata markets, uint8 assetDecimals)
        external
        returns (address valuer)
    {
        valuer = address(new PerplValuer(exchange, account, markets, assetDecimals));
        isFromFactory[valuer] = true;
        emit ValuerCreated(msg.sender, account, valuer, "perpl");
    }
}
