// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/Governance.sol";
import "../treasury/Treasury.sol";
import "../token/GovernanceToken.sol";
import "../token/StakedGovernanceToken.sol";
import "../governance/Types.sol";
import "./IDAOFactory.sol";
import "./DAOFactoryLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title DAOFactory
/// @notice Deploys and wires together a governance token, staking wrapper,
///         treasury and governance contract for a new DAO.
/// @dev Deployment order matters here because of a circular dependency:
///      Treasury and StakedGovernanceToken must exist before Governance can
///      be constructed (Governance's constructor takes their addresses),
///      but Treasury and GovernanceToken each need to recognize Governance
///      as their controller once it exists. The factory itself is
///      temporarily installed as the controller of both (as the initial
///      Ownable owner of the token, and as the initial `governance` of the
///      Treasury), and hands control off to the real Governance contract
///      immediately after it is deployed, within the same transaction.
///
///      Voting power is not derived from raw token balance. Holders must
///      stake their GovernanceToken into the StakedGovernanceToken wrapper
///      to receive voting power - see StakedGovernanceToken for why.
///      Governance is pointed at the staking wrapper, not the raw token,
///      so every quorum/approval/proposal-threshold check in Governance.sol
///      is already scoped to staked (committed) supply with zero changes
///      needed there.
///
///      Clone-based deployment: this factory used to directly `new` all
///      four contracts per DAO, which embeds each one's FULL creation
///      bytecode inside the factory's own bytecode - the reason this
///      factory (and every other one in this system) exceeded Ethereum's
///      24,576-byte contract size limit by roughly 3x. Deploying the
///      implementations from inside the factory's own constructor does
///      NOT fix this - the child's creation bytecode is embedded in the
///      factory's bytecode regardless of which function contains the
///      `new` call, constructor included. The four implementations must
///      be deployed as their own separate, standalone transactions
///      *before* this factory, with their resulting addresses passed in
///      here as constructor arguments. createDAO() then deploys cheap
///      ~45-byte EIP-1167 clones pointing at those addresses, and
///      initializes each clone exactly as the original constructors did.
///      StakedGovernanceToken's ownership goes to governance along with
///      the token and Treasury, so the DAO can later switch models
///      (createForSwitch) and hand all three to the new governance.
contract DAOFactory is IDAOFactory {
    using Clones for address;

    address public immutable governanceTokenImplementation;
    address public immutable stakedGovernanceTokenImplementation;
    address public immutable treasuryImplementation;
    address public immutable governanceImplementation;

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

    constructor(
        address governanceTokenImplementation_,
        address stakedGovernanceTokenImplementation_,
        address treasuryImplementation_,
        address governanceImplementation_
    ) {
        require(governanceTokenImplementation_ != address(0), "Zero implementation");
        require(stakedGovernanceTokenImplementation_ != address(0), "Zero implementation");
        require(treasuryImplementation_ != address(0), "Zero implementation");
        require(governanceImplementation_ != address(0), "Zero implementation");

        governanceTokenImplementation = governanceTokenImplementation_;
        stakedGovernanceTokenImplementation = stakedGovernanceTokenImplementation_;
        treasuryImplementation = treasuryImplementation_;
        governanceImplementation = governanceImplementation_;
    }

    function createDAO(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        uint256 maxSupply,
        GovernanceConfig calldata config
    ) external returns (address governance) {
        // Initial supply goes to the DAO creator; the factory is only the
        // temporary Ownable owner so it can hand off minting rights to
        // Governance once Governance exists.
        GovernanceToken token = GovernanceToken(governanceTokenImplementation.clone());
        token.initialize(name, symbol, initialSupply, maxSupply, msg.sender, address(this));

        StakedGovernanceToken stakedToken = StakedGovernanceToken(stakedGovernanceTokenImplementation.clone());
        stakedToken.initialize(
            address(token),
            string.concat("Staked ", name),
            string.concat("s", symbol),
            address(this)
        );

        Treasury treasury = Treasury(payable(treasuryImplementation.clone()));
        treasury.initialize(address(this));

        Governance gov = Governance(governanceImplementation.clone());
        gov.initialize(
            name,
            msg.sender,
            address(stakedToken),
            address(treasury),
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
        GovernanceConfig calldata config,
        address expectedGovernance
    ) external returns (address governance) {
        DAOFactoryLib.checkSwitch(treasury, token, stakedToken);
        governance = DAOFactoryLib.cloneForSwitch(governanceImplementation, switchNonce[msg.sender]++, expectedGovernance);
        Governance(governance).initialize(name, msg.sender, stakedToken, treasury, config);

        _recordDAO(name, stakedToken, token, governance, treasury);
        predecessorOf[governance] = msg.sender;
        emit DAOSwitched(daoCount, msg.sender, governance, treasury);
    }

    /// @notice The address the next switch of `previousGovernance` to this
    ///         model will deploy to.
    function predictSwitchGovernance(address previousGovernance) external view returns (address) {
        return DAOFactoryLib.predictSwitch(governanceImplementation, previousGovernance, switchNonce[previousGovernance]);
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
