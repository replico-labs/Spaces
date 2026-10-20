// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/board/BoardGovernance.sol";
import "../treasury/Treasury.sol";
import "../governance/Types.sol";
import "./DAOFactoryLib.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title BoardDAOFactory
/// @notice Deploys and wires together a treasury and BoardGovernance
///         contract for a new DAO. BoardGovernance is the one model in
///         this system that needs no token at all - a fixed set of
///         signers governs directly - so this factory, unlike every
///         other one, never deploys GovernanceToken or
///         StakedGovernanceToken. DAOInfo's token fields are recorded as
///         address(0) accordingly.
/// @dev Clone-based - see QuadraticDAOFactory's own notes for why. Only
///      two implementations needed here (Treasury, BoardGovernance),
///      matching this model's simpler, tokenless deployment shape.
contract BoardDAOFactory {
    using Clones for address;

    address public immutable treasuryImplementation;
    address public immutable boardGovernanceImplementation;

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

    event DAOCreated(uint256 indexed daoId, address indexed creator, address governance, address treasury);

    constructor(address treasuryImplementation_, address boardGovernanceImplementation_) {
        require(treasuryImplementation_ != address(0), "Zero implementation");
        require(boardGovernanceImplementation_ != address(0), "Zero implementation");

        treasuryImplementation = treasuryImplementation_;
        boardGovernanceImplementation = boardGovernanceImplementation_;
    }

    function createDAO(
        string calldata name,
        BoardGovernance.BoardGovernanceConfig calldata config,
        address[] calldata initialSigners
    ) external returns (address governance) {
        Treasury treasury = Treasury(payable(treasuryImplementation.clone()));
        treasury.initialize(address(this));

        BoardGovernance gov = BoardGovernance(boardGovernanceImplementation.clone());
        gov.initialize(name, msg.sender, address(treasury), config, initialSigners);
        governance = address(gov);

        treasury.transferGovernance(governance);

        _recordDAO(name, address(0), address(0), governance, address(treasury));
    }

    /// @notice Switches an existing DAO to this model. Deploys only the
    ///         governance contract, pointed at the DAO's own Treasury and
    ///         staking contract, at the address predictSwitchGovernance()
    ///         returned. Must be called by the DAO's current governance as
    ///         the first action of a switch proposal; the actions after it
    ///         hand the Treasury, token and staking contract to the new
    ///         governance, all in the same execution.
    ///         `token` and `stakedToken` are the DAO's existing token and
    ///         staking contract, if it has them; Board doesn't use them but
    ///         records them so a later switch back can find them.
    function createForSwitch(
        string calldata name,
        address treasury,
        address token,
        address stakedToken,
        BoardGovernance.BoardGovernanceConfig calldata config,
        address[] calldata initialSigners,
        address expectedGovernance
    ) external returns (address governance) {
        DAOFactoryLib.checkSwitch(treasury, token, stakedToken);
        governance = DAOFactoryLib.cloneForSwitch(boardGovernanceImplementation, switchNonce[msg.sender]++, expectedGovernance);
        BoardGovernance(governance).initialize(name, msg.sender, treasury, config, initialSigners);

        _recordDAO(name, stakedToken, token, governance, treasury);
        predecessorOf[governance] = msg.sender;
        emit DAOSwitched(daoCount, msg.sender, governance, treasury);
    }

    /// @notice The address the next switch of `previousGovernance` to this
    ///         model will deploy to.
    function predictSwitchGovernance(address previousGovernance) external view returns (address) {
        return DAOFactoryLib.predictSwitch(boardGovernanceImplementation, previousGovernance, switchNonce[previousGovernance]);
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
        emit DAOCreated(daoCount, msg.sender, governance, treasury);
    }

    function getCreatorDAOs(address creator) external view returns (address[] memory) {
        return creatorDAOs[creator];
    }
}
