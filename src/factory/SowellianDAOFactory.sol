// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/sowellian/SowellianGovernance.sol";
import "../treasury/Treasury.sol";
import "../token/GovernanceToken.sol";
import "../token/StakedGovernanceToken.sol";
import "../governance/Types.sol";
import "./DAOFactoryLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title SowellianDAOFactory
/// @notice Deploys and wires together a governance token, staking
///         wrapper, treasury, and SowellianGovernance contract for a new
///         DAO - the same deployment shape as the original DAOFactory.
///         Which oracle a proposal resolves against is chosen per-
///         proposal (SowellianGovernance's own propose() call), not at
///         factory time, so nothing oracle-specific is wired here.
/// @dev Clone-based - see QuadraticDAOFactory's own notes for why.
contract SowellianDAOFactory {
    using Clones for address;

    address public immutable governanceTokenImplementation;
    address public immutable stakedGovernanceTokenImplementation;
    address public immutable treasuryImplementation;
    address public immutable sowellianGovernanceImplementation;

    uint256 public daoCount;
    mapping(uint256 => DAOInfo) public daos;
    mapping(address => address[]) public creatorDAOs;

    /// @notice For a governance deployed by a model switch, the governance
    ///         it replaced. Zero for DAOs created fresh.
    mapping(address => address) public predecessorOf;

    /// @notice Switches away from each governance so far, used to derive
    ///         the next switch's deterministic address.
    mapping(address => uint256) public switchNonce;

    event DAOSwitched(uint256 indexed daoId, address indexed previousGovernance, address governance, address treasury);

    event DAOCreated(uint256 indexed daoId, address indexed creator, address governance, address treasury, address token);

    constructor(
        address governanceTokenImplementation_,
        address stakedGovernanceTokenImplementation_,
        address treasuryImplementation_,
        address sowellianGovernanceImplementation_
    ) {
        require(governanceTokenImplementation_ != address(0), "Zero implementation");
        require(stakedGovernanceTokenImplementation_ != address(0), "Zero implementation");
        require(treasuryImplementation_ != address(0), "Zero implementation");
        require(sowellianGovernanceImplementation_ != address(0), "Zero implementation");

        governanceTokenImplementation = governanceTokenImplementation_;
        stakedGovernanceTokenImplementation = stakedGovernanceTokenImplementation_;
        treasuryImplementation = treasuryImplementation_;
        sowellianGovernanceImplementation = sowellianGovernanceImplementation_;
    }

    function createDAO(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        uint256 maxSupply,
        SowellianGovernance.SowellianConfig calldata config
    ) external returns (address governance) {
        (GovernanceToken token, StakedGovernanceToken stakedToken, Treasury treasury) = DAOFactoryLib.deployCore(
            name,
            symbol,
            initialSupply,
            maxSupply,
            msg.sender,
            governanceTokenImplementation,
            stakedGovernanceTokenImplementation,
            treasuryImplementation
        );

        SowellianGovernance gov = SowellianGovernance(sowellianGovernanceImplementation.clone());
        gov.initialize(name, msg.sender, address(stakedToken), address(treasury), config);
        governance = address(gov);

        treasury.transferGovernance(governance);
        token.transferOwnership(governance);
        stakedToken.transferOwnership(governance);

        _recordDAO(name, address(stakedToken), address(token), governance, address(treasury));
    }

    /// @notice Switches an existing DAO to this model. Deploys only the
    ///         governance contract, pointed at the DAO's own Treasury and
    ///         staking contract, at the address predictSwitchGovernance()
    ///         returned. Must be called by the DAO's current governance as
    ///         the first action of a switch proposal; the actions after it
    ///         hand the Treasury, token and staking contract to the new
    ///         governance, all in the same execution.
    function createForSwitch(
        string calldata name,
        address treasury,
        address token,
        address stakedToken,
        SowellianGovernance.SowellianConfig calldata config,
        address expectedGovernance
    ) external returns (address governance) {
        DAOFactoryLib.checkSwitch(treasury, token, stakedToken);
        governance = DAOFactoryLib.cloneForSwitch(sowellianGovernanceImplementation, switchNonce[msg.sender]++, expectedGovernance);
        SowellianGovernance(governance).initialize(name, msg.sender, stakedToken, treasury, config);

        _recordDAO(name, stakedToken, token, governance, treasury);
        predecessorOf[governance] = msg.sender;
        emit DAOSwitched(daoCount, msg.sender, governance, treasury);
    }

    /// @notice The address the next switch of `previousGovernance` to this
    ///         model will deploy to.
    function predictSwitchGovernance(address previousGovernance) external view returns (address) {
        return DAOFactoryLib.predictSwitch(sowellianGovernanceImplementation, previousGovernance, switchNonce[previousGovernance]);
    }

    function _recordDAO(
        string calldata name,
        address stakedToken,
        address token,
        address governance,
        address treasury
    ) private {
        daoCount++;
        daos[daoCount] = DAOInfo(name, msg.sender, stakedToken, token, governance, treasury, block.timestamp);
        creatorDAOs[msg.sender].push(governance);
        emit DAOCreated(daoCount, msg.sender, governance, treasury, stakedToken);
    }

    function getCreatorDAOs(address creator) external view returns (address[] memory) {
        return creatorDAOs[creator];
    }
}
