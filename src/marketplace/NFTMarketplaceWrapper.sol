// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @title NFTMarketplaceWrapper
/// @author Marvin Sunday
/// @notice A governance-controlled EIP-1271 signer, letting a DAO's
///         Treasury participate in marketplaces (OpenSea/Seaport) that
///         require the offerer to be able to validate signatures -
///         something Treasury deliberately does NOT implement itself,
///         to keep Treasury's own trust model minimal and marketplace-
///         agnostic. One deployed per DAO, same pattern as
///         ChainlinkPriceFeedAdapter - not shared across DAOs, since
///         (unlike a price adapter) this one temporarily holds real
///         assets.
/// @dev SCOPE NOTE: `isValidSignature` implements the standard
///      "approved-hash" EIP-1271 pattern used by Gnosis Safe and other
///      smart-contract wallets - it does not verify a cryptographic
///      signature at all, since this contract has no private key.
///      Governance pre-approves a specific order hash via
///      `approveOrderHash`, and `isValidSignature` simply checks
///      whether the hash being asked about was pre-approved. The
///      actual Seaport order-hash computation (turning "list this NFT
///      for this price" into the specific bytes32 Seaport expects) is
///      NOT done on-chain here - it happens off-chain, using Seaport's
///      own real order-hashing logic, and the resulting hash is what
///      gets passed to `approveOrderHash`. This keeps this contract
///      simple and marketplace-agnostic: it never needs to know any
///      specific marketplace's order struct layout.
contract NFTMarketplaceWrapper {
    address public governance;
    address public treasury;

    /// @dev EIP-1271 magic value returned for a valid signature.
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    mapping(bytes32 => bool) public approvedOrderHashes;

    event OrderHashApproved(bytes32 indexed orderHash);
    event OrderHashRevoked(bytes32 indexed orderHash);
    event ERC721Swept(address indexed token, uint256 indexed tokenId, address indexed to);
    event ERC1155Swept(address indexed token, uint256 indexed tokenId, uint256 amount, address indexed to);
    event NativeSwept(uint256 amount, address indexed to);
    event ERC20Swept(address indexed token, uint256 amount, address indexed to);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    error ZeroAddress();
    error Unauthorized();
    error TransferFailed();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    constructor(address governance_, address treasury_) {
        if (governance_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        governance = governance_;
        treasury = treasury_;
    }

    receive() external payable {}

    /// @notice Approves a specific order hash - governance's way of
    ///         saying "yes, list under these exact terms." The hash
    ///         itself is computed off-chain from the actual listing
    ///         terms (NFT, price, expiration, etc.) - this contract
    ///         never needs to understand those terms directly, only
    ///         the resulting hash.
    function approveOrderHash(bytes32 orderHash) external onlyGovernance {
        approvedOrderHashes[orderHash] = true;
        emit OrderHashApproved(orderHash);
    }

    /// @notice Revokes a previously approved hash - e.g. to cancel a
    ///         listing before it's filled.
    function revokeOrderHash(bytes32 orderHash) external onlyGovernance {
        approvedOrderHashes[orderHash] = false;
        emit OrderHashRevoked(orderHash);
    }

    /// @notice EIP-1271 - lets external contracts (Seaport) verify that
    ///         a given order hash was genuinely authorized by this
    ///         contract. `signature` is intentionally unused - this
    ///         contract has no private key to check a real signature
    ///         against; approval is tracked by hash instead.
    function isValidSignature(bytes32 hash, bytes memory) external view returns (bytes4) {
        return approvedOrderHashes[hash] ? MAGICVALUE : bytes4(0);
    }

    /// @notice Generic escape hatch, mirroring Treasury's own execute()
    ///         - lets governance make this wrapper interact with
    ///         whatever a specific marketplace actually requires
    ///         (token approvals, fulfillment calls, etc.) without this
    ///         contract needing to know that marketplace's interface
    ///         ahead of time.
    function execute(address target, uint256 value, bytes calldata data) external onlyGovernance returns (bytes memory) {
        (bool ok, bytes memory result) = target.call{value: value}(data);
        if (!ok) revert TransferFailed();
        return result;
    }

    /// @notice Lets governance update which Treasury this wrapper sweeps
    ///         assets back to - mirrors Governance's own setTreasury(),
    ///         so this wrapper stays correct if the DAO's treasury ever
    ///         changes.
    function setTreasury(address newTreasury) external onlyGovernance {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Sweeps an ERC721 this wrapper is holding back to Treasury
    ///         - e.g. after a listing is cancelled unsold.
    function sweepERC721(address token, uint256 tokenId) external onlyGovernance {
        IERC721(token).safeTransferFrom(address(this), treasury, tokenId);
        emit ERC721Swept(token, tokenId, treasury);
    }

    /// @notice Sweeps an ERC1155 balance this wrapper is holding back to Treasury.
    function sweepERC1155(address token, uint256 tokenId, uint256 amount) external onlyGovernance {
        IERC1155(token).safeTransferFrom(address(this), treasury, tokenId, amount, "");
        emit ERC1155Swept(token, tokenId, amount, treasury);
    }

    /// @notice Sweeps native currency proceeds (e.g. from a filled sale) back to Treasury.
    function sweepNative(uint256 amount) external onlyGovernance {
        (bool ok, ) = payable(treasury).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit NativeSwept(amount, treasury);
    }

    /// @notice Sweeps ERC20 proceeds back to Treasury.
    function sweepERC20(address token, uint256 amount) external onlyGovernance {
        bool ok = IERC20(token).transfer(treasury, amount);
        if (!ok) revert TransferFailed();
        emit ERC20Swept(token, amount, treasury);
    }

    /// @dev Required so this contract can legally hold ERC721 tokens via safeTransferFrom.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @dev Required so this contract can legally hold ERC1155 tokens via safeTransferFrom.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
