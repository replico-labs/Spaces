// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    FHE,
    euint32,
    euint64,
    ebool,
    externalEuint32,
    externalEuint64
} from "@fhevm/solidity/lib/FHE.sol";
import { ZamaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title OpportunityMarket
/// @author Marvin Sunday
/// @notice A confidential opportunity-backing system: anyone can list an
///         opportunity, anyone can back one with a private amount, and
///         WHICH opportunity someone backed stays hidden too - not just
///         how much. Not adversarial or pari-mutuel: everyone's own stake
///         is always returned to them regardless of outcome. Instead, the
///         deployer separately commits a reward pool, paid out only to
///         whoever backed the opportunity that turned out real - the
///         deployer resolves this directly, since they're the one
///         actually acting on the opportunity and so the one who
///         genuinely knows the outcome. Deployed as a clone by
///         OpportunityMarketFactory - see that contract for the
///         DAO-style "anyone can deploy a market" entry point.
///
/// @dev HONESTY NOTES - read before deploying this anywhere real:
///
///      Every FHE.* call below is verified against the real, installed
///      fhevm/solidity v0.13.3 package - not guessed or written from
///      documentation snippets. What I cannot independently audit is
///      whether the overall CIRCUIT this builds is cryptographically
///      sound the way I could hand-trace an AMM invariant. Treat this as
///      a first draft on a verified foundation, not an audited system.
///
///      CLONE-SAFETY: this contract does NOT inherit Zama's
///      ZamaEthereumConfig, deliberately. That config contract wires up
///      the coprocessor inside its CONSTRUCTOR - which, for a contract
///      meant to be deployed via minimal-proxy clones, would only ever
///      run once, on the implementation itself, and silently never run
///      for any actual clone (the exact same class of bug already caught
///      once elsewhere in this codebase with a reentrancy-lock flag,
///      here applying to core cryptographic wiring instead). Coprocessor
///      setup happens explicitly inside initialize() instead.
///
///      WHAT STAYS PRIVATE: once deposited, both the AMOUNT backing an
///      opportunity and WHICH opportunity was chosen stay encrypted
///      end-to-end - the opportunity id is never a plaintext storage
///      key, so no eth_getStorageAt pattern can reveal it.
///
///      WHAT IS NOT PRIVATE: the initial deposit amount is a plain
///      ERC20 transferFrom, visible like any ordinary transfer. A true
///      confidential token (OpenZeppelin's real ERC7984 wrapper) would
///      close this too, but it currently pins fhevm/solidity version
///      0.11.1 as a peer dependency - two versions behind what's
///      actually live on Sepolia - so using it would mean deploying
///      against infrastructure it was never tested against. Deferred,
///      not overlooked. Also disclosed: which opportunity won IS
///      revealed in plaintext at resolution, and the AGGREGATE total
///      backing the winner is revealed in plaintext during payout
///      finalization (see finalizeWinningTotal) - individual positions
///      still never are.
///
///      PAYOUT MATH AND OVERFLOW: encrypted-by-encrypted division isn't
///      supported by this library at all (only dividing an encrypted
///      value by a known plaintext constant is). The payout is computed
///      as (qualifyingStake * rewardPool) / winningTotalBacking - an
///      encrypted*encrypted multiply (supported), followed by an
///      encrypted/plaintext divide (supported), once winningTotalBacking
///      has been verified-revealed. The multiply happens BEFORE the
///      divide brings the value back down, so if stake amounts and the
///      reward pool aren't kept to a sane range relative to euint64's
///      max, the intermediate product can overflow before division
///      rescues it. This is a real, disclosed numerical constraint, not
///      a solved one - keep amounts modest relative to token decimals
///      until this has been properly stress-tested.
///
///      SCALING: finalizeWinningTotal iterates over every bettor and
///      every one of their bets in a single, unbatched loop. Fine for
///      the scale of an initial test with a small group; a market with
///      many participants would need this broken into batched calls
///      before it could be trusted not to exceed gas or the protocol's
///      HCU (homomorphic compute unit) budget in one transaction.
contract OpportunityMarket {
    struct Opportunity {
        address lister;
        string metadataURI;
        uint256 listedAt;
    }

    struct Bet {
        euint32 target;
        euint64 amount;
    }

    bool internal _initialized;

    address public deployer;
    address public underlyingToken;

    bool public rewardPoolFunded;
    uint256 public rewardPool;

    bool public resolved;
    bool public cancelled;
    uint256 public winningOpportunityId;

    bool public winningTotalFinalized;
    uint256 public winningTotalBacking;
    bytes32 internal _winningTotalHandle;

    uint256 public opportunityCount;
    mapping(uint256 => Opportunity) public opportunities;

    mapping(address => euint64) internal _confidentialBalance;
    mapping(address => bool) internal _hasBalance;

    mapping(address => uint256) public betCount;
    mapping(address => mapping(uint256 => Bet)) internal _bets;

    address[] public allBettors;
    mapping(address => bool) internal _isTrackedBettor;

    mapping(address => bool) public stakeReclaimed;
    mapping(address => bool) public rewardComputed;
    mapping(address => euint64) internal _pendingReward;
    mapping(address => bool) internal _hasPendingReward;

    mapping(bytes32 => address) internal _pendingWithdrawalRecipient;
    mapping(bytes32 => bool) internal _pendingWithdrawalIsReward;
    mapping(bytes32 => bool) internal _pendingWithdrawalSettled;

    event Deposited(address indexed account, uint256 amount);
    event OpportunityListed(uint256 indexed id, address indexed lister, string metadataURI);
    event Backed(address indexed account, uint256 indexed betIndex);
    event Resolved(uint256 indexed winningOpportunityId);
    event StakeReclaimed(address indexed account);
    event RewardPoolFunded(uint256 amount);
    event MarketCancelled(uint256 refundedRewardPool);
    event WinningTotalRevealRequested(bytes32 indexed handle);
    event WinningTotalFinalized(uint256 winningTotalBacking);
    event RewardComputed(address indexed account);
    event WithdrawalRequested(address indexed account, bytes32 indexed handle, bool isReward);
    event WithdrawalCompleted(address indexed account, bytes32 indexed handle, uint256 amount);

    error AlreadyInitialized();
    error ZeroAddress();
    error OnlyDeployer();
    error EmptyMetadataURI();
    error OpportunityDoesNotExist();
    error AlreadyResolved();
    error NotResolved();
    error RewardPoolAlreadyFunded();
    error TransferFailed();
    error AlreadyReclaimed();
    error ZeroAmount();
    error NoBalance();
    error UnknownWithdrawalHandle();
    error WithdrawalAlreadySettled();
    error WinningTotalAlreadyFinalized();
    error WinningTotalNotFinalized();
    error RewardAlreadyComputed();
    error AlreadyCancelled();
    error CannotCancelAfterResolution();

    modifier onlyDeployer() {
        if (msg.sender != deployer) revert OnlyDeployer();
        _;
    }

    /// @notice Called exactly once, by the factory, immediately after
    ///         cloning - substitutes for a constructor, and is also
    ///         where coprocessor wiring happens (see the clone-safety
    ///         note above for why that can't live in an inherited
    ///         constructor here).
    function initialize(address underlyingToken_, address deployer_) external {
        if (_initialized) revert AlreadyInitialized();
        if (underlyingToken_ == address(0) || deployer_ == address(0)) revert ZeroAddress();
        _initialized = true;

        underlyingToken = underlyingToken_;
        deployer = deployer_;

        FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig());
    }

    /*//////////////////////////////////////////////////////////////
                            REWARD POOL
    //////////////////////////////////////////////////////////////*/

    function fundRewardPool(uint256 amount) external onlyDeployer {
        if (rewardPoolFunded) revert RewardPoolAlreadyFunded();
        if (amount == 0) revert ZeroAmount();
        rewardPoolFunded = true;
        rewardPool = amount;

        bool ok = IERC20Minimal(underlyingToken).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        emit RewardPoolFunded(amount);
    }

    /// @notice Calls off the market and returns the entire reward pool to
    ///         the deployer - for when the information gathered turns out
    ///         not to be useful enough to act on. Only available before
    ///         resolution: once resolved, backers committed real stakes
    ///         trusting a genuine reward was on the line, and pulling it
    ///         after the fact would be a rug pull, not a cancellation.
    ///         Backers can still reclaim their own stakes afterward - see
    ///         reclaimStake, which now also accepts a cancelled market.
    function cancelMarket() external onlyDeployer {
        if (resolved) revert CannotCancelAfterResolution();
        if (cancelled) revert AlreadyCancelled();
        cancelled = true;

        uint256 refund = rewardPool;
        rewardPool = 0;

        if (refund > 0) {
            bool ok = IERC20Minimal(underlyingToken).transfer(deployer, refund);
            if (!ok) revert TransferFailed();
        }

        emit MarketCancelled(refund);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the caller's own encrypted balance handle - a
    ///         frontend uses this to fetch the handle, then decrypts it
    ///         client-side via Zama's SDK using the permission already
    ///         granted through FHE.allow.
    function balanceOf(address account) external view returns (euint64) {
        return _confidentialBalance[account];
    }

    /// @notice Returns one bet's raw encrypted handles - the backer and
    ///         the deployer can each decrypt these client-side (see the
    ///         deployer-only visibility note in back()); nobody else can.
    ///         Combined with the already-public allBettors list and
    ///         betCount, this is what lets the deployer enumerate every
    ///         bet for their own statistics, without anyone else being
    ///         able to do the same.
    function getBet(address account, uint256 index) external view returns (euint32 target, euint64 amount) {
        Bet storage b = _bets[account][index];
        return (b.target, b.amount);
    }

    /// @notice Returns every bet, from every wallet, in a single call -
    ///         paired arrays: bettor[i] placed bet targets[i]/amounts[i].
    ///         Lets the deployer's tooling gather every handle in one
    ///         round trip, then submit them all together as one batched
    ///         decrypt request, instead of one getBet() call per bet.
    function getAllBets()
        external
        view
        returns (address[] memory bettor, euint32[] memory targets, euint64[] memory amounts)
    {
        uint256 total;
        uint256 m = allBettors.length;
        for (uint256 j = 0; j < m; j++) {
            total += betCount[allBettors[j]];
        }

        bettor = new address[](total);
        targets = new euint32[](total);
        amounts = new euint64[](total);

        uint256 cursor;
        for (uint256 j = 0; j < m; j++) {
            address account = allBettors[j];
            uint256 n = betCount[account];
            for (uint256 i = 0; i < n; i++) {
                bettor[cursor] = account;
                targets[cursor] = _bets[account][i].target;
                amounts[cursor] = _bets[account][i].amount;
                cursor++;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        OPPORTUNITY LISTING
    //////////////////////////////////////////////////////////////*/

    function listOpportunity(string calldata metadataURI) external returns (uint256 id) {
        if (bytes(metadataURI).length == 0) revert EmptyMetadataURI();
        id = ++opportunityCount;
        opportunities[id] = Opportunity({ lister: msg.sender, metadataURI: metadataURI, listedAt: block.timestamp });
        emit OpportunityListed(id, msg.sender, metadataURI);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        bool ok = IERC20Minimal(underlyingToken).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        euint64 encryptedAmount = FHE.asEuint64(uint64(amount));
        euint64 newBalance = _hasBalance[msg.sender]
            ? FHE.add(_confidentialBalance[msg.sender], encryptedAmount)
            : encryptedAmount;

        _confidentialBalance[msg.sender] = newBalance;
        _hasBalance[msg.sender] = true;

        FHE.allowThis(newBalance);
        FHE.allow(newBalance, msg.sender);

        emit Deposited(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        BACKING AN OPPORTUNITY
    //////////////////////////////////////////////////////////////*/

    function back(
        externalEuint32 targetHandle,
        bytes calldata targetProof,
        externalEuint64 amountHandle,
        bytes calldata amountProof
    ) external {
        if (!_hasBalance[msg.sender]) revert NoBalance();

        euint32 target = FHE.fromExternal(targetHandle, targetProof);
        euint64 requestedAmount = FHE.fromExternal(amountHandle, amountProof);

        euint64 balance = _confidentialBalance[msg.sender];
        ebool sufficient = FHE.le(requestedAmount, balance);
        euint64 actualAmount = FHE.select(sufficient, requestedAmount, FHE.asEuint64(0));

        euint64 newBalance = FHE.sub(balance, actualAmount);
        _confidentialBalance[msg.sender] = newBalance;

        uint256 idx = betCount[msg.sender]++;
        _bets[msg.sender][idx] = Bet({ target: target, amount: actualAmount });

        if (!_isTrackedBettor[msg.sender]) {
            _isTrackedBettor[msg.sender] = true;
            allBettors.push(msg.sender);
        }

        FHE.allowThis(newBalance);
        FHE.allow(newBalance, msg.sender);
        FHE.allowThis(target);
        FHE.allow(target, msg.sender);
        FHE.allowThis(actualAmount);
        FHE.allow(actualAmount, msg.sender);
        // Deployer-only visibility for statistics - granted alongside,
        // never instead of, the backer's own decrypt rights. The public,
        // and every other backer, still see nothing but ciphertext.
        FHE.allow(target, deployer);
        FHE.allow(actualAmount, deployer);

        emit Backed(msg.sender, idx);
    }

    /*//////////////////////////////////////////////////////////////
                            RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function resolve(uint256 winningOpportunityId_) external onlyDeployer {
        if (resolved) revert AlreadyResolved();
        if (winningOpportunityId_ == 0 || winningOpportunityId_ > opportunityCount) {
            revert OpportunityDoesNotExist();
        }

        resolved = true;
        winningOpportunityId = winningOpportunityId_;

        emit Resolved(winningOpportunityId_);
    }

    /*//////////////////////////////////////////////////////////////
                        STAKE RECLAMATION
    //////////////////////////////////////////////////////////////*/

    function reclaimStake() external {
        if (!resolved && !cancelled) revert NotResolved();
        if (stakeReclaimed[msg.sender]) revert AlreadyReclaimed();
        stakeReclaimed[msg.sender] = true;

        euint64 total = _hasBalance[msg.sender] ? _confidentialBalance[msg.sender] : FHE.asEuint64(0);
        uint256 n = betCount[msg.sender];
        for (uint256 i = 0; i < n; i++) {
            total = FHE.add(total, _bets[msg.sender][i].amount);
        }

        FHE.allowThis(total);
        FHE.allow(total, msg.sender);
        _confidentialBalance[msg.sender] = total;
        _hasBalance[msg.sender] = true;

        emit StakeReclaimed(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
            PAYOUT - AGGREGATE DENOMINATOR, THEN PRIVATE DIVISION
    //////////////////////////////////////////////////////////////*/

    function _qualifyingStake(address account) internal returns (euint64) {
        euint32 winningTarget = FHE.asEuint32(uint32(winningOpportunityId));
        euint64 qualifyingTotal = FHE.asEuint64(0);

        uint256 n = betCount[account];
        for (uint256 i = 0; i < n; i++) {
            Bet storage b = _bets[account][i];
            ebool matches = FHE.eq(b.target, winningTarget);
            euint64 contribution = FHE.select(matches, b.amount, FHE.asEuint64(0));
            qualifyingTotal = FHE.add(qualifyingTotal, contribution);
        }
        return qualifyingTotal;
    }

    function finalizeWinningTotal() external returns (bytes32 handle) {
        if (!resolved) revert NotResolved();
        if (winningTotalFinalized) revert WinningTotalAlreadyFinalized();

        euint64 grandTotal = FHE.asEuint64(0);
        uint256 m = allBettors.length;
        for (uint256 j = 0; j < m; j++) {
            grandTotal = FHE.add(grandTotal, _qualifyingStake(allBettors[j]));
        }

        FHE.makePubliclyDecryptable(grandTotal);
        handle = euint64.unwrap(grandTotal);
        _winningTotalHandle = handle;

        emit WinningTotalRevealRequested(handle);
    }

    function completeWinningTotalReveal(bytes calldata abiEncodedCleartext, bytes calldata decryptionProof) external {
        if (winningTotalFinalized) revert WinningTotalAlreadyFinalized();

        bytes32[] memory handles = new bytes32[](1);
        handles[0] = _winningTotalHandle;
        FHE.checkSignatures(handles, abiEncodedCleartext, decryptionProof);

        winningTotalFinalized = true;
        winningTotalBacking = abi.decode(abiEncodedCleartext, (uint64));

        emit WinningTotalFinalized(winningTotalBacking);
    }

    function computeReward() external {
        if (!winningTotalFinalized) revert WinningTotalNotFinalized();
        if (rewardComputed[msg.sender]) revert RewardAlreadyComputed();
        rewardComputed[msg.sender] = true;

        euint64 qualifying = _qualifyingStake(msg.sender);
        euint64 numerator = FHE.mul(qualifying, FHE.asEuint64(uint64(rewardPool)));
        euint64 reward = winningTotalBacking == 0 ? FHE.asEuint64(0) : FHE.div(numerator, uint64(winningTotalBacking));

        FHE.allowThis(reward);
        FHE.allow(reward, msg.sender);
        _pendingReward[msg.sender] = reward;
        _hasPendingReward[msg.sender] = true;

        emit RewardComputed(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAWAL - VERIFIED DECRYPTION FLOW
    //////////////////////////////////////////////////////////////*/

    function requestWithdrawal() external returns (bytes32 handle) {
        if (!_hasBalance[msg.sender]) revert NoBalance();

        euint64 amount = _confidentialBalance[msg.sender];
        FHE.makePubliclyDecryptable(amount);
        handle = euint64.unwrap(amount);

        _pendingWithdrawalRecipient[handle] = msg.sender;

        euint64 zero = FHE.asEuint64(0);
        FHE.allowThis(zero);
        FHE.allow(zero, msg.sender);
        _confidentialBalance[msg.sender] = zero;

        emit WithdrawalRequested(msg.sender, handle, false);
    }

    function requestRewardWithdrawal() external returns (bytes32 handle) {
        if (!_hasPendingReward[msg.sender]) revert NoBalance();

        euint64 amount = _pendingReward[msg.sender];
        FHE.makePubliclyDecryptable(amount);
        handle = euint64.unwrap(amount);

        _pendingWithdrawalRecipient[handle] = msg.sender;
        _pendingWithdrawalIsReward[handle] = true;

        euint64 zero = FHE.asEuint64(0);
        FHE.allowThis(zero);
        FHE.allow(zero, msg.sender);
        _pendingReward[msg.sender] = zero;

        emit WithdrawalRequested(msg.sender, handle, true);
    }

    function completeWithdrawal(
        bytes32 handle,
        bytes calldata abiEncodedCleartext,
        bytes calldata decryptionProof
    ) external {
        address recipient = _pendingWithdrawalRecipient[handle];
        if (recipient == address(0)) revert UnknownWithdrawalHandle();
        if (_pendingWithdrawalSettled[handle]) revert WithdrawalAlreadySettled();

        bytes32[] memory handles = new bytes32[](1);
        handles[0] = handle;
        FHE.checkSignatures(handles, abiEncodedCleartext, decryptionProof);

        _pendingWithdrawalSettled[handle] = true;

        uint64 amount = abi.decode(abiEncodedCleartext, (uint64));

        if (amount > 0) {
            bool ok = IERC20Minimal(underlyingToken).transfer(recipient, amount);
            if (!ok) revert TransferFailed();
        }

        emit WithdrawalCompleted(recipient, handle, amount);
    }
}
