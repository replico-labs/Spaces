// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./DistributionFactory.sol";
import "./Distributor.sol";
import "./Raise.sol";
import "../interfaces/ITreasury.sol";
import "../vault/VaultFactory.sol";

interface ILaunchToken {
    function setMinter(address minter) external;
}

interface ILaunchFactory {
    function daoCount() external view returns (uint256);
    function daos(uint256 daoId)
        external
        view
        returns (
            string memory name,
            address daoCreator,
            address governanceToken,
            address underlyingToken,
            address governance,
            address treasury,
            uint256 createdAt
        );
}

/// @title Launcher
/// @notice One per network. A founder sets up a new DAO's launch - which
///         model and rules, the token, the raise, the team and community
///         shares, the allowances agreed as terms of joining - and opens the
///         raise. When it ends, the founder accepts an amount and `finish`
///         does the rest in one transaction:
///         1. deploys the DAO through the model's factory;
///         2. creates its Distributor and moves the sale and share tokens in,
///            the rest of the supply to the Treasury;
///         3. accepts the raise: the money goes to the new Treasury, never
///            to the founder;
///         4. writes the team and community shares (with their vesting);
///         5. sets the agreed allowances on the Treasury.
///         Contributors then settle and claim through the raise and the
///         Distributor as usual.
///
///         A prop firm's launch differs in steps 2-3: its token is the
///         shares of a vault, so `finish` creates the vault, makes it the
///         token's minter, sends the accepted money into it, and the shares
///         it mints go to the Distributor for the contributors. No team
///         shares: a prop firm's tokens only come from deposits.
/// @dev The factory call is encoded by the bot for the chosen model and
///      fixed when the launch is created, so contributors can check it. Only
///      factories the owner approved may be called, and the DAO the call
///      makes must be the factory's newest, created by this contract.
contract Launcher is Ownable {
    using SafeERC20 for IERC20;

    struct Share {
        address owner;
        bytes32 account;
        uint256 amount;
        uint64 cliff;
        uint64 duration;
    }

    struct AllowanceTerm {
        address recipient;
        address token; // ignored when daoToken is set; address(0): the native coin
        bool daoToken; // pay in the DAO's own token (not known until launch)
        uint256 amount;
        uint64 duration; // from launch, at most a year
    }

    struct PropFirm {
        bool enabled;
        PropFirmVault.Config config; // the raise's currency is the vault's asset
    }

    struct Launch {
        address founder;
        address factory;
        bytes createCall;
        address raise;
        address operator;
        uint64 claimDeadline;
        bool finished;
        address governance;
        address treasury;
        address token;
        address distributor;
        address vault;
    }

    DistributionFactory public immutable distributionFactory;
    VaultFactory public immutable vaultFactory;

    mapping(address => bool) public approvedFactory;
    mapping(uint256 => Launch) internal _launches;
    mapping(uint256 => Share[]) internal _shares;
    mapping(uint256 => AllowanceTerm[]) internal _allowances;
    mapping(uint256 => PropFirm) internal _propFirm;
    uint256 public launchCount;

    event FactoryApproved(address indexed factory, bool approved);
    event LaunchCreated(uint256 indexed id, address indexed founder, address raise, address factory);
    event LaunchFinished(uint256 indexed id, address governance, address treasury, address token, address distributor, uint256 accepted);

    error FactoryNotApproved();
    error NotFounder();
    error AlreadyFinished();
    error FundsToMustBeEmpty();
    error CreateFailed(bytes reason);
    error UnexpectedDAO();
    error SupplyTooSmall(uint256 supply, uint256 needed);
    error InvalidPropFirm();

    constructor(DistributionFactory distributionFactory_, VaultFactory vaultFactory_, address owner_) Ownable(owner_) {
        distributionFactory = distributionFactory_;
        vaultFactory = vaultFactory_;
    }

    function approveFactory(address factory, bool approved) external onlyOwner {
        approvedFactory[factory] = approved;
        emit FactoryApproved(factory, approved);
    }

    /// @notice Sets up a launch and opens its raise. `terms.fundsTo` stays
    ///         empty: the Treasury is the one `finish` creates.
    function createLaunch(
        address factory,
        bytes calldata createCall,
        Raise.Terms calldata terms,
        Share[] calldata shares,
        AllowanceTerm[] calldata allowances,
        address operator,
        uint64 claimDeadline,
        PropFirm calldata propFirm
    ) external returns (uint256 id, address raise) {
        if (!approvedFactory[factory]) revert FactoryNotApproved();
        if (terms.fundsTo != address(0)) revert FundsToMustBeEmpty();
        // A prop firm's shares come from the accepted money: no fixed sale supply, no team shares, an ERC20 asset.
        if (propFirm.enabled && (terms.saleSupply != 0 || shares.length != 0 || terms.currency == address(0))) revert InvalidPropFirm();
        if (!propFirm.enabled && terms.saleSupply == 0) revert InvalidPropFirm();
        id = ++launchCount;
        raise = distributionFactory.createRaise(terms, bytes32(id));
        Launch storage l = _launches[id];
        l.founder = msg.sender;
        l.factory = factory;
        l.createCall = createCall;
        l.raise = raise;
        l.operator = operator;
        l.claimDeadline = claimDeadline;
        for (uint256 i = 0; i < shares.length; i++) _shares[id].push(shares[i]);
        for (uint256 i = 0; i < allowances.length; i++) _allowances[id].push(allowances[i]);
        if (propFirm.enabled) _propFirm[id] = propFirm;
        emit LaunchCreated(id, msg.sender, raise, factory);
    }

    /// @notice The founder accepts `amount` of the raise and the DAO is made.
    function finish(uint256 id, uint256 amount) external {
        Launch storage l = _launches[id];
        if (msg.sender != l.founder) revert NotFounder();
        if (l.finished) revert AlreadyFinished();
        l.finished = true;

        // 1. The DAO, through the model's factory.
        (bool ok, bytes memory ret) = l.factory.call(l.createCall);
        if (!ok) revert CreateFailed(ret);
        address governance = abi.decode(ret, (address));
        (, address creator,, address token, address recorded, address treasury,) =
            ILaunchFactory(l.factory).daos(ILaunchFactory(l.factory).daoCount());
        if (creator != address(this) || recorded != governance || token == address(0)) revert UnexpectedDAO();

        // 2. Its Distributor.
        address[] memory allocators = new address[](2);
        allocators[0] = l.raise;
        allocators[1] = address(this);
        address distributor = distributionFactory.createDistributor(token, treasury, l.operator, allocators, l.claimDeadline, bytes32(id));
        Share[] storage shares = _shares[id];

        if (_propFirm[id].enabled) {
            // 3 (prop firm). The vault, minting the DAO's token as its shares; the money goes in and
            // the first shares go to the Distributor for the contributors.
            address asset = Raise(l.raise).terms().currency;
            PropFirmVault.FeeSplit[] memory noFees = new PropFirmVault.FeeSplit[](0);
            address vault = vaultFactory.createVault(asset, token, treasury, address(this), _propFirm[id].config, noFees, bytes32(id));
            ILaunchToken(token).setMinter(vault);
            uint256 expected = amount * 10 ** (18 - IERC20Metadata(asset).decimals());
            Raise(l.raise).acceptWithSupply(amount, vault, distributor, expected);
            uint256 minted = PropFirmVault(payable(vault)).seed(distributor);
            if (minted != expected) revert InvalidPropFirm();
            l.vault = vault;
            // Any starting supply the factory minted goes to the Treasury.
            uint256 starting = IERC20(token).balanceOf(address(this));
            if (starting > 0) IERC20(token).safeTransfer(treasury, starting);
        } else {
            // 2b. The sale and the shares into the Distributor; the rest of the supply to the Treasury.
            uint256 needed = Raise(l.raise).terms().saleSupply;
            for (uint256 i = 0; i < shares.length; i++) needed += shares[i].amount;
            uint256 supply = IERC20(token).balanceOf(address(this));
            if (supply < needed) revert SupplyTooSmall(supply, needed);
            IERC20(token).safeTransfer(distributor, needed);
            if (supply > needed) IERC20(token).safeTransfer(treasury, supply - needed);

            // 3. The raise: the accepted money goes to the new Treasury.
            Raise(l.raise).accept(amount, treasury, distributor);
        }

        // 4. Team and community shares.
        for (uint256 i = 0; i < shares.length; i++) {
            Share storage s = shares[i];
            Distributor(distributor).allocate(s.owner, s.account, s.amount, uint64(block.timestamp), s.cliff, s.duration);
        }

        // 5. The agreed allowances (the Treasury lets its launch contract do this in this block only).
        AllowanceTerm[] storage allowances = _allowances[id];
        for (uint256 i = 0; i < allowances.length; i++) {
            AllowanceTerm storage a = allowances[i];
            ITreasury(treasury).createAllowance(a.recipient, a.daoToken ? token : a.token, a.amount, uint64(block.timestamp + a.duration));
        }
        ITreasury(treasury).endSetup();

        l.governance = governance;
        l.treasury = treasury;
        l.token = token;
        l.distributor = distributor;
        emit LaunchFinished(id, governance, treasury, token, distributor, amount);
    }

    function launch(uint256 id) external view returns (Launch memory) {
        return _launches[id];
    }

    function shares(uint256 id) external view returns (Share[] memory) {
        return _shares[id];
    }

    function propFirm(uint256 id) external view returns (PropFirm memory) {
        return _propFirm[id];
    }

    function allowances(uint256 id) external view returns (AllowanceTerm[] memory) {
        return _allowances[id];
    }
}
