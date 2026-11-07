// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IValuer.sol";

/// @dev Perpl's exchange, as far as valuing an account needs. Struct
///      layouts from the exchange ABI the bot uses
///      (protean-bot src/integrations/abis/perpl.json).
interface IPerplExchange {
    struct PositionBitMap {
        uint256 bank1;
        uint256 bank2;
        uint256 bank3;
        uint256 bank4;
    }

    struct AccountInfo {
        uint256 accountId;
        uint256 balanceCNS;
        uint256 lockedBalanceCNS;
        uint8 frozen;
        address accountAddr;
        PositionBitMap positions;
    }

    struct PositionInfo {
        uint256 accountId;
        uint256 nextNodeId;
        uint256 prevNodeId;
        uint8 positionType;
        uint256 depositCNS;
        uint256 pricePNS;
        uint256 lotLNS;
        uint256 entryBlock;
        int256 pnlCNS;
        int256 deltaPnlCNS;
        int256 premiumPnlCNS;
    }

    struct PerpetualInfo {
        string name;
        string symbol;
        uint256 priceDecimals;
        uint256 lotDecimals;
        bytes32 linkFeedId;
        uint256 priceTolPer100K;
        uint256 marginTol;
        uint256 marginTolDecimals;
        uint256 refPriceMaxAgeSec;
        uint256 positionBalanceCNS;
        uint256 insuranceBalanceCNS;
        uint256 markPNS;
        uint256 markTimestamp;
        uint256 lastPNS;
        uint256 lastTimestamp;
        uint256 oraclePNS;
        uint256 oracleTimestampSec;
        uint256 longOpenInterestLNS;
        uint256 shortOpenInterestLNS;
        uint256 fundingStartBlock;
        int16 fundingRatePct100k;
        uint256 absFundingClampPctPer100K;
        uint8 status;
        uint256 basePricePNS;
        uint256 maxBidPriceONS;
        uint256 minBidPriceONS;
        uint256 maxAskPriceONS;
        uint256 minAskPriceONS;
        uint256 numOrders;
        bool ignOracle;
    }

    function getAccountByAddr(address accountAddress) external view returns (AccountInfo memory);
    function getPosition(uint256 perpId, uint256 accountId) external view returns (PositionInfo memory, uint256 markPricePNS, bool markPriceValid);
    function getPerpetualInfo(uint256 perpId) external view returns (PerpetualInfo memory);
    function getExchangeInfo()
        external
        view
        returns (uint256 balanceCNS, uint256 protocolBalanceCNS, uint256 recycleBalanceCNS, uint256 collateralDecimals, address collateralToken, address verifierProxy);
}

/// @title PerplValuer
/// @notice Values a desk's Perpl account: its collateral balance, plus each
///         open position's margin and its PnL at the mark price, in the
///         markets the DAO lists (the only ones the bot lets traders use).
///         An invalid mark makes the value invalid, so the window waits.
/// @dev The same sum the bot shows for a desk (perpl.js openPositions):
///      margin + (mark - entry) x size, long or short. TO CONFIRM against a
///      mainnet fork before a vault relies on it, as the other Perpl actions
///      were: whether funding (premiumPnlCNS), pnlCNS / deltaPnlCNS and the
///      locked balance belong in the value. Until then this valuer counts
///      balance, margin and mark-price PnL only.
contract PerplValuer is IValuer {
    IPerplExchange public immutable exchange;
    address public immutable account; // the desk's address on Perpl
    uint8 public immutable assetDecimals;
    uint256[] internal _markets;

    constructor(IPerplExchange exchange_, address account_, uint256[] memory markets_, uint8 assetDecimals_) {
        exchange = exchange_;
        account = account_;
        _markets = markets_;
        assetDecimals = assetDecimals_;
    }

    function markets() external view returns (uint256[] memory) {
        return _markets;
    }

    function value() external view returns (uint256 assets, bool valid) {
        IPerplExchange.AccountInfo memory info;
        try exchange.getAccountByAddr(account) returns (IPerplExchange.AccountInfo memory a) {
            info = a;
        } catch {
            return (0, true); // no Perpl account yet: nothing there
        }
        (,,, uint256 cd,,) = exchange.getExchangeInfo();
        int256 total = int256(info.balanceCNS);
        for (uint256 i = 0; i < _markets.length; i++) {
            (IPerplExchange.PositionInfo memory p, uint256 mark, bool markValid) = exchange.getPosition(_markets[i], info.accountId);
            if (p.lotLNS == 0) continue;
            if (!markValid) return (0, false);
            IPerplExchange.PerpetualInfo memory perp = exchange.getPerpetualInfo(_markets[i]);
            int256 move = int256(mark) - int256(p.pricePNS);
            if (p.positionType != 0) move = -move; // positionType 0 is long
            int256 pnl = (move * int256(p.lotLNS) * int256(10 ** cd)) / int256(10 ** (perp.priceDecimals + perp.lotDecimals));
            total += int256(p.depositCNS) + pnl;
        }
        if (total <= 0) return (0, true);
        uint256 v = uint256(total);
        if (cd > assetDecimals) v /= 10 ** (cd - assetDecimals);
        else if (cd < assetDecimals) v *= 10 ** (assetDecimals - cd);
        return (v, true);
    }
}
