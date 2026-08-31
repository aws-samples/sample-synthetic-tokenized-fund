// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/ICREPriceFeed.sol";
import "./interfaces/ICRECollateralMonitor.sol";
import "./SyntheticToken.sol";

/// @title SyntheticMinter
/// @notice Collateralized-debt-position (CDP) issuer for synthetic stock tokens (sSPY).
/// @dev Economic model: a user deposits USDC collateral and mints sSPY as a *liability*.
///      The minter is therefore the issuer / short of the synthetic asset — long-SPY
///      exposure belongs to whoever *holds* the sSPY token, not to the minter. Burning
///      sSPY repays the minter's debt and unlocks their collateral; it is NOT an
///      oracle-priced long-SPY payout. Because this is a closed, self-collateralized
///      system with no counterparty or sponsor funding, positions are marked to the live
///      oracle price and can be liquidated when they fall below `liquidationThreshold`.
///      Integrates with CRE oracle feeds for real-time stock prices and protocol health.
contract SyntheticMinter is Ownable, Pausable, ReentrancyGuard {
    // ============ Constants ============

    /// @notice Decimals used by CRE price feed (8 decimals, e.g., 18500000000 = $185.00)
    uint256 public constant PRICE_DECIMALS = 8;

    /// @notice Decimals used by USDC token
    uint256 public constant USDC_DECIMALS = 6;

    /// @notice Decimals used by synthetic token
    uint256 public constant SYNTHETIC_DECIMALS = 18;

    /// @notice Basis points denominator (10000 = 100%)
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Upper bound on the liquidation bonus (3000 bps = 30%)
    uint256 public constant MAX_LIQUIDATION_BONUS_BPS = 3000;

    // ============ Feed Interfaces ============

    /// @notice CRE price feed for stock prices
    ICREPriceFeed public priceFeed;

    /// @notice CRE collateral monitor for protocol health
    ICRECollateralMonitor public collateralMonitor;

    // ============ Tokens ============

    /// @notice USDC token used as collateral
    IERC20 public immutable usdc;

    /// @notice Synthetic token that users mint/burn
    SyntheticToken public immutable syntheticToken;

    // ============ Risk Parameters ============

    /// @notice Minimum collateralization ratio required to open/increase a position (e.g., 150 = 150%)
    uint256 public minCollateralizationRatio;

    /// @notice Collateralization ratio (percent) at/below which a position may be liquidated.
    /// @dev Must be < minCollateralizationRatio so positions have a buffer before liquidation.
    uint256 public liquidationThreshold;

    /// @notice Bonus paid to a liquidator, in basis points, on top of the repaid debt value
    ///         (e.g., 1000 = 10%). Bounded by MAX_LIQUIDATION_BONUS_BPS.
    uint256 public liquidationBonusBps;

    /// @notice Mint fee in basis points (e.g., 30 = 0.3%)
    uint256 public mintFeeBps;

    /// @notice Maximum age in seconds for feed data to be considered valid
    uint256 public stalenessWindow;

    // ============ User Position Mappings ============

    /// @notice Total USDC deposited by each user
    mapping(address => uint256) public totalCollateral;

    /// @notice USDC currently backing minted tokens for each user
    mapping(address => uint256) public lockedCollateral;

    /// @notice Total USDC currently locked backing minted tokens across all users
    uint256 public totalLockedCollateral;

    /// @notice sSPY liability each user has minted and must repay (burn) to reclaim collateral.
    /// @dev Tracked independently of the ERC20 balance so that transferring sSPY away cannot
    ///      distort collateral release — the debt, not the token balance, backs the collateral.
    mapping(address => uint256) public syntheticDebt;

    /// @notice Total sSPY liability minted across all users
    uint256 public totalSyntheticDebt;

    // ============ Fee State ============

    /// @notice Address that receives collected fees
    address public feeRecipient;

    /// @notice Total mint fees accumulated and not yet collected, denominated in USDC (6 decimals)
    uint256 public accumulatedFees;

    // ============ Events ============

    /// @notice Emitted when collateral is deposited
    event CollateralDeposited(address indexed user, uint256 amount, uint256 priceAtDeposit);

    /// @notice Emitted when collateral is withdrawn
    event CollateralWithdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when synthetic tokens are minted
    event SyntheticMinted(address indexed user, uint256 amount, uint256 priceUsed, uint256 collateralRatio);

    /// @notice Emitted when synthetic tokens are burned
    event SyntheticBurned(address indexed user, uint256 amount, uint256 priceUsed, uint256 collateralReleased);

    /// @notice Emitted when an unhealthy position is liquidated
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 priceUsed
    );

    /// @notice Emitted when a liquidation cannot fully cover the repaid debt with collateral
    /// @param user The owner of the underwater position
    /// @param shortfall The USDC-denominated value of debt not covered by seized collateral
    event BadDebtRealized(address indexed user, uint256 shortfall);

    /// @notice Emitted when a feed address is updated
    event FeedUpdated(string indexed feedType, address oldAddress, address newAddress);

    /// @notice Emitted when risk parameters are updated
    event RiskParamsUpdated(string indexed param, uint256 oldValue, uint256 newValue);

    /// @notice Emitted when fees are collected
    event FeesCollected(address indexed recipient, uint256 amount);

    // ============ Constructor ============

    /// @notice Creates a new SyntheticMinter
    /// @param _usdc Address of the USDC token contract
    /// @param _syntheticToken Address of the SyntheticToken contract
    /// @param _initialOwner Address that will own the contract
    /// @param _feeRecipient Address that will receive collected fees
    constructor(
        address _usdc,
        address _syntheticToken,
        address _initialOwner,
        address _feeRecipient
    ) Ownable(_initialOwner) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_syntheticToken != address(0), "Invalid synthetic token address");
        require(_feeRecipient != address(0), "Invalid fee recipient");

        usdc = IERC20(_usdc);
        syntheticToken = SyntheticToken(_syntheticToken);
        feeRecipient = _feeRecipient;

        // Set default risk parameters
        minCollateralizationRatio = 150; // 150% required to open/increase a position
        liquidationThreshold = 120;      // 120% — positions below this can be liquidated
        liquidationBonusBps = 1000;      // 10% liquidator bonus
        mintFeeBps = 30;                 // 0.3%
        stalenessWindow = 3600;          // 1 hour
    }

    // ============ Admin Setters ============

    /// @notice Sets the price feed address
    /// @dev Only callable by owner
    /// @param _priceFeed Address of the new price feed contract
    function setPriceFeed(address _priceFeed) external onlyOwner {
        require(_priceFeed != address(0), "Invalid feed address");
        address oldAddress = address(priceFeed);
        priceFeed = ICREPriceFeed(_priceFeed);
        emit FeedUpdated("priceFeed", oldAddress, _priceFeed);
    }

    /// @notice Sets the collateral monitor address
    /// @dev Only callable by owner
    /// @param _collateralMonitor Address of the new collateral monitor contract
    function setCollateralMonitor(address _collateralMonitor) external onlyOwner {
        require(_collateralMonitor != address(0), "Invalid feed address");
        address oldAddress = address(collateralMonitor);
        collateralMonitor = ICRECollateralMonitor(_collateralMonitor);
        emit FeedUpdated("collateralMonitor", oldAddress, _collateralMonitor);
    }

    /// @notice Sets the minimum collateralization ratio required to open/increase a position
    /// @dev Only callable by owner. Must remain >= liquidationThreshold so a freshly minted
    ///      position is never immediately liquidatable.
    /// @param _minCollateralizationRatio New minimum ratio as percentage
    function setMinCollateralizationRatio(uint256 _minCollateralizationRatio) external onlyOwner {
        require(_minCollateralizationRatio >= liquidationThreshold, "Below liquidation threshold");
        uint256 oldValue = minCollateralizationRatio;
        minCollateralizationRatio = _minCollateralizationRatio;
        emit RiskParamsUpdated("minCollateralizationRatio", oldValue, _minCollateralizationRatio);
    }

    /// @notice Sets the liquidation threshold (percent)
    /// @dev Only callable by owner. Must be in [100, minCollateralizationRatio]: a position is
    ///      only unsafe once its collateral falls toward the value of its debt, and it must never
    ///      exceed the mint ratio (otherwise new positions would open already liquidatable).
    /// @param _liquidationThreshold New liquidation threshold as percentage
    function setLiquidationThreshold(uint256 _liquidationThreshold) external onlyOwner {
        require(_liquidationThreshold >= 100, "Threshold below 100%");
        require(_liquidationThreshold <= minCollateralizationRatio, "Above min collateralization");
        uint256 oldValue = liquidationThreshold;
        liquidationThreshold = _liquidationThreshold;
        emit RiskParamsUpdated("liquidationThreshold", oldValue, _liquidationThreshold);
    }

    /// @notice Sets the liquidation bonus in basis points
    /// @dev Only callable by owner, bounded by MAX_LIQUIDATION_BONUS_BPS (30%)
    /// @param _liquidationBonusBps New liquidation bonus in basis points
    function setLiquidationBonusBps(uint256 _liquidationBonusBps) external onlyOwner {
        require(_liquidationBonusBps <= MAX_LIQUIDATION_BONUS_BPS, "Bonus exceeds maximum");
        uint256 oldValue = liquidationBonusBps;
        liquidationBonusBps = _liquidationBonusBps;
        emit RiskParamsUpdated("liquidationBonusBps", oldValue, _liquidationBonusBps);
    }

    /// @notice Sets the mint fee in basis points
    /// @dev Only callable by owner, max 1000 bps (10%)
    /// @param _mintFeeBps New mint fee in basis points
    function setMintFeeBps(uint256 _mintFeeBps) external onlyOwner {
        require(_mintFeeBps <= 1000, "Fee exceeds maximum");
        uint256 oldValue = mintFeeBps;
        mintFeeBps = _mintFeeBps;
        emit RiskParamsUpdated("mintFeeBps", oldValue, _mintFeeBps);
    }

    /// @notice Sets the staleness window for feed data
    /// @dev Only callable by owner
    /// @param _stalenessWindow New staleness window in seconds
    function setStalenessWindow(uint256 _stalenessWindow) external onlyOwner {
        uint256 oldValue = stalenessWindow;
        stalenessWindow = _stalenessWindow;
        emit RiskParamsUpdated("stalenessWindow", oldValue, _stalenessWindow);
    }

    /// @notice Sets the fee recipient address
    /// @dev Only callable by owner
    /// @param _feeRecipient New fee recipient address
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }

    // ============ Pause Functions ============

    /// @notice Pauses the contract
    /// @dev Only callable by owner
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    /// @dev Only callable by owner
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Internal Validation Functions ============

    /// @notice Validates the price feed and returns the current price
    /// @dev Checks feed is set, price is positive, and data is not stale
    /// @return price The validated price from the feed
    function _validatePriceFeed() internal view returns (uint256 price) {
        require(address(priceFeed) != address(0), "Feed not set");
        
        uint256 timestamp;
        (price, timestamp) = priceFeed.getLatestPrice();
        
        require(price > 0, "Invalid price");
        require(block.timestamp - timestamp <= stalenessWindow, "Price feed stale");
        
        return price;
    }

    /// @notice Validates the collateral monitor and returns the current data
    /// @dev Checks feed is set, data is not stale, and protocol is healthy
    /// @return data The validated CollateralData from the monitor
    function _validateCollateralMonitor() internal view returns (ICRECollateralMonitor.CollateralData memory data) {
        require(address(collateralMonitor) != address(0), "Feed not set");
        
        data = collateralMonitor.getLatestData();
        
        require(block.timestamp - data.timestamp <= stalenessWindow, "Collateral feed stale");
        require(data.isHealthy == true, "Protocol unhealthy");

        return data;
    }

    /// @notice Converts an sSPY debt amount (18 decimals) into its USDC value (6 decimals) at `price`
    /// @dev value = debt * price / (10^PRICE_DECIMALS * 10^(SYNTHETIC_DECIMALS - USDC_DECIMALS))
    /// @param debt sSPY amount (18 decimals)
    /// @param price Oracle price (8 decimals)
    /// @return USDC-denominated value (6 decimals)
    function _debtValueUSDC(uint256 debt, uint256 price) internal pure returns (uint256) {
        return (debt * price) / (10**PRICE_DECIMALS * 10**(SYNTHETIC_DECIMALS - USDC_DECIMALS));
    }

    /// @notice Computes the current oracle-priced collateralization ratio (percent) of a position
    /// @dev CR = lockedCollateral * 100 / debtValue. Returns max uint when there is no debt.
    /// @param locked USDC collateral backing the position (6 decimals)
    /// @param debt sSPY liability (18 decimals)
    /// @param price Oracle price (8 decimals)
    /// @return ratio Collateralization ratio as a percentage (e.g., 150 = 150%)
    function _collateralRatio(uint256 locked, uint256 debt, uint256 price) internal pure returns (uint256 ratio) {
        if (debt == 0 || price == 0) {
            return type(uint256).max;
        }
        ratio = (locked * 100 * 10**PRICE_DECIMALS * 10**(SYNTHETIC_DECIMALS - USDC_DECIMALS)) / (debt * price);
    }

    // ============ Collateral Management Functions ============

    /// @notice Deposits USDC as collateral
    /// @dev Requires prior approval of USDC transfer
    /// @param amount Amount of USDC to deposit (6 decimals)
    function depositCollateral(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be greater than zero");
        
        // Transfer USDC from user to contract
        bool success = usdc.transferFrom(msg.sender, address(this), amount);
        require(success, "USDC transfer failed");
        
        // Update user's total collateral
        totalCollateral[msg.sender] += amount;
        
        // Get current price for event (handle if feed not set yet)
        uint256 priceAtDeposit = 0;
        if (address(priceFeed) != address(0)) {
            try priceFeed.getLatestPrice() returns (uint256 price, uint256) {
                priceAtDeposit = price;
            } catch {
                // Price feed call failed, use 0
            }
        }
        
        emit CollateralDeposited(msg.sender, amount, priceAtDeposit);
    }

    /// @notice Withdraws unused USDC collateral
    /// @dev Allowed even when paused to enable user exits
    /// @param amount Amount of USDC to withdraw (6 decimals)
    function withdrawCollateral(uint256 amount) external nonReentrant {
        // Calculate available collateral (not backing any minted tokens)
        uint256 available = totalCollateral[msg.sender] - lockedCollateral[msg.sender];
        require(amount <= available, "Insufficient available collateral");
        
        // Update user's total collateral
        totalCollateral[msg.sender] -= amount;
        
        // Transfer USDC back to user
        bool success = usdc.transfer(msg.sender, amount);
        require(success, "USDC transfer failed");
        
        emit CollateralWithdrawn(msg.sender, amount);
    }

    // ============ Mint Function ============

    /// @notice Mints synthetic tokens by locking USDC collateral
    /// @dev Requires sufficient available collateral and valid CRE feeds. The mint fee is charged
    ///      in USDC out of the caller's available collateral, so the caller receives the full
    ///      `syntheticAmount` of sSPY and no unbacked synthetic tokens are ever created.
    /// @param syntheticAmount Amount of synthetic tokens to mint (18 decimals)
    function mint(uint256 syntheticAmount) external nonReentrant whenNotPaused {
        require(syntheticAmount > 0, "Amount must be greater than zero");

        // Validate feeds and get current price
        uint256 price = _validatePriceFeed();
        _validateCollateralMonitor();

        // Calculate required collateral in USDC (6 decimals)
        // Formula: (syntheticAmount * price * minCollateralizationRatio) / (100 * 10^PRICE_DECIMALS)
        // Adjust for decimal difference: synthetic (18) vs USDC (6) = divide by 10^12
        uint256 requiredCollateral = (syntheticAmount * price * minCollateralizationRatio)
            / (100 * 10**PRICE_DECIMALS * 10**(SYNTHETIC_DECIMALS - USDC_DECIMALS));

        // A position must always lock a non-zero amount of collateral. Because `requiredCollateral`
        // rounds down, a sufficiently small `syntheticAmount` would otherwise mint sSPY (and record
        // debt) while locking zero USDC — i.e. unbacked debt. Reject such dust mints outright.
        require(requiredCollateral > 0, "Mint amount too small");

        // Mint fee, charged in USDC on the minted notional value (same decimal adjustment).
        uint256 fee = (syntheticAmount * price * mintFeeBps)
            / (BPS_DENOMINATOR * 10**PRICE_DECIMALS * 10**(SYNTHETIC_DECIMALS - USDC_DECIMALS));

        // Check available collateral covers both the locked collateral and the USDC fee.
        uint256 available = totalCollateral[msg.sender] - lockedCollateral[msg.sender];
        require(available >= requiredCollateral + fee, "Insufficient collateral");

        // Update state. Debt is the full minted amount (the user receives all of it); the fee is
        // taken from the user's collateral and held as protocol fees denominated in USDC.
        lockedCollateral[msg.sender] += requiredCollateral;
        totalLockedCollateral += requiredCollateral;
        syntheticDebt[msg.sender] += syntheticAmount;
        totalSyntheticDebt += syntheticAmount;
        totalCollateral[msg.sender] -= fee;
        accumulatedFees += fee;

        // Mint synthetic tokens to user (full amount — no sSPY withheld)
        syntheticToken.mint(msg.sender, syntheticAmount);

        // Calculate resulting collateral ratio for event, against the tracked debt
        uint256 collateralRatio = _collateralRatio(lockedCollateral[msg.sender], syntheticDebt[msg.sender], price);

        emit SyntheticMinted(msg.sender, syntheticAmount, price, collateralRatio);
    }

    // ============ Burn Function ============

    /// @notice Burns sSPY to repay the caller's own debt and unlock the backing collateral.
    /// @dev This is CDP debt repayment, NOT an oracle-priced long-SPY payout: the caller can
    ///      only reclaim the USDC they locked. Collateral is released in proportion to the
    ///      *tracked debt* repaid (`lockedCollateral * amount / debt`), which holds the
    ///      position's collateralization ratio constant at any price and stays solvent even if
    ///      the caller transferred their sSPY away and reacquired it. The price is read
    ///      best-effort purely for the emitted event and does NOT change the USDC released:
    ///      repaying debt and reclaiming collateral must never be blocked by a stale or unset
    ///      oracle, or a user's funds could be trapped indefinitely.
    /// @param syntheticAmount Amount of synthetic tokens to burn/repay (18 decimals)
    function burn(uint256 syntheticAmount) external nonReentrant whenNotPaused {
        require(syntheticAmount > 0, "Amount must be greater than zero");

        // Read the current price best-effort for the event only — staleness is intentionally NOT
        // enforced here because burning is price-independent debt repayment (see @dev above).
        uint256 price = 0;
        if (address(priceFeed) != address(0)) {
            try priceFeed.getLatestPrice() returns (uint256 p, uint256) {
                price = p;
            } catch {
                // Feed call reverted; leave price at 0 for the event.
            }
        }

        // Caller must hold the tokens they are burning...
        uint256 userBalance = syntheticToken.balanceOf(msg.sender);
        require(syntheticAmount <= userBalance, "Insufficient balance");

        // ...and cannot repay more than their own outstanding debt.
        uint256 debt = syntheticDebt[msg.sender];
        require(syntheticAmount <= debt, "Exceeds debt");

        // Release collateral proportionally to the debt repaid (keeps CR invariant).
        uint256 collateralToRelease = (lockedCollateral[msg.sender] * syntheticAmount) / debt;

        // Update state (checks-effects-interactions)
        lockedCollateral[msg.sender] -= collateralToRelease;
        totalLockedCollateral -= collateralToRelease;
        syntheticDebt[msg.sender] = debt - syntheticAmount;
        totalSyntheticDebt -= syntheticAmount;

        // Burn synthetic tokens from user
        syntheticToken.burn(msg.sender, syntheticAmount);

        emit SyntheticBurned(msg.sender, syntheticAmount, price, collateralToRelease);
    }

    // ============ Liquidation Function ============

    /// @notice Liquidates an unhealthy position by repaying part or all of its sSPY debt.
    /// @dev The liquidator burns their own sSPY to repay `repayAmount` of `user`'s debt and, in
    ///      return, seizes collateral equal to the USDC value of the repaid debt plus a bonus. The
    ///      seizure is taken from the borrower's locked collateral first and, if that is
    ///      insufficient, from their available collateral — capped at the borrower's TOTAL
    ///      collateral, so their own funds absorb their loss before the protocol does. Only
    ///      permitted once the position's oracle-priced collateralization ratio falls strictly
    ///      below `liquidationThreshold`. A liquidation whose seizure would consume all of the
    ///      locked collateral must fully repay the debt (`newDebt == 0`), so no un-repaid,
    ///      under-collateralized remainder is ever left stranded; smaller partial repayments that
    ///      stay within the locked collateral are always allowed. Fully repaying the debt closes
    ///      the position and returns any collateral remaining after the seizure to the borrower's
    ///      available balance. If the seized collateral cannot cover the repaid debt value (extreme
    ///      price gap that exceeds even the borrower's total collateral), the shortfall is surfaced
    ///      via {BadDebtRealized} rather than hidden — the contract never pays out more USDC than
    ///      the position actually holds.
    /// @param user The owner of the position being liquidated
    /// @param repayAmount Amount of sSPY debt to repay on the user's behalf (18 decimals)
    function liquidate(address user, uint256 repayAmount) external nonReentrant whenNotPaused {
        require(repayAmount > 0, "Amount must be greater than zero");

        // Validate price feed and get current price (staleness enforced).
        // Protocol-health is intentionally NOT required here so liquidations can proceed —
        // and restore health — even while the global monitor reports the protocol unhealthy.
        uint256 price = _validatePriceFeed();

        uint256 debt = syntheticDebt[user];
        require(debt > 0, "No debt");
        require(repayAmount <= debt, "Exceeds debt");

        uint256 lockedBefore = lockedCollateral[user];

        // Position must be below the liquidation threshold at the current price.
        require(
            _collateralRatio(lockedBefore, debt, price) < liquidationThreshold,
            "Position not liquidatable"
        );

        // Liquidator must hold the sSPY they are repaying.
        require(syntheticToken.balanceOf(msg.sender) >= repayAmount, "Insufficient balance");

        uint256 totalBefore = totalCollateral[user];

        // Collateral to seize = repaid debt value + bonus. A defaulting borrower's OWN collateral
        // must absorb their loss before the protocol does, so the seizure draws from locked
        // collateral first and then from the borrower's available collateral — capped at everything
        // they hold (not just the locked portion). This closes the leak where an underwater
        // borrower kept their available deposit while the protocol ate the bad debt.
        uint256 repayValue = _debtValueUSDC(repayAmount, price);
        uint256 seize = repayValue + (repayValue * liquidationBonusBps) / BPS_DENOMINATOR;
        if (seize > totalBefore) {
            seize = totalBefore;
        }

        uint256 newDebt = debt - repayAmount;

        // Dipping past the locked collateral (into the borrower's available balance) is only
        // coherent when the debt is fully cleared. A *partial* liquidation that consumed all of the
        // locked collateral would leave the un-repaid remainder wholly unbacked and — because
        // available stays withdrawable — silently strand it. Force such liquidations to fully close
        // the position; a liquidator who cannot do so can repay a smaller amount that stays within
        // the locked collateral (which always leaves the remaining debt backed).
        if (seize >= lockedBefore) {
            require(newDebt == 0, "Must fully close underwater position");
        }

        // With the guard above, any surviving debt (newDebt > 0) is guaranteed to still be backed
        // by a positive `lockedBefore - seize`, so bad debt can only arise on a full close: when the
        // seized collateral cannot even cover the repaid debt value.
        uint256 shortfall = repayValue > seize ? repayValue - seize : 0;

        // ---- Effects ----
        syntheticDebt[user] = newDebt;
        totalSyntheticDebt -= repayAmount;
        totalCollateral[user] = totalBefore - seize;

        if (newDebt == 0) {
            // Position fully closed: unlock any collateral left after the seizure back to the
            // borrower's available balance (it is their remaining equity, not the liquidator's).
            totalLockedCollateral -= lockedBefore;
            lockedCollateral[user] = 0;
        } else {
            // seize < lockedBefore here, so the remaining debt keeps positive locked backing.
            lockedCollateral[user] = lockedBefore - seize;
            totalLockedCollateral -= seize;
        }

        // ---- Interactions ----
        // Burn the liquidator's sSPY (repays the debt) and pay out the seized collateral.
        syntheticToken.burn(msg.sender, repayAmount);
        bool success = usdc.transfer(msg.sender, seize);
        require(success, "USDC transfer failed");

        emit Liquidated(user, msg.sender, repayAmount, seize, price);
        if (shortfall > 0) {
            emit BadDebtRealized(user, shortfall);
        }
    }

    // ============ View Functions ============

    /// @notice Returns the total USDC collateral held by the contract
    /// @dev Used by CRE workflow to read on-chain collateral state
    /// @return Total USDC balance of this contract
    function getCollateralValue() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Returns the latest price from the CRE price feed with staleness check
    /// @dev Reverts if feed is not set, price is invalid, or data is stale
    /// @return price The current stock price (8 decimals)
    function getLatestPrice() external view returns (uint256 price) {
        return _validatePriceFeed();
    }

    /// @notice Returns the user's current oracle-priced collateralization ratio
    /// @dev CR = lockedCollateral * 100 / debtValue, computed against the user's tracked debt
    ///      (not their token balance) so transfers cannot distort it.
    /// @param user The address of the user to query
    /// @return ratio The collateralization ratio as a percentage (e.g., 150 = 150%)
    function getUserCollateralRatio(address user) external view returns (uint256 ratio) {
        uint256 debt = syntheticDebt[user];
        uint256 locked = lockedCollateral[user];

        // If no position, return max uint (infinite CR)
        if (debt == 0 || locked == 0) {
            return type(uint256).max;
        }

        // Get current price (with staleness check)
        uint256 price = _validatePriceFeed();

        return _collateralRatio(locked, debt, price);
    }

    /// @notice Returns whether a user's position can currently be liquidated
    /// @dev True when the position has debt and its oracle-priced CR is below liquidationThreshold
    /// @param user The address of the user to query
    /// @return liquidatable Whether the position is eligible for liquidation
    function isLiquidatable(address user) external view returns (bool liquidatable) {
        uint256 debt = syntheticDebt[user];
        if (debt == 0) {
            return false;
        }
        uint256 price = _validatePriceFeed();
        return _collateralRatio(lockedCollateral[user], debt, price) < liquidationThreshold;
    }

    /// @notice Returns the user's available collateral (not backing any minted tokens)
    /// @param user The address of the user to query
    /// @return available The amount of USDC available for withdrawal or new mints (6 decimals)
    function getAvailableCollateral(address user) external view returns (uint256 available) {
        return totalCollateral[user] - lockedCollateral[user];
    }

    /// @notice Returns the maximum amount of synthetic tokens the user can mint
    /// @dev Based on available collateral, current price, and min collateralization ratio
    /// @param user The address of the user to query
    /// @return maxMintable The maximum synthetic tokens mintable (18 decimals)
    function getMaxMintable(address user) external view returns (uint256 maxMintable) {
        uint256 available = totalCollateral[user] - lockedCollateral[user];
        
        // If no available collateral, return 0
        if (available == 0) {
            return 0;
        }
        
        // Get current price (with staleness check)
        uint256 price = _validatePriceFeed();

        // Inverse of the mint requirement, accounting for the USDC mint fee:
        //   requiredCollateral + fee = syntheticAmount * price * (minCR*100 + mintFeeBps)
        //                              / (BPS_DENOMINATOR * 10^PRICE_DECIMALS * 10^12)
        // Solving for syntheticAmount at available collateral:
        maxMintable = (available * BPS_DENOMINATOR * 10**PRICE_DECIMALS * 10**(SYNTHETIC_DECIMALS - USDC_DECIMALS))
            / (price * (minCollateralizationRatio * 100 + mintFeeBps));

        return maxMintable;
    }

    /// @notice Returns the USD value of the user's synthetic token holdings
    /// @dev Value = syntheticBalance * price / 10^PRICE_DECIMALS
    /// @param user The address of the user to query
    /// @return value The USD value of the position (adjusted for decimals)
    function getPositionValue(address user) external view returns (uint256 value) {
        uint256 syntheticBalance = syntheticToken.balanceOf(user);
        
        // If no position, return 0
        if (syntheticBalance == 0) {
            return 0;
        }
        
        // Get current price (with staleness check)
        uint256 price = _validatePriceFeed();
        
        // Value = syntheticBalance * price / 10^PRICE_DECIMALS
        // Result is in synthetic token decimals (18) representing USD value
        value = (syntheticBalance * price) / 10**PRICE_DECIMALS;
        
        return value;
    }

    // ============ Fee Collection ============

    /// @notice Collects accumulated fees and transfers them to the fee recipient
    /// @dev Only callable by owner or feeRecipient. Fees are accumulated and paid in USDC
    ///      (6 decimals) — no synthetic tokens are minted, so supply always equals total debt.
    function collectFees() external nonReentrant {
        require(msg.sender == owner() || msg.sender == feeRecipient, "Not authorized");

        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees to collect");

        // Reset accumulated fees before transfer (checks-effects-interactions)
        accumulatedFees = 0;

        // Transfer collected USDC fees to the fee recipient.
        bool success = usdc.transfer(feeRecipient, amount);
        require(success, "USDC transfer failed");

        emit FeesCollected(feeRecipient, amount);
    }
}
