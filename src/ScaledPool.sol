// SPDX-License-Identifier: MIT

pragma solidity 0.8.14;

import { Clone } from "@clones/Clone.sol";

import { ERC20 }     from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { FenwickTree } from "./FenwickTree.sol";
import { Queue }       from "./Queue.sol";

import { BucketMath } from "./libraries/BucketMath.sol";
import { Maths }      from "./libraries/Maths.sol";

contract ScaledPool is Clone, FenwickTree, Queue {
    using SafeERC20 for ERC20;

    /**************/
    /*** Events ***/
    /**************/

    event AddQuoteToken(address indexed lender_, uint256 indexed price_, uint256 amount_, uint256 lup_);
    event MoveQuoteToken(address indexed lender_, uint256 indexed from_, uint256 indexed to_, uint256 amount_, uint256 lup_);
    event RemoveQuoteToken(address indexed lender_, uint256 indexed price_, uint256 amount_, uint256 lup_);

    event AddCollateral(address indexed borrower_, uint256 amount_);
    event Borrow(address indexed borrower_, uint256 lup_, uint256 amount_);
    event RemoveCollateral(address indexed borrower_, uint256 amount_);
    event Repay(address indexed borrower_, uint256 lup_, uint256 amount_);

    /***************/
    /*** Structs ***/
    /***************/

    struct Bucket {
        uint256 lpAccumulator;
        uint256 availableCollateral;
    }

    struct Borrower {
        uint256 debt;
        uint256 collateral;
        uint256 inflatorSnapshot;
    }

    int256  public constant INDEX_OFFSET       = 3232;
    uint256 public constant WAD_WEEKS_PER_YEAR = 52 * 10**18;
    uint256 public constant SECONDS_PER_YEAR   = 3_600 * 24 * 365;

    uint256 public constant RATE_INCREASE_COEFFICIENT = 1.1 * 10**18;
    uint256 public constant RATE_DECREASE_COEFFICIENT = 0.9 * 10**18;
    // lambda used for the EMAs calculated as exp(-1/7 * ln2)
    uint256 public constant LAMBDA_EMA                = 0.905723664263906671 * 10**18;
    uint256 public constant EMA_RATE_FACTOR           = 10**18 - LAMBDA_EMA;

    /***********************/
    /*** State Variables ***/
    /***********************/

    uint256 public inflatorSnapshot;           // [RAY]
    uint256 public lastInflatorSnapshotUpdate; // [SEC]
    uint256 public minFee;                     // [WAD]
    uint256 public lenderInterestFactor;       // WAD
    uint256 public interestRate;               // [WAD]

    uint256 public lenderDebt;
    uint256 public borrowerDebt;

    uint256 public collateralScale;
    uint256 public quoteTokenScale;

    uint256 public depositAccumulator;

    uint256 public debtEma;   // [WAD]
    uint256 public lupColEma; // [WAD]

    /**
     *  @notice Mapping of buckets for a given pool
     *  @dev    deposit index -> bucket
     */
    mapping(uint256 => Bucket) public buckets;

    /**
     *  @dev deposit index -> lender address -> lender lp [WAD]
     */
    mapping(uint256 => mapping(address => uint256)) public lpBalance;

    // borrowers book: borrower address -> BorrowerInfo
    mapping(address => Borrower) public borrowers;

    uint256 internal _poolInitializations = 0;

    /*****************************/
    /*** Inititalize Functions ***/
    /*****************************/

    function initialize(uint256 rate_) external {
        require(_poolInitializations == 0, "P:INITIALIZED");
        collateralScale = 10**(18 - collateral().decimals());
        quoteTokenScale = 10**(18 - quoteToken().decimals());

        inflatorSnapshot           = 10**18;
        lastInflatorSnapshotUpdate = block.timestamp;
        lenderInterestFactor       = 0.9 * 10**18;
        interestRate               = rate_;
        minFee                     = 0.0005 * 10**18;

        // increment initializations count to ensure these values can't be updated
        _poolInitializations += 1;
    }

    /*********************************/
    /*** Lender External Functions ***/
    /*********************************/

    function addQuoteToken(uint256 amount_, uint256 index_) external returns (uint256 lpbChange_) {
        _accruePoolInterest();

        Bucket storage bucket = buckets[index_];
        uint256 bucketSize    = _rangeSum(index_, index_);
        uint256 exchangeRate  = bucket.lpAccumulator != 0 ? Maths.wdiv(bucketSize, bucket.lpAccumulator) : Maths.WAD;

        lpbChange_            = Maths.wdiv(amount_, exchangeRate);
        bucket.lpAccumulator  += lpbChange_;

        lpBalance[index_][msg.sender] += lpbChange_;

        _add(index_, amount_);
        depositAccumulator += amount_;

        _updateInterestRate();

        // move quote token amount from lender to pool
        quoteToken().safeTransferFrom(msg.sender, address(this), amount_ / quoteTokenScale);
        emit AddQuoteToken(msg.sender, _indexToPrice(index_), amount_, _lup());
    }

    function moveQuoteToken(uint256 lpbAmount_, uint256 fromIndex_, uint256 toIndex_) external {
        require(fromIndex_ != toIndex_, "S:MQT:SAME_PRICE");

        uint256 availableLPs = lpBalance[fromIndex_][msg.sender];
        require(availableLPs != 0 && lpbAmount_ <= availableLPs, "S:MQT:INSUF_LPS");

        _accruePoolInterest();

        Bucket storage fromBucket = buckets[fromIndex_];
        uint256 bucketSize        = _rangeSum(fromIndex_, fromIndex_);
        uint256 exchangeRate      = fromBucket.lpAccumulator != 0 ? Maths.wdiv(bucketSize, fromBucket.lpAccumulator) : Maths.WAD;
        uint256 amount            = Maths.wmul(lpbAmount_, exchangeRate);
        fromBucket.lpAccumulator  -= lpbAmount_;

        Bucket storage toBucket = buckets[toIndex_];
        bucketSize              = _rangeSum(toIndex_, toIndex_);
        exchangeRate            = toBucket.lpAccumulator != 0 ? Maths.wdiv(bucketSize, toBucket.lpAccumulator) : Maths.WAD;
        uint256 lpbChange       = Maths.wdiv(amount, exchangeRate);
        toBucket.lpAccumulator  += lpbChange;

        _remove(fromIndex_, amount);
        _add(toIndex_, amount);

        uint256 lup = _lup();
        if (fromIndex_ < toIndex_) require(_htp() <= lup, "S:MQT:LUP_BELOW_HTP");

        lpBalance[fromIndex_][msg.sender] -= lpbAmount_;
        lpBalance[toIndex_][msg.sender]   += lpbChange;

        _updateInterestRate();

        emit MoveQuoteToken(msg.sender, fromIndex_, toIndex_, lpbAmount_, lup);

    }

    function removeQuoteToken(uint256 lpbAmount_, uint256 index_) external {
        uint256 availableLPs = lpBalance[index_][msg.sender];
        require(availableLPs != 0 && lpbAmount_ <= availableLPs, "S:RQT:INSUF_LPS");

        _accruePoolInterest();

        Bucket storage bucket = buckets[index_];
        uint256 bucketSize    = _rangeSum(index_, index_);
        uint256 exchangeRate  = bucket.lpAccumulator != 0 ? Maths.wdiv(bucketSize, bucket.lpAccumulator) : Maths.WAD;
        uint256 amount        = Maths.wmul(lpbAmount_, exchangeRate);
        bucket.lpAccumulator  -= lpbAmount_;

        lpBalance[index_][msg.sender] -= lpbAmount_;

        require(_htp() <= _indexToPrice(_lupIndex(amount)), "S:RQT:BAD_LUP");

        _remove(index_, amount);
        depositAccumulator -= amount;

        _updateInterestRate();

        // move quote token amount from pool to lender
        quoteToken().safeTransfer(msg.sender, amount / quoteTokenScale);
        emit RemoveQuoteToken(msg.sender, _indexToPrice(index_), amount, _lup());
    }

    /***********************************/
    /*** Borrower External Functions ***/
    /***********************************/

    function addCollateral(uint256 amount_, address oldPrev_, address newPrev_, uint256 radius_) external {
        _accruePoolInterest();

        // borrower accounting
        Borrower storage borrower = borrowers[msg.sender];
        _accrueBorrowerInterest(borrower);
        borrower.collateral += amount_;

        if (borrower.debt != 0) _updateLoanQueue(msg.sender, Maths.wdiv(borrower.debt, borrower.collateral), oldPrev_, newPrev_, radius_);

        _updateInterestRate();

        // move collateral from sender to pool
        collateral().safeTransferFrom(msg.sender, address(this), amount_ / collateralScale);
        emit AddCollateral(msg.sender, amount_);
    }

    function borrow(uint256 amount_, uint256 limitIndex_, address oldPrev_, address newPrev_, uint256 radius_) external {

        Borrower storage borrower = borrowers[msg.sender];
        uint256 lupId = _lupIndex(amount_);
        require(lupId <= limitIndex_, "S:B:LIMIT_REACHED");

        _accruePoolInterest();
        _accrueBorrowerInterest(borrower);

        uint256 feeRate = Maths.max(Maths.wdiv(interestRate, WAD_WEEKS_PER_YEAR), minFee) + Maths.WAD;
        uint256 debt    = Maths.wmul(amount_, feeRate);
        borrower.debt   += debt;

        uint256 newLup = _indexToPrice(lupId);
        require(_borrowerCollateralization(borrower.debt, borrower.collateral, newLup) >= Maths.WAD, "S:B:BUNDER_COLLAT");

        uint256 curBorrowerDebt = borrowerDebt + debt;
        require(_poolCollateralization(
            curBorrowerDebt, amount_, collateral().balanceOf(address(this)) / collateralScale, newLup) >= Maths.WAD,
            "S:B:PUNDER_COLLAT"
        );

        borrowerDebt       = curBorrowerDebt;
        lenderDebt         += amount_;
        depositAccumulator -= amount_;

        _updateLoanQueue(msg.sender, Maths.wdiv(borrower.debt, borrower.collateral), oldPrev_, newPrev_, radius_);

        _updateInterestRate();

        // move borrowed amount from pool to sender
        quoteToken().safeTransfer(msg.sender, amount_ / quoteTokenScale);
        emit Borrow(msg.sender, newLup, amount_);
    }

    function removeCollateral(uint256 amount_, address oldPrev_, address newPrev_, uint256 radius_) external {
        _accruePoolInterest();

        // borrower accounting
        Borrower storage borrower = borrowers[msg.sender];
        _accrueBorrowerInterest(borrower);

        require(borrower.debt <= Maths.wmul(_lup(), borrower.collateral - amount_), "S:RC:NOT_ENOUGH_COLLATERAL");
        borrower.collateral -= amount_;

        if (borrower.debt != 0) _updateLoanQueue(msg.sender, Maths.wdiv(borrower.debt, borrower.collateral), oldPrev_, newPrev_, radius_);

        _updateInterestRate();

        // move collateral from pool to sender
        collateral().safeTransfer(msg.sender, amount_ / collateralScale);
        emit RemoveCollateral(msg.sender, amount_);
    }

    function repay(uint256 maxAmount_, address oldPrev_, address newPrev_, uint256 radius_) external {
        uint256 availableAmount = quoteToken().balanceOf(msg.sender) * quoteTokenScale;
        require(availableAmount >= maxAmount_, "S:R:INSUF_BAL");

        Borrower storage borrower = borrowers[msg.sender];
        require(borrower.debt != 0, "P:R:NO_DEBT");

        _accruePoolInterest();
        _accrueBorrowerInterest(borrower);

        uint256 amount = Maths.min(borrower.debt, maxAmount_);
        borrower.debt -= amount;

        uint256 curBorrowerDebt = borrowerDebt;
        uint256 curLenderDebt   = lenderDebt;

        curLenderDebt -= Maths.min(curLenderDebt, Maths.wmul(Maths.wdiv(curLenderDebt, curBorrowerDebt), amount));

        borrowerDebt = curBorrowerDebt - amount;
        lenderDebt   = curLenderDebt;

        if (borrower.debt == 0) _removeLoanQueue(msg.sender, oldPrev_);
        else _updateLoanQueue(msg.sender, Maths.wdiv(borrower.debt, borrower.collateral), oldPrev_, newPrev_, radius_);

        _updateInterestRate();

        // move amount to repay from sender to pool
        quoteToken().safeTransferFrom(msg.sender, address(this), amount / quoteTokenScale);
        emit Repay(msg.sender, _lup(), amount);
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _accruePoolInterest() internal {
        //TODO add inline with sim
        uint256 debt = borrowerDebt;
        if (debt != 0) {
            uint256 elapsed = block.timestamp - lastInflatorSnapshotUpdate;
            if (elapsed != 0 ) {
                uint256 spr = Maths.wadToRay(interestRate) / SECONDS_PER_YEAR;
                uint256 pendingInflator = Maths.rmul(inflatorSnapshot, Maths.rpow(Maths.RAY + spr, elapsed));

                uint256 newHtp = _htp();
                if (newHtp != 0) {
                    uint256 newInterest     = Maths.radToWadTruncate(debt * (Maths.rdiv(pendingInflator, inflatorSnapshot) - Maths.RAY));
                    uint256 htpIndex        = _priceToIndex(newHtp);
                    uint256 depositAboveHtp = _prefixSum(htpIndex);
                    if (depositAboveHtp != 0) {
                        uint256 lenderFactor = Maths.wdiv(newInterest, depositAboveHtp) + Maths.WAD;
                        _mult(htpIndex, lenderFactor);
                    }
                }

                borrowerDebt = Maths.wmul(debt, pendingInflator);

                inflatorSnapshot           = pendingInflator;
                lastInflatorSnapshotUpdate = block.timestamp;
            }
        }
    }

    function _accrueBorrowerInterest(Borrower storage borrower_) internal {
        if (borrower_.debt != 0 && borrower_.inflatorSnapshot != 0) {
            borrower_.debt = Maths.wmul(borrower_.debt, Maths.wdiv(inflatorSnapshot, borrower_.inflatorSnapshot));
        }
        borrower_.inflatorSnapshot = inflatorSnapshot;
    }

    function _updateInterestRate() internal {
        // TODO implement
    }

    function _borrowerCollateralization(uint256 debt_, uint256 collateral_, uint256 price_) internal pure returns (uint256 collateralization_) {
        uint256 encumberedCollateral = price_ != 0 && debt_ != 0 ? Maths.wdiv(debt_, price_) : 0;
        collateralization_ = collateral_ != 0 && encumberedCollateral != 0 ? Maths.wdiv(collateral_, encumberedCollateral) : Maths.WAD;
    }

    function _poolCollateralization(uint256 borrowerDebt_, uint256 additionalDebt_, uint256 collateral_, uint256 price_
    ) internal pure returns (uint256 collateralization_) {
        uint256 encumbered = Maths.wdiv(borrowerDebt_ + additionalDebt_, price_);
        collateralization_ = encumbered != 0 ? Maths.wdiv(collateral_, encumbered) : Maths.WAD;
    }

    function _htp() internal view returns (uint256) {
        if (loanQueueHead != address(0)) {
            return loans[loanQueueHead].thresholdPrice;
        }
        return 0;
    }

    function _lupIndex(uint256 additionalDebt_) internal view returns (uint256) {
        return _findSum(lenderDebt + additionalDebt_);
    }

    function _indexToPrice(uint256 index_) internal pure returns (uint256) {
        return BucketMath.indexToPrice(7388 - int256(index_) - 3232);
    }

    function _priceToIndex(uint256 price_) internal pure returns (uint256) {
        return uint256(7388 - (BucketMath.priceToIndex(price_) + 3232));
    }

    function _lup() internal view returns (uint256) {
        return _indexToPrice(_lupIndex(0));
    }

    /**************************/
    /*** External Functions ***/
    /**************************/

    function lup() external view returns (uint256) {
        return _lup();
    }

    function lupIndex() external view returns (uint256) {
        return _lupIndex(0);
    }

    function htp() external view returns (uint256) {
        return _htp();
    }

    function priceToIndex(uint256 price_) external pure returns (uint256) {
        return _priceToIndex(price_);
    }

    /************************/
    /*** Helper Functions ***/
    /************************/

    /**
     *  @dev Pure function used to facilitate accessing token via clone state.
     */
    function collateral() public pure returns (ERC20) {
        return ERC20(_getArgAddress(0));
    }

    /**
     *  @dev Pure function used to facilitate accessing token via clone state.
     */
    function quoteToken() public pure returns (ERC20) {
        return ERC20(_getArgAddress(0x14));
    }
}