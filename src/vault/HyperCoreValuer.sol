// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IValuer.sol";

/// @title HyperCoreValuer
/// @notice Values an account's money on HyperCore from HyperEVM: spot USDC
///         plus the perp account's value (unrealized PnL included), read
///         from HyperCore's own precompiles. Nothing to trust but the chain.
/// @dev Precompile addresses and layouts from hyper-evm-lib
///      (hyperliquid-dev/hyper-evm-lib: src/common/HLConstants.sol,
///      src/PrecompileLib.sol), as the bot's HyperCore integration uses:
///      - 0x…0801 spotBalance(user, token) -> (uint64 total, uint64 hold, uint64 entryNtl),
///        in the token's wei (weiDecimals from 0x…080C tokenInfo);
///      - 0x…080F accountMarginSummary(perpDex, user) -> (int64 accountValue,
///        uint64 marginUsed, uint64 ntlPos, int64 rawUsd), in perp USD units.
///      Perp USD is taken as 6 decimals (`perpUsdDecimals`), the scale of
///      CoreWriter's usdClassTransfer; the bot's verify step checks the
///      value against Hyperliquid's API before a vault uses this valuer.
contract HyperCoreValuer is IValuer {
    address internal constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant TOKEN_INFO = 0x000000000000000000000000000000000000080C;
    address internal constant ACCOUNT_MARGIN_SUMMARY = 0x000000000000000000000000000000000000080F;

    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct AccountMarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    /// @notice The account valued: the vault itself, which owns its HyperCore account.
    address public immutable account;
    uint32 public immutable perpDex;
    uint64 public immutable usdcToken; // HyperCore's USDC token index (0)
    uint8 public immutable perpUsdDecimals;
    uint8 public immutable assetDecimals; // the vault's asset (USDC on HyperEVM)

    error PrecompileFailed(address precompile);

    constructor(address account_, uint32 perpDex_, uint64 usdcToken_, uint8 perpUsdDecimals_, uint8 assetDecimals_) {
        account = account_;
        perpDex = perpDex_;
        usdcToken = usdcToken_;
        perpUsdDecimals = perpUsdDecimals_;
        assetDecimals = assetDecimals_;
    }

    function value() external view returns (uint256 assets, bool valid) {
        (bool ok, bytes memory out) = TOKEN_INFO.staticcall(abi.encode(usdcToken));
        if (!ok) revert PrecompileFailed(TOKEN_INFO);
        uint8 weiDecimals = abi.decode(out, (TokenInfo)).weiDecimals;

        (ok, out) = SPOT_BALANCE.staticcall(abi.encode(account, usdcToken));
        if (!ok) revert PrecompileFailed(SPOT_BALANCE);
        assets = _scale(abi.decode(out, (SpotBalance)).total, weiDecimals);

        (ok, out) = ACCOUNT_MARGIN_SUMMARY.staticcall(abi.encode(perpDex, account));
        if (!ok) revert PrecompileFailed(ACCOUNT_MARGIN_SUMMARY);
        int64 perp = abi.decode(out, (AccountMarginSummary)).accountValue;
        if (perp > 0) assets += _scale(uint64(perp), perpUsdDecimals);
        return (assets, true);
    }

    function _scale(uint256 amount, uint8 from) internal view returns (uint256) {
        if (from == assetDecimals) return amount;
        return from > assetDecimals ? amount / 10 ** (from - assetDecimals) : amount * 10 ** (assetDecimals - from);
    }
}
