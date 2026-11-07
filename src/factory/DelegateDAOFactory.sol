// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/delegate/DelegateGovernance.sol";
import "../treasury/Treasury.sol";
import "../token/GovernanceToken.sol";
import "../token/StakedGovernanceToken.sol";
import "../governance/Types.sol";
import "./DAOFactoryLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title DelegateDAOFactory
/// @notice Deploys and wires together a governance token, staking wrapper,
///         treasury, and DelegateGovernance contract for a new DAO - the
///         same deployment shape as the original DAOFactory, with the
///         addition of the initial elected council DelegateGovernance
///         requires at construction.
/// @dev Clone-based - see QuadraticDAOFactory's own notes for why.
///      DelegateGovernance itself needs --via-ir to deploy (too large as
///      a standalone implementation even after this conversion - see its
///      own file for details); this factory's own bytecode is unaffected
///      by that and stays small regardless.
contract DelegateDAOFactory {
    using Clones for address;

    address public immutable governanceTokenImplementation;
    address public immutable stakedGovernanceTokenImplementation;
    address public immutable treasuryImplementation;
    address public immutable delegateGovernanceImplementation;
    /// @notice Settles tied council seats in every Delegate DAO made here
    ///         (Pyth Entropy, as Sortition uses); zero: ties go to whoever
    ///         declared first.
    address public immutable randomnessSource;

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
    event StakingCreated(address indexed deployer, address indexed token, address staking);

    event DAOCreated(uint256 indexed daoId, address indexed creator, address governance, address treasury, address token);

    constructor(
        address governanceTokenImplementation_,
        address stakedGovernanceTokenImplementation_,
        address treasuryImplementation_,
        address delegateGovernanceImplementation_,
        address randomnessSource_
    ) {
        require(governanceTokenImplementation_ != address(0), "Zero implementation");
        require(stakedGovernanceTokenImplementation_ != address(0), "Zero implementation");
        require(treasuryImplementation_ != address(0), "Zero implementation");
        require(delegateGovernanceImplementation_ != address(0), "Zero implementation");

        governanceTokenImplementation = governanceTokenImplementation_;
        stakedGovernanceTokenImplementation = stakedGovernanceTokenImplementation_;
        treasuryImplementation = treasuryImplementation_;
        delegateGovernanceImplementation = delegateGovernanceImplementation_;
        randomnessSource = randomnessSource_;
    }

    function createDAO(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        uint256 maxSupply,
        DelegateGovernance.DelegateGovernanceConfig calldata config,
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

        DelegateGovernance gov = DelegateGovernance(delegateGovernanceImplementation.clone());
        gov.initialize(
            name,
            msg.sender,
            address(stakedToken),
            address(treasury),
            config,
            initialCouncil,
            randomnessSource
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
        DelegateGovernance.DelegateGovernanceConfig calldata config,
        address[] calldata initialCouncil,
        address expectedGovernance
    ) external returns (address governance) {
        DAOFactoryLib.checkSwitch(treasury, token, stakedToken);
        governance = DAOFactoryLib.cloneForSwitch(delegateGovernanceImplementation, switchNonce[msg.sender]++, expectedGovernance);
        DelegateGovernance(governance).initialize(name, msg.sender, stakedToken, treasury, config, initialCouncil, randomnessSource);

        _recordDAO(name, stakedToken, token, governance, treasury);
        predecessorOf[governance] = msg.sender;
        emit DAOSwitched(daoCount, msg.sender, governance, treasury);
    }

    /*//////////////////////////////////////////////////////////////
                    NEW TOKENS AND STAKING CONTRACTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a staking contract for `token` owned by `owner`, at
    ///         predictStaking(msg.sender, salt). A DAO changing its token
    ///         calls it from a proposal, then points its governance at it
    ///         (setGovernanceToken). Anyone can call it; the contract is
    ///         useless until a governance uses it.
    function createStaking(address token, address owner, bytes32 salt) external returns (address staking) {
        staking = DAOFactoryLib.createStaking(stakedGovernanceTokenImplementation, token, owner, salt);
        emit StakingCreated(msg.sender, token, staking);
    }

    function predictStaking(address deployer, bytes32 salt) external view returns (address) {
        return DAOFactoryLib.predictStaking(stakedGovernanceTokenImplementation, deployer, salt);
    }

    /// @notice Creates a token (its whole initial supply minted to
    ///         `treasury`) and its staking contract, both owned by the
    ///         caller: for a DAO without a token switching to this model.
    ///         The switch proposal's later actions hand both to the new
    ///         governance.
    function createTokenForSwitch(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        uint256 maxSupply,
        address treasury,
        bytes32 salt
    ) external returns (address token, address staking) {
        (token, staking) = DAOFactoryLib.createTokenForSwitch(
            governanceTokenImplementation, stakedGovernanceTokenImplementation, name, symbol, initialSupply, maxSupply, treasury, salt
        );
        emit StakingCreated(msg.sender, token, staking);
    }

    /// @notice Where createTokenForSwitch(…, salt) called by `deployer` puts the token and its staking contract.
    function predictTokenForSwitch(address deployer, bytes32 salt) external view returns (address token, address staking) {
        token = DAOFactoryLib.predictToken(governanceTokenImplementation, deployer, salt);
        staking = DAOFactoryLib.predictStaking(stakedGovernanceTokenImplementation, deployer, salt);
    }

    /// @notice The address the next switch of `previousGovernance` to this
    ///         model will deploy to.
    function predictSwitchGovernance(address previousGovernance) external view returns (address) {
        return DAOFactoryLib.predictSwitch(delegateGovernanceImplementation, previousGovernance, switchNonce[previousGovernance]);
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
