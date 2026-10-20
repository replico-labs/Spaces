// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/futarchy/DecisionMarketsGovernance.sol";
import "../governance/futarchy/ConditionalToken.sol";
import "../governance/futarchy/ConditionalVault.sol";
import "../governance/futarchy/DecisionMarketPair.sol";
import "../treasury/Treasury.sol";
import "../token/GovernanceToken.sol";
import "../token/StakedGovernanceToken.sol";
import "../governance/Types.sol";
import "./DAOFactoryLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title DecisionMarketsDAOFactory
/// @notice Deploys and wires together a governance token, staking
///         wrapper, treasury, and DecisionMarketsGovernance contract for
///         a new DAO. ConditionalToken, ConditionalVault, and
///         DecisionMarketPair are stateless clone implementations, shared
///         across every DAO this factory ever creates. WMON is supplied
///         the same way, since it is meant to be one canonical shared
///         deployment across the whole chain, not something each DAO
///         gets its own copy of.
/// @dev Clone-based, all 8 implementations included - this factory
///      previously deployed ConditionalToken/ConditionalVault/
///      DecisionMarketPair from inside its OWN constructor, which does
///      NOT solve the bytecode-embedding problem (a child's creation
///      bytecode is embedded in the caller's bytecode regardless of
///      which function contains the `new` call - constructor included).
///      This was the worst offender of all ten factories in this system
///      for exactly that reason. All 8 implementations - the 4 standard
///      ones plus wmon, conditionalToken, conditionalVault, and
///      decisionMarketPair - must now be deployed once, separately,
///      before this factory, with their addresses passed in as
///      constructor arguments.
contract DecisionMarketsDAOFactory {
    using Clones for address;

    address public immutable governanceTokenImplementation;
    address public immutable stakedGovernanceTokenImplementation;
    address public immutable treasuryImplementation;
    address public immutable decisionMarketsGovernanceImplementation;

    address public immutable wmon;
    address public immutable conditionalTokenImplementation;
    address public immutable conditionalVaultImplementation;
    address public immutable decisionMarketPairImplementation;

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

    error ZeroAddress();

    constructor(
        address governanceTokenImplementation_,
        address stakedGovernanceTokenImplementation_,
        address treasuryImplementation_,
        address decisionMarketsGovernanceImplementation_,
        address wmon_,
        address conditionalTokenImplementation_,
        address conditionalVaultImplementation_,
        address decisionMarketPairImplementation_
    ) {
        if (
            governanceTokenImplementation_ == address(0) ||
            stakedGovernanceTokenImplementation_ == address(0) ||
            treasuryImplementation_ == address(0) ||
            decisionMarketsGovernanceImplementation_ == address(0) ||
            wmon_ == address(0) ||
            conditionalTokenImplementation_ == address(0) ||
            conditionalVaultImplementation_ == address(0) ||
            decisionMarketPairImplementation_ == address(0)
        ) revert ZeroAddress();

        governanceTokenImplementation = governanceTokenImplementation_;
        stakedGovernanceTokenImplementation = stakedGovernanceTokenImplementation_;
        treasuryImplementation = treasuryImplementation_;
        decisionMarketsGovernanceImplementation = decisionMarketsGovernanceImplementation_;

        wmon = wmon_;
        conditionalTokenImplementation = conditionalTokenImplementation_;
        conditionalVaultImplementation = conditionalVaultImplementation_;
        decisionMarketPairImplementation = decisionMarketPairImplementation_;
    }

    function createDAO(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        uint256 maxSupply,
        DecisionMarketsGovernance.DecisionMarketsConfig calldata config
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

        DecisionMarketsGovernance gov = DecisionMarketsGovernance(payable(decisionMarketsGovernanceImplementation.clone()));
        gov.initialize(
            name,
            msg.sender,
            address(stakedToken),
            address(treasury),
            wmon,
            conditionalTokenImplementation,
            conditionalVaultImplementation,
            decisionMarketPairImplementation,
            config
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
        DecisionMarketsGovernance.DecisionMarketsConfig calldata config,
        address expectedGovernance
    ) external returns (address governance) {
        DAOFactoryLib.checkSwitch(treasury, token, stakedToken);
        governance = DAOFactoryLib.cloneForSwitch(decisionMarketsGovernanceImplementation, switchNonce[msg.sender]++, expectedGovernance);
        DecisionMarketsGovernance(payable(governance)).initialize(
            name,
            msg.sender,
            stakedToken,
            treasury,
            wmon,
            conditionalTokenImplementation,
            conditionalVaultImplementation,
            decisionMarketPairImplementation,
            config
        );

        _recordDAO(name, stakedToken, token, governance, treasury);
        predecessorOf[governance] = msg.sender;
        emit DAOSwitched(daoCount, msg.sender, governance, treasury);
    }

    /// @notice The address the next switch of `previousGovernance` to this
    ///         model will deploy to.
    function predictSwitchGovernance(address previousGovernance) external view returns (address) {
        return DAOFactoryLib.predictSwitch(decisionMarketsGovernanceImplementation, previousGovernance, switchNonce[previousGovernance]);
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
