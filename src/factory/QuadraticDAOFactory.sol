// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/quadratic/QuadraticGovernance.sol";
import "../treasury/Treasury.sol";
import "../token/GovernanceToken.sol";
import "../token/StakedGovernanceToken.sol";
import "../governance/Types.sol";
import "./DAOFactoryLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title QuadraticDAOFactory
/// @notice Deploys and wires together a governance token, staking
///         wrapper, treasury, and QuadraticGovernance contract for a new
///         DAO - the same deployment shape as the original DAOFactory.
/// @dev Clone-based - all four implementations (token, staked token,
///      treasury, QuadraticGovernance) must be deployed once, separately,
///      before this factory, with their addresses passed in as
///      constructor arguments. See DAOFactoryLib's own notes for why
///      deploying them from inside this factory (constructor or
///      otherwise) would not solve the bytecode-size problem this exists
///      to fix.
contract QuadraticDAOFactory {
    using Clones for address;

    address public immutable governanceTokenImplementation;
    address public immutable stakedGovernanceTokenImplementation;
    address public immutable treasuryImplementation;
    address public immutable quadraticGovernanceImplementation;

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
        address quadraticGovernanceImplementation_
    ) {
        require(governanceTokenImplementation_ != address(0), "Zero implementation");
        require(stakedGovernanceTokenImplementation_ != address(0), "Zero implementation");
        require(treasuryImplementation_ != address(0), "Zero implementation");
        require(quadraticGovernanceImplementation_ != address(0), "Zero implementation");

        governanceTokenImplementation = governanceTokenImplementation_;
        stakedGovernanceTokenImplementation = stakedGovernanceTokenImplementation_;
        treasuryImplementation = treasuryImplementation_;
        quadraticGovernanceImplementation = quadraticGovernanceImplementation_;
    }

    function createDAO(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        uint256 maxSupply,
        QuadraticGovernance.QuadraticGovernanceConfig calldata config
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

        QuadraticGovernance gov = QuadraticGovernance(quadraticGovernanceImplementation.clone());
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
        QuadraticGovernance.QuadraticGovernanceConfig calldata config,
        address expectedGovernance
    ) external returns (address governance) {
        DAOFactoryLib.checkSwitch(treasury, token, stakedToken);
        governance = DAOFactoryLib.cloneForSwitch(quadraticGovernanceImplementation, switchNonce[msg.sender]++, expectedGovernance);
        QuadraticGovernance(governance).initialize(name, msg.sender, stakedToken, treasury, config);

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
        return DAOFactoryLib.predictSwitch(quadraticGovernanceImplementation, previousGovernance, switchNonce[previousGovernance]);
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
