// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/sortition/SortitionGovernance.sol";
import "../treasury/Treasury.sol";
import "../token/GovernanceToken.sol";
import "../token/StakedGovernanceToken.sol";
import "../governance/Types.sol";
import "./DAOFactoryLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title SortitionDAOFactory
/// @notice Deploys and wires together a governance token, staking
///         wrapper, treasury, and SortitionGovernance contract for a new
///         DAO. Unlike every other factory in this system, this one
///         cannot self-contain everything it needs: SortitionGovernance
///         requires a real, already-deployed randomness source (the
///         chain's PythEntropyRandomnessAdapter, or any other
///         IRandomnessSource implementation configured for this chain), which the caller must supply per-DAO, at
///         createDAO() time - not something this factory's own
///         constructor should default or guess at.
/// @dev Clone-based - see QuadraticDAOFactory's own notes for why.
///      SortitionGovernance itself needs --via-ir to deploy (too large as
///      a standalone implementation even after this conversion); this
///      factory's own bytecode is unaffected and stays small regardless.
contract SortitionDAOFactory {
    using Clones for address;

    address public immutable governanceTokenImplementation;
    address public immutable stakedGovernanceTokenImplementation;
    address public immutable treasuryImplementation;
    address public immutable sortitionGovernanceImplementation;

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
        address sortitionGovernanceImplementation_
    ) {
        require(governanceTokenImplementation_ != address(0), "Zero implementation");
        require(stakedGovernanceTokenImplementation_ != address(0), "Zero implementation");
        require(treasuryImplementation_ != address(0), "Zero implementation");
        require(sortitionGovernanceImplementation_ != address(0), "Zero implementation");

        governanceTokenImplementation = governanceTokenImplementation_;
        stakedGovernanceTokenImplementation = stakedGovernanceTokenImplementation_;
        treasuryImplementation = treasuryImplementation_;
        sortitionGovernanceImplementation = sortitionGovernanceImplementation_;
    }

    function createDAO(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        uint256 maxSupply,
        address randomnessSource,
        SortitionGovernance.SortitionGovernanceConfig calldata config,
        address[] calldata initialCouncil
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

        SortitionGovernance gov = SortitionGovernance(sortitionGovernanceImplementation.clone());
        gov.initialize(
            name,
            msg.sender,
            address(stakedToken),
            address(treasury),
            randomnessSource,
            config,
            initialCouncil
        );
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
        address randomnessSource,
        SortitionGovernance.SortitionGovernanceConfig calldata config,
        address[] calldata initialCouncil,
        address expectedGovernance
    ) external returns (address governance) {
        DAOFactoryLib.checkSwitch(treasury, token, stakedToken);
        governance = DAOFactoryLib.cloneForSwitch(sortitionGovernanceImplementation, switchNonce[msg.sender]++, expectedGovernance);
        SortitionGovernance(governance).initialize(
            name,
            msg.sender,
            stakedToken,
            treasury,
            randomnessSource,
            config,
            initialCouncil
        );

        _recordDAO(name, stakedToken, token, governance, treasury);
        predecessorOf[governance] = msg.sender;
        emit DAOSwitched(daoCount, msg.sender, governance, treasury);
    }

    /// @notice The address the next switch of `previousGovernance` to this
    ///         model will deploy to.
    function predictSwitchGovernance(address previousGovernance) external view returns (address) {
        return DAOFactoryLib.predictSwitch(sortitionGovernanceImplementation, previousGovernance, switchNonce[previousGovernance]);
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
