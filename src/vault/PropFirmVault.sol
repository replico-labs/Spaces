// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./IValuer.sol";

interface IVaultShares is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

interface IVaultTreasury {
    function governance() external view returns (address);
}

/// @title PropFirmVault
/// @notice A prop-firm DAO's fund: depositors' money is traded through the
///         DAO's desks, and the vault's shares are the DAO's own token.
///         Deposits and redemptions are requested at any time and priced
///         together at the next window, at the vault's value then, so
///         traders aren't forced to close positions to pay someone out.
/// @dev Accounting per window (epoch): requests add up; processWindow
///      values the vault (idle money plus every venue's valuer), takes
///      fees, prices redemptions (burned, their money owed) and then
///      deposits (shares minted), all at one price. Members claim their
///      shares or money afterwards.
///
///      Money moves to and from the venues only through `execute`, by the
///      DAO (whoever its Treasury answers to). Moves stop `freezeBefore`
///      ahead of a window and the window waits `settleDelay` after the last
///      move, so nothing in flight (e.g. a HyperEVM to HyperCore transfer,
///      which HyperCore processes after the block) is missed or counted
///      twice. A stale price on any venue makes the window wait.
///
///      Fees: a yearly management fee and a performance fee above the high
///      water mark (the best share price after fees), minted as shares and
///      split between the trader(s) and the Treasury as the DAO configures.
///      Drawdown: when the share price falls more than `maxDrawdownBps`
///      below the high water mark, `paused` is set - the bot stops signing
///      traders' orders - until a proposal resumes trading.
contract PropFirmVault is Initializable {
    using SafeERC20 for IERC20;

    struct FeeSplit {
        address recipient;
        uint16 bps; // of each fee; the splits add up to 10,000
    }

    struct Config {
        uint64 interval; // between windows, e.g. 30 days
        uint64 freezeBefore; // no moves this long before a window
        uint64 settleDelay; // a window waits this long after the last move
        uint16 managementBps; // per year, of the vault's value
        uint16 performanceBps; // of gains above the high water mark
        uint16 maxDrawdownBps; // below the high water mark that pauses trading; 0: off
        bool openToAll; // false: only addresses the DAO allowed may deposit
    }

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant ONE = 1e18;

    IERC20 public asset;
    IVaultShares public shares;
    address public treasury;
    /// @notice The launch contract that may seed the vault once, while it has no shares.
    address public seeder;

    Config internal _config;
    FeeSplit[] internal _feeSplits;
    address[] internal _valuers;
    mapping(address => bool) public allowed;

    /// @notice The open epoch: requests made now are priced at its window.
    uint256 public epoch;
    uint64 public nextWindowAt;
    uint64 public lastMoveAt;
    uint64 public lastFeeAt;
    /// @notice The best share price after fees so far (asset units per 1e18 shares, 1e18-scaled).
    uint256 public highWater;
    bool public paused;

    uint256 public pendingDepositAssets; // in the open epoch
    uint256 public owedAssets; // redemptions priced, not yet paid
    uint256 internal _initialRate; // shares per asset unit for the first deposit

    mapping(uint256 => uint256) public epochDepositAssets;
    mapping(uint256 => uint256) public epochDepositShares;
    mapping(uint256 => uint256) public epochRedeemShares;
    mapping(uint256 => uint256) public epochRedeemAssets;
    mapping(uint256 => mapping(address => uint256)) public depositOf;
    mapping(uint256 => mapping(address => uint256)) public redeemOf;
    mapping(uint256 => mapping(address => uint256)) public redeemPaid;

    event DepositRequested(uint256 indexed epoch, address indexed who, uint256 assets);
    event DepositCancelled(uint256 indexed epoch, address indexed who, uint256 assets);
    event RedeemRequested(uint256 indexed epoch, address indexed who, uint256 shares);
    event RedeemCancelled(uint256 indexed epoch, address indexed who, uint256 shares);
    event WindowProcessed(uint256 indexed epoch, uint256 value, uint256 supply, uint256 feeShares, uint256 redeemedShares, uint256 redeemedAssets, uint256 depositedAssets, uint256 mintedShares);
    event SharesClaimed(uint256 indexed epoch, address indexed who, uint256 shares);
    event RedemptionPaid(uint256 indexed epoch, address indexed who, uint256 assets);
    event Moved(address indexed target, uint256 value, bytes data);
    event Paused(uint256 price, uint256 highWater);
    event Resumed();
    event Seeded(address indexed receiver, uint256 assets, uint256 shares);
    event ValuerSet(address indexed valuer, bool added);
    event ConfigSet();

    error Unauthorized();
    error ZeroAmount();
    error NotAllowed();
    error WindowNotDue(uint64 at);
    error MovesFrozen(uint64 window);
    error Settling(uint64 until);
    error StalePrice(address valuer);
    error NotProcessed();
    error NothingToClaim();
    error NotLiquid(uint256 available);
    error AlreadySeeded();
    error VaultEmpty();
    error InvalidConfig();
    error MoveFailed(bytes reason);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address asset_,
        address shares_,
        address treasury_,
        address seeder_,
        Config calldata config_,
        FeeSplit[] calldata feeSplits_
    ) external initializer {
        asset = IERC20(asset_);
        shares = IVaultShares(shares_);
        treasury = treasury_;
        seeder = seeder_;
        uint8 assetDecimals = IERC20Metadata(asset_).decimals();
        if (assetDecimals > 18) revert InvalidConfig();
        _initialRate = 10 ** (18 - assetDecimals); // 1 share per asset unit (one USDC buys one share)
        _setConfig(config_);
        _setFeeSplits(feeSplits_);
        epoch = 1;
        nextWindowAt = uint64(block.timestamp + config_.interval);
        lastFeeAt = uint64(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Whoever the Treasury answers to: the governance, or its council's wrapper.
    function admin() public view returns (address) {
        return IVaultTreasury(treasury).governance();
    }

    modifier onlyAdmin() {
        if (msg.sender != admin()) revert Unauthorized();
        _;
    }

    /// @notice Moves money to or from a venue, or acts on one (e.g. a
    ///         HyperCore action through CoreWriter, a Perpl deposit). Only
    ///         the DAO, never on the share token (the vault is its minter,
    ///         and it holds members' shares), and not in the run-up to a window.
    function execute(address target, uint256 value, bytes calldata data) external onlyAdmin returns (bytes memory result) {
        if (target == address(shares)) revert Unauthorized();
        if (block.timestamp + _config.freezeBefore >= nextWindowAt) revert MovesFrozen(nextWindowAt);
        lastMoveAt = uint64(block.timestamp);
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) revert MoveFailed(result);
        emit Moved(target, value, data);
    }

    function setValuer(address valuer, bool add) external onlyAdmin {
        if (add) {
            _valuers.push(valuer);
        } else {
            for (uint256 i = 0; i < _valuers.length; i++) {
                if (_valuers[i] == valuer) {
                    _valuers[i] = _valuers[_valuers.length - 1];
                    _valuers.pop();
                    break;
                }
            }
        }
        emit ValuerSet(valuer, add);
    }

    function setConfig(Config calldata config_) external onlyAdmin {
        _setConfig(config_);
    }

    function setFeeSplits(FeeSplit[] calldata splits) external onlyAdmin {
        _setFeeSplits(splits);
    }

    function setAllowed(address who, bool ok) external onlyAdmin {
        allowed[who] = ok;
    }

    /// @notice Resumes trading after a drawdown pause. A proposal.
    function resume() external onlyAdmin {
        paused = false;
        emit Resumed();
    }

    /// @notice Pauses trading by proposal, e.g. ahead of a vote on the desk.
    function pause() external onlyAdmin {
        paused = true;
        emit Paused(0, highWater);
    }

    function _setConfig(Config calldata c) internal {
        if (c.interval == 0 || c.freezeBefore >= c.interval) revert InvalidConfig();
        if (c.managementBps > 1_000 || c.performanceBps > 5_000 || c.maxDrawdownBps > BPS) revert InvalidConfig();
        _config = c;
        emit ConfigSet();
    }

    function _setFeeSplits(FeeSplit[] calldata splits) internal {
        delete _feeSplits;
        uint256 total;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].recipient == address(0)) revert InvalidConfig();
            total += splits[i].bps;
            _feeSplits.push(splits[i]);
        }
        if (splits.length > 0 && total != BPS) revert InvalidConfig();
    }

    /*//////////////////////////////////////////////////////////////
                               SEEDING
    //////////////////////////////////////////////////////////////*/

    /// @notice A launch's money, already sent here, becomes the first shares
    ///         for `receiver` (the Distributor, which shares them among the
    ///         raise's contributors). Once, by the launch contract.
    function seed(address receiver) external returns (uint256 minted) {
        if (msg.sender != seeder) revert Unauthorized();
        if (shares.totalSupply() != 0) revert AlreadySeeded();
        seeder = address(0);
        uint256 assets = asset.balanceOf(address(this)) - pendingDepositAssets;
        if (assets == 0) revert ZeroAmount();
        minted = assets * _initialRate;
        shares.mint(receiver, minted);
        highWater = ONE * assets / minted; // the starting price
        emit Seeded(receiver, assets, minted);
    }

    /*//////////////////////////////////////////////////////////////
                              REQUESTS
    //////////////////////////////////////////////////////////////*/

    function requestDeposit(uint256 assets) external {
        if (assets == 0) revert ZeroAmount();
        if (!_config.openToAll && !allowed[msg.sender]) revert NotAllowed();
        asset.safeTransferFrom(msg.sender, address(this), assets);
        depositOf[epoch][msg.sender] += assets;
        epochDepositAssets[epoch] += assets;
        pendingDepositAssets += assets;
        emit DepositRequested(epoch, msg.sender, assets);
    }

    function cancelDeposit() external {
        uint256 assets = depositOf[epoch][msg.sender];
        if (assets == 0) revert NothingToClaim();
        depositOf[epoch][msg.sender] = 0;
        epochDepositAssets[epoch] -= assets;
        pendingDepositAssets -= assets;
        asset.safeTransfer(msg.sender, assets);
        emit DepositCancelled(epoch, msg.sender, assets);
    }

    /// @notice Hands `amount` shares to the vault to redeem at the next window.
    function requestRedeem(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        IERC20(address(shares)).safeTransferFrom(msg.sender, address(this), amount);
        redeemOf[epoch][msg.sender] += amount;
        epochRedeemShares[epoch] += amount;
        emit RedeemRequested(epoch, msg.sender, amount);
    }

    function cancelRedeem() external {
        uint256 amount = redeemOf[epoch][msg.sender];
        if (amount == 0) revert NothingToClaim();
        redeemOf[epoch][msg.sender] = 0;
        epochRedeemShares[epoch] -= amount;
        IERC20(address(shares)).safeTransfer(msg.sender, amount);
        emit RedeemCancelled(epoch, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               WINDOWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The vault's value now: idle money (less pending deposits and
    ///         what's owed to redeemers) plus every venue, marked to market.
    ///         Reverts on a stale price.
    function totalValue() public view returns (uint256 value) {
        uint256 idle = asset.balanceOf(address(this));
        uint256 reserved = pendingDepositAssets + owedAssets;
        value = idle > reserved ? idle - reserved : 0;
        for (uint256 i = 0; i < _valuers.length; i++) {
            (uint256 v, bool valid) = IValuer(_valuers[i]).value();
            if (!valid) revert StalePrice(_valuers[i]);
            value += v;
        }
    }

    /// @notice Prices the open epoch's requests. Anyone, once the window is
    ///         due and nothing has moved for `settleDelay`.
    function processWindow() external {
        if (block.timestamp < nextWindowAt) revert WindowNotDue(nextWindowAt);
        uint64 settled = lastMoveAt + _config.settleDelay;
        if (block.timestamp < settled) revert Settling(settled);

        uint256 e = epoch;
        uint256 value = totalValue();
        uint256 supply = shares.totalSupply();
        uint256 feeShares = _takeFees(value, supply);
        supply += feeShares;

        // Redemptions first, then deposits, at the same price.
        uint256 redeemShares = epochRedeemShares[e];
        uint256 redeemAssets;
        if (redeemShares > 0) {
            redeemAssets = supply == 0 ? 0 : (redeemShares * value) / supply;
            shares.burn(redeemShares);
            owedAssets += redeemAssets;
            value -= redeemAssets;
            supply -= redeemShares;
            epochRedeemAssets[e] = redeemAssets;
        }

        uint256 depositAssets = epochDepositAssets[e];
        uint256 minted;
        if (depositAssets > 0) {
            if (supply == 0) {
                minted = depositAssets * _initialRate;
            } else {
                if (value == 0) revert VaultEmpty();
                minted = (depositAssets * supply) / value;
            }
            pendingDepositAssets -= depositAssets;
            shares.mint(address(this), minted);
            epochDepositShares[e] = minted;
            value += depositAssets;
            supply += minted;
        }

        if (supply > 0) {
            uint256 price = (value * ONE) / supply;
            if (highWater == 0) highWater = price;
            if (_config.maxDrawdownBps != 0 && price < (highWater * (BPS - _config.maxDrawdownBps)) / BPS && !paused) {
                paused = true;
                emit Paused(price, highWater);
            }
        }

        epoch = e + 1;
        uint64 next = nextWindowAt;
        while (next <= block.timestamp) next += _config.interval;
        nextWindowAt = next;
        emit WindowProcessed(e, value, supply, feeShares, redeemShares, redeemAssets, depositAssets, minted);
    }

    /// @notice Anyone (the bot's keeper) can check the drawdown between
    ///         windows: below the limit, trading pauses until a proposal resumes it.
    function checkDrawdown() external returns (bool nowPaused) {
        uint256 supply = shares.totalSupply();
        if (supply == 0 || paused || _config.maxDrawdownBps == 0 || highWater == 0) return paused;
        uint256 price = (totalValue() * ONE) / supply;
        if (price < (highWater * (BPS - _config.maxDrawdownBps)) / BPS) {
            paused = true;
            emit Paused(price, highWater);
        }
        return paused;
    }

    /// @dev Management fee for the time since the last window, and the
    ///      performance fee above the high water mark, minted as shares so
    ///      their holders own exactly the fee's value.
    function _takeFees(uint256 value, uint256 supply) internal returns (uint256 feeShares) {
        uint256 elapsed = block.timestamp - lastFeeAt;
        lastFeeAt = uint64(block.timestamp);
        if (supply == 0 || value == 0 || _feeSplits.length == 0) return 0;
        uint256 fee = (value * _config.managementBps * elapsed) / (BPS * YEAR);
        uint256 price = ((value - fee) * ONE) / supply;
        if (price > highWater && highWater != 0) {
            fee += ((price - highWater) * supply * _config.performanceBps) / (ONE * BPS);
        }
        if (fee == 0 || fee >= value) {
            if (price > highWater) highWater = price;
            return 0;
        }
        feeShares = (fee * supply) / (value - fee);
        uint256 left = feeShares;
        for (uint256 i = 0; i < _feeSplits.length; i++) {
            uint256 part = i == _feeSplits.length - 1 ? left : (feeShares * _feeSplits[i].bps) / BPS;
            left -= part;
            if (part > 0) shares.mint(_feeSplits[i].recipient, part);
        }
        uint256 after_ = (value * ONE) / (supply + feeShares);
        if (after_ > highWater) highWater = after_;
    }

    /*//////////////////////////////////////////////////////////////
                               CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Your shares from a processed epoch's deposit.
    function claimShares(uint256 e) external returns (uint256 amount) {
        if (e >= epoch) revert NotProcessed();
        uint256 assets = depositOf[e][msg.sender];
        if (assets == 0) revert NothingToClaim();
        depositOf[e][msg.sender] = 0;
        amount = (assets * epochDepositShares[e]) / epochDepositAssets[e];
        IERC20(address(shares)).safeTransfer(msg.sender, amount);
        emit SharesClaimed(e, msg.sender, amount);
    }

    /// @notice Your money from a processed epoch's redemption, as far as the
    ///         vault holds it (the rest once the desks have returned money).
    function claimRedemption(uint256 e) external returns (uint256 amount) {
        if (e >= epoch) revert NotProcessed();
        uint256 redeemed = redeemOf[e][msg.sender];
        if (redeemed == 0) revert NothingToClaim();
        uint256 owed = (redeemed * epochRedeemAssets[e]) / epochRedeemShares[e] - redeemPaid[e][msg.sender];
        if (owed == 0) revert NothingToClaim();
        uint256 balance = asset.balanceOf(address(this));
        uint256 available = balance > pendingDepositAssets ? balance - pendingDepositAssets : 0;
        amount = owed < available ? owed : available;
        if (amount == 0) revert NotLiquid(0);
        redeemPaid[e][msg.sender] += amount;
        owedAssets -= amount;
        asset.safeTransfer(msg.sender, amount);
        emit RedemptionPaid(e, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function config() external view returns (Config memory) {
        return _config;
    }

    function feeSplits() external view returns (FeeSplit[] memory) {
        return _feeSplits;
    }

    function valuers() external view returns (address[] memory) {
        return _valuers;
    }

    /// @notice The share price now (asset units per 1e18 shares, 1e18-scaled); reverts on a stale price.
    function sharePrice() external view returns (uint256) {
        uint256 supply = shares.totalSupply();
        if (supply == 0) return ONE / _initialRate;
        return (totalValue() * ONE) / supply;
    }

    receive() external payable {}
}
