// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// =============================================================
// Interfaces
// =============================================================

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ISupraOraclePull {
    struct PriceInfo {
        uint256[] pairs;
        uint256[] prices;
        uint256[] timestamp;
        uint256[] decimal;
        uint256[] round;
    }
    function verifyOracleProofV2(bytes calldata _bytesProof) external returns (PriceInfo memory);
}

interface IBrokexVault {
    function lpFreeCapital() external view returns (uint256);
    function lockCapital(uint256 amount) external;
    function unlockCapital(uint256 amount) external;
    function payTrader(address trader, uint256 amount) external;
    function collectLoss(uint256 amount) external;
    function collectCommission(uint256 amount) external;
}

// =============================================================
// BrokexCore
// =============================================================

contract BrokexCore {

    // =============================================================
    // Constants
    // =============================================================

    uint256 public constant PRECISION     = 1e6;
    uint256 public constant YEAR          = 365 days;
    uint256 public constant LIQ_THRESHOLD = 900_000; // 90%

    // States
    uint8 public constant STATE_ORDER            = 0;
    uint8 public constant STATE_OPEN             = 1;
    uint8 public constant STATE_CLOSED           = 2;
    uint8 public constant STATE_CANCELLED        = 3;
    uint8 public constant STATE_LIQUIDATED       = 4;
    uint8 public constant STATE_EMERGENCY_CLOSED = 5;

    // Directions
    uint8 public constant DIR_SHORT = 0;
    uint8 public constant DIR_LONG  = 1;

    // Order types
    uint8 public constant ORDER_MARKET = 0;
    uint8 public constant ORDER_LIMIT  = 1;
    uint8 public constant ORDER_STOP   = 2;

    // Reasons
    uint8 public constant REASON_NONE         = 0;
    uint8 public constant REASON_LIQUIDATION  = 1;
    uint8 public constant REASON_STOP_LOSS    = 2;
    uint8 public constant REASON_TAKE_PROFIT  = 3;
    uint8 public constant REASON_LIMIT_ORDER  = 4;
    uint8 public constant REASON_STOP_ORDER   = 5;
    uint8 public constant REASON_MARKET_CLOSE = 6;
    uint8 public constant REASON_CANCEL       = 7;
    uint8 public constant REASON_EMERGENCY    = 8;
    uint8 public constant REASON_MODIFY_STOPS = 9;

    // Config caps
    uint256 public constant MAX_LEVERAGE       = 10 * PRECISION;
    uint256 public constant MAX_COMMISSION_BPS = 10_000;
    uint256 public constant MAX_SPREAD_BPS     = 10_000;
    uint256 public constant MAX_FUNDING_ANNUAL = 10 * PRECISION;
    uint256 public constant MAX_EXECUTION_TOL  = 1_000;
    uint256 public constant MAX_PROOF_AGE      = 1 hours;

    // =============================================================
    // Ownership / Reentrancy
    // =============================================================

    address public owner;
    address public pendingOwner;
    bool    private locked;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    // =============================================================
    // External contracts
    // =============================================================

    IERC20           public immutable stable;
    ISupraOraclePull public immutable oracle;
    IBrokexVault     public immutable vault;

    // =============================================================
    // Structs
    // =============================================================

    struct AssetConfig {
        bool listed;
        bool tradingAllowed;
        bool frozen;

        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 minTradeSize;

        uint256 commissionOpen;
        uint256 baseSpread;
        uint256 baseFunding;
        uint256 maxFunding;

        uint256 maxOpenInterest;
        uint256 maxOpenInterestPerTrader;

        uint256 buffer;
        uint256 k;
        uint256 minRatio;
        uint256 maxRatio;

        uint256 alphaMin;
        uint256 alphaScale;
        uint256 profitCap;

        uint256 executionTolerance;
        uint256 maxProofAge;
    }

    struct AssetState {
        uint256 openInterestLong;
        uint256 openInterestShort;

        // Sum of max profits per side (used for needLock via alpha)
        uint256 riskLong;
        uint256 riskShort;

        // Weighted average open price for longs and shorts
        // avgOpenPriceLong  = sum(OI_i * openPrice_i) / openInterestLong
        // Stored as the numerator: sumPricedOILong = sum(OI_i * openPrice_i)
        // Actual avg = sumPricedOILong / openInterestLong
        uint256 sumPricedOILong;   // sum of (openInterest * openPrice) for all open longs
        uint256 sumPricedOIShort;  // sum of (openInterest * openPrice) for all open shorts

        uint256 fundingIndexLong;
        uint256 fundingIndexShort;
        uint256 lastFundingUpdate;
    }

    struct Trade {
        uint256 tradeId;
        address trader;
        uint256 assetId;

        uint8 state;
        uint8 direction;
        uint8 orderType;

        // STATE_ORDER : margin = full collateral (commission not yet deducted)
        // STATE_OPEN  : margin = collateral - commission
        uint256 margin;
        uint256 leverage;
        uint256 openInterest;

        uint256 targetPrice;
        uint256 openPrice;
        uint256 closePrice;

        uint256 openFundingIndex;
        uint256 closeFundingIndex;

        uint256 stopLossPrice;
        uint256 takeProfitPrice;
        uint256 liquidationPrice;

        // Max profit = openInterest * profitCap / PRECISION
        uint256 lpLockedCapital;

        uint256 openTimestamp;
        uint256 closeTimestamp;
    }

    // =============================================================
    // Storage
    // =============================================================

    mapping(uint256 => AssetConfig) public assetConfig;
    mapping(uint256 => AssetState)  public assetState;

    // All listed asset IDs — used to iterate for unrealized PnL
    uint256[] public listedAssetIds;

    // Number of currently active (listed and not delisted) assets
    uint256 public activeAssetCount;

    mapping(uint256 => Trade)                       public trades;
    mapping(address => uint256[])                   public traderTrades;
    mapping(address => mapping(uint256 => uint256)) public traderOpenInterest;

    uint256 public nextTradeId = 1;

    bool public paused;
    bool public emergencyMode;

    mapping(address => uint256) public lastOrderTime;
    mapping(address => uint256) public lastCancelTime;
    uint256 public minOrderDelay  = 3 seconds;
    uint256 public minCancelDelay = 3 seconds;

    // =============================================================
    // Events
    // =============================================================

    event OwnershipTransferStarted(address indexed oldOwner, address indexed pending);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event AssetListed(uint256 indexed assetId);
    event AssetDelisted(uint256 indexed assetId);
    event AssetConfigUpdated(uint256 indexed assetId);
    event TradingPaused();
    event TradingUnpaused();
    event EmergencyEnabled();
    event EmergencyDisabled();
    event FundingUpdated(uint256 indexed assetId, uint256 indexLong, uint256 indexShort);
    event TradeAction(uint256 indexed tradeId, address indexed trader, uint8 action);
    event InsolvencyWarning(uint256 indexed tradeId, uint256 owed, uint256 paid);

    // =============================================================
    // Errors
    // =============================================================

    error NotOwner();
    error NotPendingOwner();
    error Reentrancy();
    error ZeroAddress();
    error BadParameter();
    error InvalidAsset();
    error TradingNotAllowed();
    error AssetFrozen();
    error ProtocolPaused();
    error NotPausedError();
    error EmergencyOnly();
    error InvalidState();
    error NotTrader();
    error BadDirection();
    error BadOrderType();
    error BadLeverage();
    error BadMargin();
    error BadPrice();
    error BadSLTP();
    error DelayNotPassed();
    error MaxOIExceeded();
    error MaxTraderOIExceeded();
    error ImbalanceTooHigh();
    error InsufficientVaultCapital();
    error StalePrice();
    error FutureProof();
    error PairNotInProof();
    error ProofCountMismatch();
    error TransferFailed();

    // =============================================================
    // Constructor
    // =============================================================

    constructor(address stableToken, address supraOracle, address vaultAddress) {
        if (stableToken  == address(0)) revert ZeroAddress();
        if (supraOracle  == address(0)) revert ZeroAddress();
        if (vaultAddress == address(0)) revert ZeroAddress();

        owner  = msg.sender;
        stable = IERC20(stableToken);
        oracle = ISupraOraclePull(supraOracle);
        vault  = IBrokexVault(vaultAddress);

        emit OwnershipTransferred(address(0), msg.sender);
    }

    // =============================================================
    // Ownership
    // =============================================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address old  = owner;
        owner        = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, owner);
    }

    // =============================================================
    // Admin
    // =============================================================

    /// @notice List a new asset. Increments activeAssetCount.
    function listAsset(uint256 assetId, AssetConfig calldata cfg) external onlyOwner {
        if (assetId == 0) revert BadParameter();
        if (assetConfig[assetId].listed) revert BadParameter();
        _validateConfig(cfg);

        AssetConfig memory c = cfg;
        c.listed = true;
        assetConfig[assetId] = c;
        assetState[assetId].lastFundingUpdate = block.timestamp;

        listedAssetIds.push(assetId);
        activeAssetCount++;

        emit AssetListed(assetId);
    }

    /// @notice Delist an asset. Decrements activeAssetCount.
    /// @dev Does not remove from listedAssetIds array — sets listed = false instead.
    ///      unrealizedPnL will skip unlisted assets automatically.
    function delistAsset(uint256 assetId) external onlyOwner {
        _requireAsset(assetId);
        assetConfig[assetId].listed        = false;
        assetConfig[assetId].tradingAllowed = false;
        activeAssetCount--;
        emit AssetDelisted(assetId);
    }

    /// @notice Update config. Settles funding first so new rates are not retroactive.
    function updateAssetConfig(uint256 assetId, AssetConfig calldata cfg) external onlyOwner {
        _requireAsset(assetId);
        _updateFundingIndex(assetId);
        _validateConfig(cfg);

        AssetConfig memory c = cfg;
        c.listed = true;
        assetConfig[assetId] = c;

        emit AssetConfigUpdated(assetId);
    }

    function setTradingAllowed(uint256 assetId, bool allowed) external onlyOwner {
        _requireAsset(assetId);
        assetConfig[assetId].tradingAllowed = allowed;
        emit AssetConfigUpdated(assetId);
    }

    function setFrozen(uint256 assetId, bool frozen) external onlyOwner {
        _requireAsset(assetId);
        assetConfig[assetId].frozen = frozen;
        emit AssetConfigUpdated(assetId);
    }

    function pause() external onlyOwner {
        if (paused) revert ProtocolPaused();
        paused = true;
        emit TradingPaused();
    }

    function unpause() external onlyOwner {
        if (!paused) revert NotPausedError();
        paused = false;
        emit TradingUnpaused();
    }

    function enableEmergencyMode() external onlyOwner {
        paused        = true;
        emergencyMode = true;
        emit EmergencyEnabled();
    }

    function disableEmergencyMode() external onlyOwner {
        emergencyMode = false;
        emit EmergencyDisabled();
    }

    function setAntiSpamDelays(uint256 orderDelay, uint256 cancelDelay) external onlyOwner {
        if (orderDelay > 1 hours || cancelDelay > 1 hours) revert BadParameter();
        minOrderDelay  = orderDelay;
        minCancelDelay = cancelDelay;
    }

    // =============================================================
    // User — Open Market Position
    // =============================================================

    function openMarketPosition(
        uint256 assetId,
        uint8   direction,
        uint256 collateral,
        uint256 leverage,
        uint256 slPrice,
        uint256 tpPrice,
        bytes calldata oracleProof
    ) external nonReentrant returns (uint256 tradeId) {
        _requireCanTrade(assetId);
        if (direction != DIR_LONG && direction != DIR_SHORT) revert BadDirection();

        AssetConfig storage cfg = assetConfig[assetId];
        if (collateral == 0) revert BadMargin();
        if (leverage < cfg.minLeverage || leverage > cfg.maxLeverage) revert BadLeverage();

        uint256 commission = (collateral * cfg.commissionOpen) / PRECISION;
        uint256 margin     = collateral - commission;
        if (margin < cfg.minTradeSize) revert BadMargin();
        uint256 oi = (margin * leverage) / PRECISION;

        // 1. Settle funding on current OI
        _updateFundingIndex(assetId);

        // 2. Get price and apply spread on current OI (before update)
        uint256 oraclePrice = _getVerifiedPrice(assetId, oracleProof);
        uint256 entryPrice  = _applySpread(assetId, oraclePrice, direction, true);
        uint256 liqPrice    = _calculateLiquidationPrice(entryPrice, leverage, direction);

        if (slPrice != 0 || tpPrice != 0) {
            _validateSLTP(direction, entryPrice, liqPrice, slPrice, tpPrice);
        }

        // 3. Simulate new OI and validate all conditions
        uint256 maxProfit = (oi * cfg.profitCap) / PRECISION;
        _checkOpenConditions(assetId, direction, oi, maxProfit, msg.sender, cfg);

        // 4. Pull funds
        _transferFrom(msg.sender, address(this), collateral);
        if (commission > 0) {
            _approveVault(commission);
            vault.collectCommission(commission);
        }

        // 5. Update OI state and lock capital
        _applyOpenExposure(assetId, direction, oi, maxProfit, entryPrice, msg.sender, cfg);

        tradeId = _storeTrade(
            assetId, msg.sender, direction, ORDER_MARKET,
            margin, leverage, oi,
            0, entryPrice, slPrice, tpPrice, liqPrice, maxProfit
        );

        emit TradeAction(tradeId, msg.sender, REASON_NONE);
    }

    // =============================================================
    // User — Create Limit / Stop Order
    // =============================================================

    /// @notice Commission is NOT taken here — deducted at execution.
    function createLimitOrStopOrder(
        uint256 assetId,
        uint8   direction,
        uint8   orderType,
        uint256 targetPrice,
        uint256 collateral,
        uint256 leverage,
        uint256 slPrice,
        uint256 tpPrice
    ) external nonReentrant returns (uint256 tradeId) {
        _requireCanTrade(assetId);
        if (block.timestamp < lastOrderTime[msg.sender] + minOrderDelay) revert DelayNotPassed();
        if (direction != DIR_LONG && direction != DIR_SHORT) revert BadDirection();
        if (orderType != ORDER_LIMIT && orderType != ORDER_STOP) revert BadOrderType();
        if (targetPrice == 0) revert BadPrice();

        AssetConfig storage cfg = assetConfig[assetId];
        if (collateral == 0) revert BadMargin();
        if (leverage < cfg.minLeverage || leverage > cfg.maxLeverage) revert BadLeverage();

        uint256 commission = (collateral * cfg.commissionOpen) / PRECISION;
        uint256 marginNet  = collateral - commission;
        if (marginNet < cfg.minTradeSize) revert BadMargin();
        uint256 oi = (marginNet * leverage) / PRECISION;

        uint256 approxLiq = _calculateLiquidationPrice(targetPrice, leverage, direction);
        if (slPrice != 0 || tpPrice != 0) {
            _validateSLTP(direction, targetPrice, approxLiq, slPrice, tpPrice);
        }

        lastOrderTime[msg.sender] = block.timestamp;

        _transferFrom(msg.sender, address(this), collateral);

        uint256 maxProfit = (oi * cfg.profitCap) / PRECISION;

        // margin stored = full collateral (commission deducted at execution)
        tradeId = _storeTrade(
            assetId, msg.sender, direction, orderType,
            collateral, leverage, oi,
            targetPrice, 0, slPrice, tpPrice, 0, maxProfit
        );

        emit TradeAction(tradeId, msg.sender, orderType == ORDER_LIMIT ? REASON_LIMIT_ORDER : REASON_STOP_ORDER);
    }

    // =============================================================
    // User — Cancel Order
    // =============================================================

    function cancelOrder(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.trader != msg.sender)  revert NotTrader();
        if (t.state  != STATE_ORDER) revert InvalidState();
        if (block.timestamp < lastCancelTime[msg.sender] + minCancelDelay) revert DelayNotPassed();

        lastCancelTime[msg.sender] = block.timestamp;
        t.state          = STATE_CANCELLED;
        t.closeTimestamp = block.timestamp;

        _transfer(msg.sender, t.margin);
        emit TradeAction(tradeId, msg.sender, REASON_CANCEL);
    }

    // =============================================================
    // User — Modify SL / TP
    // =============================================================

    function modifyStops(uint256 tradeId, uint256 newSL, uint256 newTP) external {
        Trade storage t = trades[tradeId];
        if (t.trader != msg.sender) revert NotTrader();
        if (t.state != STATE_OPEN && t.state != STATE_ORDER) revert InvalidState();

        if (newSL != 0 || newTP != 0) {
            uint256 refPrice = t.state == STATE_OPEN ? t.openPrice : t.targetPrice;
            uint256 liqPrice = t.state == STATE_OPEN
                ? t.liquidationPrice
                : _calculateLiquidationPrice(t.targetPrice, t.leverage, t.direction);
            _validateSLTP(t.direction, refPrice, liqPrice, newSL, newTP);
        }

        t.stopLossPrice   = newSL;
        t.takeProfitPrice = newTP;

        emit TradeAction(tradeId, msg.sender, REASON_MODIFY_STOPS);
    }

    // =============================================================
    // User — Close Market
    // =============================================================

    function closePositionMarket(uint256 tradeId, bytes calldata oracleProof) external nonReentrant {
        if (paused) revert ProtocolPaused();

        Trade storage t = trades[tradeId];
        if (t.trader != msg.sender) revert NotTrader();
        if (t.state  != STATE_OPEN) revert InvalidState();

        _updateFundingIndex(t.assetId);
        uint256 oraclePrice = _getVerifiedPrice(t.assetId, oracleProof);
        _closeTrade(tradeId, oraclePrice, REASON_MARKET_CLOSE);
    }

    // =============================================================
    // User — Emergency Close
    // =============================================================

    function emergencyClose(uint256 tradeId) external nonReentrant {
        if (!paused && !emergencyMode) revert EmergencyOnly();

        Trade storage t = trades[tradeId];
        if (t.trader != msg.sender) revert NotTrader();
        if (t.state != STATE_ORDER && t.state != STATE_OPEN) revert InvalidState();

        uint256 refund = t.margin;

        if (t.state == STATE_OPEN) {
            _releaseExposure(tradeId);
        }

        t.state          = STATE_EMERGENCY_CLOSED;
        t.closeTimestamp = block.timestamp;

        _transfer(t.trader, refund);
        emit TradeAction(tradeId, t.trader, REASON_EMERGENCY);
    }

    // =============================================================
    // Keeper — Batch Execute
    // =============================================================

    function batchExecute(
        uint256   assetId,
        bytes calldata oracleProof,
        uint256[] calldata tradeIds,
        uint8[]   calldata reasons
    ) external nonReentrant returns (
        uint256[] memory executedIds,
        uint256[] memory skippedIds,
        uint8[]   memory skippedReasons
    ) {
        if (paused) revert ProtocolPaused();
        _requireCanTrade(assetId);
        if (tradeIds.length != reasons.length) revert BadParameter();

        _updateFundingIndex(assetId);
        uint256 oraclePrice = _getVerifiedPrice(assetId, oracleProof);

        uint256 len = tradeIds.length;
        uint256[] memory execTmp    = new uint256[](len);
        uint256[] memory skipTmp    = new uint256[](len);
        uint8[]   memory reasonsTmp = new uint8[](len);
        uint256 execCount;
        uint256 skipCount;

        for (uint256 i = 0; i < len; i++) {
            bool ok = _executeTriggered(assetId, tradeIds[i], oraclePrice, reasons[i]);
            if (ok) {
                execTmp[execCount++] = tradeIds[i];
            } else {
                skipTmp[skipCount]    = tradeIds[i];
                reasonsTmp[skipCount] = reasons[i];
                skipCount++;
            }
        }

        executedIds    = _trimUint(execTmp,     execCount);
        skippedIds     = _trimUint(skipTmp,     skipCount);
        skippedReasons = _trimUint8(reasonsTmp, skipCount);
    }

    // =============================================================
    // View — Unrealized PnL (for LP token pricing)
    // =============================================================

    /// @notice Computes the total unrealized PnL of all open positions across all listed assets.
    /// @dev The proof must contain prices for ALL currently active assets.
    ///      The number of valid pairs in the proof must equal activeAssetCount.
    ///      A positive return means traders are winning (vault owes them).
    ///      A negative return means traders are losing (vault is ahead).
    /// @param oracleProof A single Supra proof containing prices for all active assets.
    /// @return pnl Signed integer. Positive = traders winning, negative = traders losing.
    function unrealizedPnL(bytes calldata oracleProof)
        external
        returns (int256 pnl)
    {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(oracleProof);

        // Count how many prices in the proof match active listed assets
        uint256 matchedCount;
        uint256 len = listedAssetIds.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 assetId = listedAssetIds[i];
            if (!assetConfig[assetId].listed) continue;

            // Find this assetId in the proof
            bool found = false;
            for (uint256 j = 0; j < info.pairs.length; j++) {
                if (info.pairs[j] != assetId) continue;

                uint256 ts = info.timestamp[j];
                if (ts > block.timestamp) revert FutureProof();
                if (block.timestamp - ts > assetConfig[assetId].maxProofAge) revert StalePrice();

                uint256 price = _normalizePrice(info.prices[j], info.decimal[j]);
                pnl += _unrealizedPnLForAsset(assetId, price);

                found = true;
                matchedCount++;
                break;
            }

            // Every active asset must have a price in the proof
            if (!found) revert PairNotInProof();
        }

        // Proof must cover exactly all active assets — no more, no less
        if (matchedCount != activeAssetCount) revert ProofCountMismatch();
    }

    /// @notice Computes unrealized PnL for a single asset given a current price.
    /// @dev From the protocol's perspective:
    ///      - If longs are winning (price up), vault owes them → positive PnL for traders → negative for vault
    ///      - If shorts are winning (price down), vault owes them → positive PnL for traders → negative for vault
    ///      We return trader PnL (positive = vault loses).
    function _unrealizedPnLForAsset(uint256 assetId, uint256 currentPrice)
        internal view
        returns (int256 pnl)
    {
        AssetState storage st = assetState[assetId];
        AssetConfig storage cfg = assetConfig[assetId];

        // Long side
        // avgOpenPrice = sumPricedOILong / openInterestLong
        // PnL_long = openInterestLong * (currentPrice - avgOpenPrice) / avgOpenPrice
        //          = openInterestLong * currentPrice / avgOpenPrice - openInterestLong
        //          = (openInterestLong * currentPrice * openInterestLong / sumPricedOILong) - openInterestLong
        // Simplified: PnL_long = openInterestLong * (currentPrice - avgOpen) / avgOpen
        if (st.openInterestLong > 0 && st.sumPricedOILong > 0) {
            uint256 avgOpenLong = st.sumPricedOILong / st.openInterestLong;
            int256 longPnl;
            if (currentPrice >= avgOpenLong) {
                longPnl = int256((st.openInterestLong * (currentPrice - avgOpenLong)) / avgOpenLong);
            } else {
                longPnl = -int256((st.openInterestLong * (avgOpenLong - currentPrice)) / avgOpenLong);
            }
            // Cap at max possible profit for longs
            int256 maxLongProfit = int256(st.riskLong);
            if (longPnl > maxLongProfit) longPnl = maxLongProfit;
            pnl += longPnl;
        }

        // Short side
        // PnL_short = openInterestShort * (avgOpenPrice - currentPrice) / avgOpenPrice
        if (st.openInterestShort > 0 && st.sumPricedOIShort > 0) {
            uint256 avgOpenShort = st.sumPricedOIShort / st.openInterestShort;
            int256 shortPnl;
            if (currentPrice <= avgOpenShort) {
                shortPnl = int256((st.openInterestShort * (avgOpenShort - currentPrice)) / avgOpenShort);
            } else {
                shortPnl = -int256((st.openInterestShort * (currentPrice - avgOpenShort)) / avgOpenShort);
            }
            int256 maxShortProfit = int256(st.riskShort);
            if (shortPnl > maxShortProfit) shortPnl = maxShortProfit;
            pnl += shortPnl;
        }
    }

    // =============================================================
    // INTERNAL — Close Trade
    // =============================================================

    function _closeTrade(uint256 tradeId, uint256 oraclePrice, uint8 reason) internal {
        Trade storage t = trades[tradeId];
        if (t.state != STATE_OPEN) revert InvalidState();

        // Spread applied on OI before removal
        uint256 closePrice = _applySpread(t.assetId, oraclePrice, t.direction, false);
        uint256 fundingFee = _calculateFundingFee(t);
        int256  rawPnl     = _calculatePnl(t.openInterest, t.openPrice, closePrice, t.direction);

        if (rawPnl > int256(t.lpLockedCapital)) rawPnl = int256(t.lpLockedCapital);

        uint256 loss = rawPnl < 0 ? uint256(-rawPnl) : 0;
        if (loss + fundingFee >= (t.margin * LIQ_THRESHOLD) / PRECISION) {
            reason = REASON_LIQUIDATION;
        }

        uint256 marginAfterFunding = fundingFee >= t.margin ? 0 : t.margin - fundingFee;

        t.state             = reason == REASON_LIQUIDATION ? STATE_LIQUIDATED : STATE_CLOSED;
        t.closePrice        = closePrice;
        t.closeTimestamp    = block.timestamp;
        t.closeFundingIndex = t.direction == DIR_LONG
            ? assetState[t.assetId].fundingIndexLong
            : assetState[t.assetId].fundingIndexShort;

        _releaseExposure(tradeId);
        _settleTrade(t, rawPnl, marginAfterFunding, fundingFee, reason);

        emit TradeAction(tradeId, t.trader, reason);
    }

    // =============================================================
    // INTERNAL — Execute Pending Order
    // =============================================================

    function _executeOrder(uint256 tradeId, uint256 oraclePrice) internal returns (bool) {
        Trade storage t   = trades[tradeId];
        AssetState  storage st  = assetState[t.assetId];
        AssetConfig storage cfg = assetConfig[t.assetId];

        uint256 commission = (t.margin * cfg.commissionOpen) / PRECISION;
        uint256 margin     = t.margin - commission;
        uint256 oi         = (margin * t.leverage) / PRECISION;
        uint256 maxProfit  = (oi * cfg.profitCap) / PRECISION;

        // Spread applied on current OI (before this order updates it)
        uint256 entryPrice = _applySpread(t.assetId, oraclePrice, t.direction, true);
        uint256 liqPrice   = _calculateLiquidationPrice(entryPrice, t.leverage, t.direction);

        uint256 newLongOI  = st.openInterestLong  + (t.direction == DIR_LONG  ? oi : 0);
        uint256 newShortOI = st.openInterestShort + (t.direction == DIR_SHORT ? oi : 0);

        if (newLongOI + newShortOI > cfg.maxOpenInterest)                                return false;
        if (traderOpenInterest[t.trader][t.assetId] + oi > cfg.maxOpenInterestPerTrader) return false;
        if (!_isImbalanceAllowed(newLongOI, newShortOI, cfg))                            return false;

        uint256 newRiskL    = st.riskLong  + (t.direction == DIR_LONG  ? maxProfit : 0);
        uint256 newRiskS    = st.riskShort + (t.direction == DIR_SHORT ? maxProfit : 0);
        uint256 oldNeedLock = _calculateNeedLock(st.riskLong, st.riskShort, cfg);
        uint256 newNeedLock = _calculateNeedLock(newRiskL, newRiskS, cfg);

        if (newNeedLock > oldNeedLock) {
            if (newNeedLock - oldNeedLock > vault.lpFreeCapital()) return false;
        }

        if (commission > 0) {
            _approveVault(commission);
            vault.collectCommission(commission);
        }

        // Update OI, risk, and weighted average price
        _applyOpenExposure(t.assetId, t.direction, oi, maxProfit, entryPrice, t.trader, cfg);

        t.margin           = margin;
        t.openInterest     = oi;
        t.lpLockedCapital  = maxProfit;
        t.state            = STATE_OPEN;
        t.openPrice        = entryPrice;
        t.liquidationPrice = liqPrice;
        t.openTimestamp    = block.timestamp;
        t.openFundingIndex = t.direction == DIR_LONG
            ? st.fundingIndexLong
            : st.fundingIndexShort;

        return true;
    }

    // =============================================================
    // INTERNAL — Trigger Verification + Dispatch
    // =============================================================

    function _executeTriggered(
        uint256 assetId,
        uint256 tradeId,
        uint256 oraclePrice,
        uint8   reason
    ) internal returns (bool) {
        Trade storage t = trades[tradeId];
        if (t.assetId != assetId) return false;

        AssetConfig storage cfg = assetConfig[assetId];
        uint256 tol   = (oraclePrice * cfg.executionTolerance) / PRECISION;
        uint256 upper = oraclePrice + tol;
        uint256 lower = oraclePrice > tol ? oraclePrice - tol : 0;

        if (t.state == STATE_OPEN) {
            bool ok;
            if (reason == REASON_LIQUIDATION) {
                ok = t.direction == DIR_LONG ? lower <= t.liquidationPrice : upper >= t.liquidationPrice;
            } else if (reason == REASON_STOP_LOSS) {
                ok = t.stopLossPrice != 0 && (
                    t.direction == DIR_LONG ? lower <= t.stopLossPrice : upper >= t.stopLossPrice
                );
            } else if (reason == REASON_TAKE_PROFIT) {
                ok = t.takeProfitPrice != 0 && (
                    t.direction == DIR_LONG ? upper >= t.takeProfitPrice : lower <= t.takeProfitPrice
                );
            }
            if (!ok) return false;
            _closeTrade(tradeId, oraclePrice, reason);
            return true;
        }

        if (t.state == STATE_ORDER) {
            bool ok;
            if (reason == REASON_LIMIT_ORDER) {
                ok = t.orderType == ORDER_LIMIT && (
                    t.direction == DIR_LONG ? lower <= t.targetPrice : upper >= t.targetPrice
                );
            } else if (reason == REASON_STOP_ORDER) {
                ok = t.orderType == ORDER_STOP && (
                    t.direction == DIR_LONG ? upper >= t.targetPrice : lower <= t.targetPrice
                );
            }
            if (!ok) return false;
            return _executeOrder(tradeId, oraclePrice);
        }

        return false;
    }

    // =============================================================
    // INTERNAL — Release Exposure on Close
    // =============================================================

    function _releaseExposure(uint256 tradeId) internal {
        Trade storage t   = trades[tradeId];
        AssetState  storage st  = assetState[t.assetId];
        AssetConfig storage cfg = assetConfig[t.assetId];

        uint256 oldNeedLock = _calculateNeedLock(st.riskLong, st.riskShort, cfg);

        if (t.direction == DIR_LONG) {
            st.openInterestLong -= t.openInterest;
            st.riskLong         -= t.lpLockedCapital;
            // Remove this trade's contribution to the weighted average
            uint256 contribution = t.openInterest * t.openPrice;
            st.sumPricedOILong  = st.sumPricedOILong > contribution
                ? st.sumPricedOILong - contribution
                : 0;
        } else {
            st.openInterestShort -= t.openInterest;
            st.riskShort         -= t.lpLockedCapital;
            uint256 contribution  = t.openInterest * t.openPrice;
            st.sumPricedOIShort  = st.sumPricedOIShort > contribution
                ? st.sumPricedOIShort - contribution
                : 0;
        }
        traderOpenInterest[t.trader][t.assetId] -= t.openInterest;

        uint256 newNeedLock = _calculateNeedLock(st.riskLong, st.riskShort, cfg);
        if (oldNeedLock > newNeedLock) vault.unlockCapital(oldNeedLock - newNeedLock);
    }

    // =============================================================
    // INTERNAL — Settle Trade Funds
    // =============================================================

    function _settleTrade(
        Trade storage t,
        int256  pnl,
        uint256 marginAfterFunding,
        uint256 fundingFee,
        uint8   reason
    ) internal {
        if (fundingFee > 0 && fundingFee <= t.margin) {
            _approveVault(fundingFee);
            vault.collectCommission(fundingFee);
        }

        if (reason == REASON_LIQUIDATION) {
            if (marginAfterFunding > 0) {
                _approveVault(marginAfterFunding);
                vault.collectLoss(marginAfterFunding);
            }
            return;
        }

        if (marginAfterFunding == 0) return;

        if (pnl >= 0) {
            uint256 profit = uint256(pnl);
            _transfer(t.trader, marginAfterFunding);
            if (profit > 0) {
                uint256 available = vault.lpFreeCapital();
                if (available >= profit) {
                    vault.payTrader(t.trader, profit);
                } else {
                    if (available > 0) vault.payTrader(t.trader, available);
                    emit InsolvencyWarning(t.tradeId, profit, available);
                }
            }
            return;
        }

        uint256 loss = uint256(-pnl);
        if (loss >= marginAfterFunding) {
            _approveVault(marginAfterFunding);
            vault.collectLoss(marginAfterFunding);
        } else {
            _approveVault(loss);
            vault.collectLoss(loss);
            _transfer(t.trader, marginAfterFunding - loss);
        }
    }

    // =============================================================
    // INTERNAL — Open Condition Checks
    // =============================================================

    function _checkOpenConditions(
        uint256 assetId,
        uint8   direction,
        uint256 oi,
        uint256 maxProfit,
        address trader,
        AssetConfig storage cfg
    ) internal view {
        AssetState storage st = assetState[assetId];

        uint256 newLongOI  = st.openInterestLong  + (direction == DIR_LONG  ? oi : 0);
        uint256 newShortOI = st.openInterestShort + (direction == DIR_SHORT ? oi : 0);

        if (newLongOI + newShortOI > cfg.maxOpenInterest) revert MaxOIExceeded();
        if (traderOpenInterest[trader][assetId] + oi > cfg.maxOpenInterestPerTrader) revert MaxTraderOIExceeded();
        if (!_isImbalanceAllowed(newLongOI, newShortOI, cfg)) revert ImbalanceTooHigh();

        uint256 newRiskL    = st.riskLong  + (direction == DIR_LONG  ? maxProfit : 0);
        uint256 newRiskS    = st.riskShort + (direction == DIR_SHORT ? maxProfit : 0);
        uint256 oldNeedLock = _calculateNeedLock(st.riskLong, st.riskShort, cfg);
        uint256 newNeedLock = _calculateNeedLock(newRiskL, newRiskS, cfg);

        if (newNeedLock > oldNeedLock) {
            if (newNeedLock - oldNeedLock > vault.lpFreeCapital()) revert InsufficientVaultCapital();
        }
    }

    /// @notice Updates OI, risk, weighted average price, and locks capital.
    ///         Called AFTER all checks pass.
    function _applyOpenExposure(
        uint256 assetId,
        uint8   direction,
        uint256 oi,
        uint256 maxProfit,
        uint256 entryPrice,
        address trader,
        AssetConfig storage cfg
    ) internal {
        AssetState storage st = assetState[assetId];

        uint256 oldNeedLock = _calculateNeedLock(st.riskLong, st.riskShort, cfg);

        if (direction == DIR_LONG) {
            st.openInterestLong += oi;
            st.riskLong         += maxProfit;
            st.sumPricedOILong  += oi * entryPrice;
        } else {
            st.openInterestShort += oi;
            st.riskShort         += maxProfit;
            st.sumPricedOIShort  += oi * entryPrice;
        }
        traderOpenInterest[trader][assetId] += oi;

        uint256 newNeedLock = _calculateNeedLock(st.riskLong, st.riskShort, cfg);
        if (newNeedLock > oldNeedLock) vault.lockCapital(newNeedLock - oldNeedLock);
    }

    // =============================================================
    // HELPER — Funding Index
    // =============================================================

    function _updateFundingIndex(uint256 assetId) internal {
        AssetState  storage st  = assetState[assetId];
        AssetConfig storage cfg = assetConfig[assetId];

        uint256 last = st.lastFundingUpdate;
        if (last == 0 || block.timestamp == last) {
            st.lastFundingUpdate = block.timestamp;
            return;
        }

        uint256 dt = block.timestamp - last;
        (uint256 rLong, uint256 rShort) = _fundingRates(assetId);

        st.fundingIndexLong  += (rLong  * dt) / YEAR;
        st.fundingIndexShort += (rShort * dt) / YEAR;
        st.lastFundingUpdate  = block.timestamp;

        emit FundingUpdated(assetId, st.fundingIndexLong, st.fundingIndexShort);
    }

    function _fundingRates(uint256 assetId) internal view returns (uint256 rLong, uint256 rShort) {
        AssetState  storage st  = assetState[assetId];
        AssetConfig storage cfg = assetConfig[assetId];

        uint256 total = st.openInterestLong + st.openInterestShort;
        if (total == 0) {
            uint256 n = cfg.baseFunding / 2;
            return (n, n);
        }

        uint256 p        = _smoothstepSkew(st.openInterestLong, st.openInterestShort);
        uint256 dominant = (cfg.baseFunding * (500_000 + (9_500_000 * p / PRECISION))) / PRECISION;
        uint256 red      = (200_000 * p) / PRECISION;
        uint256 minority = (cfg.baseFunding * (500_000 > red ? 500_000 - red : 0)) / PRECISION;

        if (dominant > cfg.maxFunding) dominant = cfg.maxFunding;
        if (minority  > dominant)      minority  = dominant;

        if      (st.openInterestLong  > st.openInterestShort) return (dominant, minority);
        else if (st.openInterestShort > st.openInterestLong)  return (minority,  dominant);
        else { uint256 n = cfg.baseFunding / 2; return (n, n); }
    }

    // =============================================================
    // HELPER — Smoothstep Skew
    // =============================================================

    function _smoothstepSkew(uint256 longOI, uint256 shortOI) internal pure returns (uint256) {
        uint256 total = longOI + shortOI;
        if (total == 0) return 0;
        uint256 diff = longOI > shortOI ? longOI - shortOI : shortOI - longOI;
        uint256 r    = (diff * PRECISION) / total;
        uint256 r2   = (r * r) / PRECISION;
        return (r2 * (3 * PRECISION - 2 * r)) / PRECISION;
    }

    // =============================================================
    // HELPER — Spread
    // =============================================================

    function _applySpread(
        uint256 assetId,
        uint256 oraclePrice,
        uint8   direction,
        bool    isOpen
    ) internal view returns (uint256) {
        AssetState  storage st  = assetState[assetId];
        AssetConfig storage cfg = assetConfig[assetId];

        uint256 spread = cfg.baseSpread;
        uint256 total  = st.openInterestLong + st.openInterestShort;

        if (total > 0 && st.openInterestLong != st.openInterestShort) {
            uint256 p = _smoothstepSkew(st.openInterestLong, st.openInterestShort);
            bool isDominant =
                (direction == DIR_LONG  && st.openInterestLong  > st.openInterestShort) ||
                (direction == DIR_SHORT && st.openInterestShort > st.openInterestLong);

            if (isDominant) {
                spread = (cfg.baseSpread * (PRECISION + 3 * p)) / PRECISION;
            } else {
                uint256 red = (200_000 * p) / PRECISION;
                spread = (cfg.baseSpread * (PRECISION > red ? PRECISION - red : 0)) / PRECISION;
            }
        }

        uint256 amount = (oraclePrice * spread) / PRECISION;
        if (direction == DIR_LONG)  return isOpen ? oraclePrice + amount : oraclePrice - amount;
        else                        return isOpen ? oraclePrice - amount : oraclePrice + amount;
    }

    // =============================================================
    // HELPER — Liquidation Price
    // =============================================================

    function _calculateLiquidationPrice(
        uint256 openPrice,
        uint256 leverage,
        uint8   direction
    ) internal pure returns (uint256) {
        uint256 move = (openPrice * 900_000) / leverage;
        if (direction == DIR_LONG) return openPrice > move ? openPrice - move : 0;
        return openPrice + move;
    }

    // =============================================================
    // HELPER — SL / TP Validation
    // =============================================================

    function _validateSLTP(
        uint8   direction,
        uint256 entryPrice,
        uint256 liqPrice,
        uint256 slPrice,
        uint256 tpPrice
    ) internal pure {
        if (direction == DIR_LONG) {
            if (slPrice != 0) {
                if (slPrice >= entryPrice) revert BadSLTP();
                if (slPrice <  liqPrice)   revert BadSLTP();
            }
            if (tpPrice != 0 && tpPrice <= entryPrice) revert BadSLTP();
        } else {
            if (slPrice != 0) {
                if (slPrice <= entryPrice) revert BadSLTP();
                if (slPrice >  liqPrice)   revert BadSLTP();
            }
            if (tpPrice != 0 && tpPrice >= entryPrice) revert BadSLTP();
        }
    }

    // =============================================================
    // HELPER — PnL
    // =============================================================

    function _calculatePnl(
        uint256 openInterest,
        uint256 openPrice,
        uint256 closePrice,
        uint8   direction
    ) internal pure returns (int256) {
        if (direction == DIR_LONG) {
            if (closePrice >= openPrice)
                return  int256((openInterest * (closePrice - openPrice)) / openPrice);
            return -int256((openInterest * (openPrice  - closePrice)) / openPrice);
        } else {
            if (closePrice <= openPrice)
                return  int256((openInterest * (openPrice  - closePrice)) / openPrice);
            return -int256((openInterest * (closePrice - openPrice))  / openPrice);
        }
    }

    // =============================================================
    // HELPER — Funding Fee
    // =============================================================

    function _calculateFundingFee(Trade storage t) internal view returns (uint256) {
        AssetState storage st = assetState[t.assetId];
        uint256 currentIndex  = t.direction == DIR_LONG
            ? st.fundingIndexLong
            : st.fundingIndexShort;
        if (currentIndex <= t.openFundingIndex) return 0;
        uint256 fee = (t.openInterest * (currentIndex - t.openFundingIndex)) / PRECISION;
        return fee > t.margin ? t.margin : fee;
    }

    // =============================================================
    // HELPER — NeedLock
    // =============================================================

    function _calculateNeedLock(
        uint256 riskLong,
        uint256 riskShort,
        AssetConfig storage cfg
    ) internal view returns (uint256) {
        uint256 matched  = riskLong < riskShort ? riskLong  : riskShort;
        uint256 dominant = riskLong > riskShort ? riskLong  : riskShort;
        if (dominant == 0) return 0;

        uint256 balance   = (matched * PRECISION) / dominant;
        uint256 depth     = matched == 0 ? 0 : (matched * PRECISION) / (matched + cfg.alphaScale);
        uint256 reduction = ((PRECISION - cfg.alphaMin) * balance / PRECISION * depth) / PRECISION;
        uint256 alpha     = PRECISION > reduction ? PRECISION - reduction : cfg.alphaMin;
        if (alpha < cfg.alphaMin) alpha = cfg.alphaMin;

        return (dominant * alpha) / PRECISION;
    }

    // =============================================================
    // HELPER — Imbalance Check
    // =============================================================

    function _isImbalanceAllowed(
        uint256 longOI,
        uint256 shortOI,
        AssetConfig storage cfg
    ) internal view returns (bool) {
        uint256 total    = longOI + shortOI;
        uint256 dominant = longOI > shortOI ? longOI : shortOI;
        uint256 minority = longOI < shortOI ? longOI : shortOI;

        if (total <= cfg.buffer) return true;
        if (minority == 0)       return false;

        uint256 x  = total - cfg.buffer;
        uint256 k2 = cfg.k * cfg.k;
        uint256 R  = cfg.minRatio + ((cfg.maxRatio - cfg.minRatio) * k2) / (x * x + k2);

        return dominant <= (minority * R) / PRECISION;
    }

    // =============================================================
    // HELPER — Oracle
    // =============================================================

    function _getVerifiedPrice(uint256 assetId, bytes calldata proof) internal returns (uint256) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(proof);
        return _extractPrice(assetId, info);
    }

    function _extractPrice(
        uint256 assetId,
        ISupraOraclePull.PriceInfo memory info
    ) internal view returns (uint256) {
        for (uint256 i = 0; i < info.pairs.length; i++) {
            if (info.pairs[i] != assetId) continue;
            uint256 ts = info.timestamp[i];
            if (ts > block.timestamp) revert FutureProof();
            if (block.timestamp - ts > assetConfig[assetId].maxProofAge) revert StalePrice();
            return _normalizePrice(info.prices[i], info.decimal[i]);
        }
        revert PairNotInProof();
    }

    function _normalizePrice(uint256 price, uint256 decimals) internal pure returns (uint256) {
        if (decimals == 6) return price;
        if (decimals  > 6) return price / (10 ** (decimals - 6));
        return price * (10 ** (6 - decimals));
    }

    // =============================================================
    // INTERNAL — Store Trade
    // =============================================================

    function _storeTrade(
        uint256 assetId,
        address trader,
        uint8   direction,
        uint8   orderType,
        uint256 margin,
        uint256 leverage,
        uint256 oi,
        uint256 targetPrice,
        uint256 openPrice,
        uint256 slPrice,
        uint256 tpPrice,
        uint256 liqPrice,
        uint256 maxProfit
    ) internal returns (uint256 tradeId) {
        tradeId = nextTradeId++;

        Trade storage t    = trades[tradeId];
        t.tradeId          = tradeId;
        t.trader           = trader;
        t.assetId          = assetId;
        t.direction        = direction;
        t.orderType        = orderType;
        t.margin           = margin;
        t.leverage         = leverage;
        t.openInterest     = oi;
        t.targetPrice      = targetPrice;
        t.stopLossPrice    = slPrice;
        t.takeProfitPrice  = tpPrice;
        t.liquidationPrice = liqPrice;
        t.lpLockedCapital  = maxProfit;
        t.openTimestamp    = block.timestamp;

        if (orderType == ORDER_MARKET) {
            t.state            = STATE_OPEN;
            t.openPrice        = openPrice;
            t.openFundingIndex = direction == DIR_LONG
                ? assetState[assetId].fundingIndexLong
                : assetState[assetId].fundingIndexShort;
        } else {
            t.state = STATE_ORDER;
        }

        traderTrades[trader].push(tradeId);
    }

    // =============================================================
    // INTERNAL — Validation
    // =============================================================

    function _requireAsset(uint256 assetId) internal view {
        if (!assetConfig[assetId].listed) revert InvalidAsset();
    }

    function _requireCanTrade(uint256 assetId) internal view {
        if (paused) revert ProtocolPaused();
        _requireAsset(assetId);
        AssetConfig storage cfg = assetConfig[assetId];
        if (!cfg.tradingAllowed) revert TradingNotAllowed();
        if (cfg.frozen)          revert AssetFrozen();
    }

    function _validateConfig(AssetConfig memory cfg) internal pure {
        if (cfg.minLeverage == 0 || cfg.maxLeverage < cfg.minLeverage) revert BadParameter();
        if (cfg.maxLeverage        > MAX_LEVERAGE)        revert BadParameter();
        if (cfg.commissionOpen     > MAX_COMMISSION_BPS)  revert BadParameter();
        if (cfg.baseSpread         > MAX_SPREAD_BPS)      revert BadParameter();
        if (cfg.maxFunding         > MAX_FUNDING_ANNUAL)  revert BadParameter();
        if (cfg.executionTolerance > MAX_EXECUTION_TOL)   revert BadParameter();
        if (cfg.maxProofAge == 0 || cfg.maxProofAge > MAX_PROOF_AGE) revert BadParameter();
        if (cfg.minRatio < PRECISION || cfg.maxRatio < cfg.minRatio) revert BadParameter();
        if (cfg.alphaMin    > PRECISION)  revert BadParameter();
        if (cfg.profitCap  == 0 || cfg.profitCap > PRECISION) revert BadParameter();
        if (cfg.k          == 0)          revert BadParameter();
        if (cfg.alphaScale == 0)          revert BadParameter();
    }

    // =============================================================
    // Views
    // =============================================================

    function getAsset(uint256 assetId)
        external view
        returns (AssetConfig memory cfg, AssetState memory st)
    {
        _requireAsset(assetId);
        return (assetConfig[assetId], assetState[assetId]);
    }

    /// @notice Returns the current weighted average open price for longs and shorts.
    function getAvgOpenPrices(uint256 assetId)
        external view
        returns (uint256 avgLong, uint256 avgShort)
    {
        AssetState storage st = assetState[assetId];
        avgLong  = st.openInterestLong  > 0 ? st.sumPricedOILong  / st.openInterestLong  : 0;
        avgShort = st.openInterestShort > 0 ? st.sumPricedOIShort / st.openInterestShort : 0;
    }

    function getTrade(uint256 tradeId) external view returns (Trade memory) {
        return trades[tradeId];
    }

    function getTraderTrades(address trader) external view returns (uint256[] memory) {
        return traderTrades[trader];
    }

    function getListedAssets() external view returns (uint256[] memory) {
        return listedAssetIds;
    }

    function previewRates(uint256 assetId)
        external view
        returns (
            uint256 spreadLong,
            uint256 spreadShort,
            uint256 fundingLong,
            uint256 fundingShort,
            uint256 needLock
        )
    {
        _requireAsset(assetId);
        AssetState  storage st  = assetState[assetId];
        AssetConfig storage cfg = assetConfig[assetId];

        spreadLong  = _spreadView(assetId, DIR_LONG);
        spreadShort = _spreadView(assetId, DIR_SHORT);
        (fundingLong, fundingShort) = _fundingRates(assetId);
        needLock = _calculateNeedLock(st.riskLong, st.riskShort, cfg);
    }

    function _spreadView(uint256 assetId, uint8 direction) internal view returns (uint256) {
        AssetState  storage st  = assetState[assetId];
        AssetConfig storage cfg = assetConfig[assetId];
        uint256 total = st.openInterestLong + st.openInterestShort;
        if (total == 0 || st.openInterestLong == st.openInterestShort) return cfg.baseSpread;

        uint256 p = _smoothstepSkew(st.openInterestLong, st.openInterestShort);
        bool isDominant =
            (direction == DIR_LONG  && st.openInterestLong  > st.openInterestShort) ||
            (direction == DIR_SHORT && st.openInterestShort > st.openInterestLong);

        if (isDominant) return (cfg.baseSpread * (PRECISION + 3 * p)) / PRECISION;
        uint256 red = (200_000 * p) / PRECISION;
        return (cfg.baseSpread * (PRECISION > red ? PRECISION - red : 0)) / PRECISION;
    }

    // =============================================================
    // INTERNAL — Safe Transfers
    // =============================================================

    function _transfer(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!stable.transfer(to, amount)) revert TransferFailed();
    }

    function _transferFrom(address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!stable.transferFrom(from, to, amount)) revert TransferFailed();
    }

    function _approveVault(uint256 amount) internal {
        if (!stable.approve(address(vault), amount)) revert TransferFailed();
    }

    // =============================================================
    // INTERNAL — Array Helpers
    // =============================================================

    function _trimUint(uint256[] memory arr, uint256 len) internal pure returns (uint256[] memory out) {
        out = new uint256[](len);
        for (uint256 i = 0; i < len; i++) out[i] = arr[i];
    }

    function _trimUint8(uint8[] memory arr, uint256 len) internal pure returns (uint8[] memory out) {
        out = new uint8[](len);
        for (uint256 i = 0; i < len; i++) out[i] = arr[i];
    }
}
