// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelinUpgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelinUpgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelinUpgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelinUpgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelinUpgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

import "interfaces/IReceiptsHolder.sol";
import "interfaces/ILBPair.sol";
import "interfaces/ILBRouter.sol";
import "interfaces/ILBToken.sol";
import "interfaces/IOracleHelper.sol";
import "interfaces/IStrategy.sol";
import "interfaces/IViewHelper.sol";

/// @title Locker
/// @author Vector Team
contract LBPool is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    address public tokenX;
    address public tokenY;
    uint256 public binStep;

    address public strategy;

    IReceiptsHolder public receiptsManager;
    ILBRouter public router;
    ILBPair public pair;
    ILBToken public receiptToken;
    IViewHelper public viewHelper;

    IOracleHelper public oracle;
    uint256 public constant PRECISION = 10000;
    uint256 constant EPSILON = 1000;

    EnumerableSet.UintSet private depositedIds;

    uint256 public withdrawalFee;
    uint256 public withdrawalFeeDelay;

    uint256 public swapThreshold;
    uint256 public depositThreshold;
    uint256 public addLiquidityThreshold;

    uint256 public swapMaxValue;
    uint256 public swapMinimumThreshold;
    uint256 public deltaSwapSafeguard;
    uint256 public lastSwap;
    uint256 public delayBetweenSwaps;

    mapping(address => uint256) public lastDepositedTime;

    event SetDelayBetweenSwaps(uint256);
    event SetDeltaSwapSafeguard(uint256);
    event SetSwapMinimumThreshold(uint256);
    event SetSwapMaxValue(uint256);
    event SetSwapThreshold(uint256);
    event SetAddLiquidityThreshold(uint256);
    event SetDepositThreshold(uint256);
    event SetStrategy(address);
    event SetWithdrawalFee(uint256 delay, uint256 value);
    event SetOracle(address);
    event SetReceiptsManager(address);
    event ParamsSet(int256[] _deltaIds, uint256[] _distributionX, uint256[] _distributionY);
    event LiquidityRemoved(uint256[] ids, uint256[] receiptBalances);
    event LiquidityAdded(
        int256[] deltaIds,
        uint256[] distributionX,
        uint256[] distributionY,
        uint256 amountX,
        uint256 amountY
    );
    event SwapToken(
        address inToken,
        uint256 inTokenAmount,
        address outToken,
        uint256 outTokenAmount
    );
    event Rebalance();
    event Withdrawal(address indexed user, uint256 amountX, uint256 amountY);
    event Deposit(address indexed user, uint256 amountX, uint256 amountY);

    function __LBPool_init(
        address _tokenX,
        address _tokenY,
        uint256 _binStep,
        address _router,
        address _pair,
        address _viewHelper
    ) external initializer {
        __Ownable_init();
        __ERC20_init("VLB", "VLB");
        __Pausable_init();
        __ReentrancyGuard_init();
        router = ILBRouter(_router);
        tokenX = _tokenX;
        tokenY = _tokenY;
        binStep = _binStep;
        pair = ILBPair(_pair);
        _approveTokenIfNeeded(tokenX, _router);
        _approveTokenIfNeeded(tokenY, _router);
        receiptToken = ILBToken(_pair);
        receiptToken.setApprovalForAll(_router, true);
        viewHelper = IViewHelper(_viewHelper);
    }

    modifier onlyStrategy() {
        require(msg.sender == strategy, "Only strategy");
        _;
    }

    function setReceiptsManager(address _receiptsManager) external onlyOwner {
        receiptsManager = IReceiptsHolder(_receiptsManager);
        emit SetReceiptsManager(_receiptsManager);
    }

    function setOracle(address _oracle) external onlyOwner {
        oracle = IOracleHelper(_oracle);
        emit SetOracle(_oracle);
    }

    function setWithdrawalFee(uint256 delay, uint256 value) external onlyOwner {
        withdrawalFee = value;
        withdrawalFeeDelay = delay;
        emit SetWithdrawalFee(delay, value);
    }

    function setStrategy(address _strategy) external onlyOwner {
        strategy = _strategy;
        emit SetStrategy(strategy);
    }

    function setDepositThreshold(uint256 _value) external onlyOwner {
        depositThreshold = _value;
        emit SetDepositThreshold(_value);
    }

    function setAddLiquidityThreshold(uint256 _value) external onlyOwner {
        addLiquidityThreshold = _value;
        emit SetAddLiquidityThreshold(_value);
    }

    function setSwapThreshold(uint256 _value) external onlyOwner {
        swapThreshold = _value;
        emit SetSwapThreshold(_value);
    }

    function setSwapMaxValue(uint256 _value) external onlyOwner {
        swapMaxValue = _value;
        emit SetSwapMaxValue(_value);
    }

    function setSwapMinimumThreshold(uint256 _value) external onlyOwner {
        swapMinimumThreshold = _value;
        emit SetSwapMinimumThreshold(_value);
    }

    function setDeltaSwapSafeguard(uint256 _value) external onlyOwner {
        deltaSwapSafeguard = _value;
        emit SetDeltaSwapSafeguard(_value);
    }

    function setDelayBetweenSwaps(uint256 _value) external onlyOwner {
        delayBetweenSwaps = _value;
        emit SetDelayBetweenSwaps(_value);
    }

    function getOraclePrice() public view returns (uint256 oraclePrice) {
        oraclePrice = oracle.getPriceOfXInYUnits(tokenX, tokenY);
    }

    function getPriceFromActiveBin() public view returns (uint256 price) {
        (, , uint256 activeId) = getPairInfos();
        price = viewHelper.getPriceFromBin(activeId, binStep);
    }

    function checkPrice(uint256 threshold) public view {
        if (threshold > 0) {
            uint256 activeBinPrice = getPriceFromActiveBin();
            uint256 oraclePrice = getOraclePrice();
            uint256 delta = activeBinPrice > oraclePrice
                ? activeBinPrice - oraclePrice
                : oraclePrice - activeBinPrice;
            require((delta * 10**18) / oraclePrice < threshold, "Price out of bounds");
        }
    }

    function checkSwapStatus(uint256 amountIn, address _for) public view {
        uint256 oraclePrice = getOraclePrice();
        (uint256 reserveX, uint256 reserveY) = getTotalFunds();
        uint256 tvlFor = tokenX == _for ? (reserveX * oraclePrice) / 10**18 : reserveY;
        uint256 tvlOther = tokenX == _for ? reserveY : (reserveX * oraclePrice) / 10**18;
        require(
            tvlFor <= ((swapMinimumThreshold * tvlOther) / 10**18),
            "Only if under swapMinimumThreshold"
        );
        uint256 reserveOther = tokenX == _for ? reserveY : reserveX;
        require(amountIn <= ((swapMaxValue * reserveOther) / 10**18), "Only a swapMaxValue swap");
    }

    function getPairInfos()
        public
        view
        returns (
            uint256 reservesX,
            uint256 reservesY,
            uint256 activeId
        )
    {
        (reservesX, reservesY, activeId) = pair.getReservesAndId();
    }

    function getDepositedBins() public view returns (uint256[] memory _depositedIds) {
        _depositedIds = depositedIds.values();
    }

    function getHighestAndLowestBin() public view returns (uint256 highestBin, uint256 lowestBin) {
        uint256 length = depositedIds.length();
        if (length > 0) {
            lowestBin = depositedIds.at(0);
            highestBin = depositedIds.at(0);
            for (uint256 i; i < length; i++) {
                uint256 bin = depositedIds.at(i);
                if (bin < lowestBin) {
                    lowestBin = bin;
                } else if (bin > highestBin) {
                    highestBin = bin;
                }
            }
        }
    }

    function getTotalReserveForBin(uint256 bin)
        public
        view
        returns (uint256 pairReserveX, uint256 pairReserveY)
    {
        (pairReserveX, pairReserveY) = pair.getBin(uint24(bin));
    }

    function getReserveForBin(uint256 bin)
        public
        view
        returns (uint256 reserveX, uint256 reserveY)
    {
        (reserveX, reserveY, ) = receiptsManager.getReserveForBin(bin);
    }

    function getAllReserves() public view returns (uint256 totalReserveX, uint256 totalReserveY) {
        uint256 length = depositedIds.length();
        for (uint256 i; i < length; i++) {
            (uint256 binReserveX, uint256 binReserveY) = getReserveForBin(depositedIds.at(i));
            totalReserveX += binReserveX;
            totalReserveY += binReserveY;
        }
    }

    function getBalances() public view returns (uint256 tokenXbalance, uint256 tokenYBalance) {
        (tokenXbalance, tokenYBalance) = (
            IERC20(tokenX).balanceOf(address(this)),
            IERC20(tokenY).balanceOf(address(this))
        );
    }

    function getTotalFunds() public view returns (uint256 totalX, uint256 totalY) {
        (uint256 tokenXBalance, uint256 tokenYBalance) = getBalances();
        (uint256 totalReserveX, uint256 totalReserveY) = getAllReserves();
        totalX = tokenXBalance + totalReserveX;
        totalY = tokenYBalance + totalReserveY;
    }

    /**
     * @notice Calculate shares amount for a given amount of depositToken
     * @param amount deposit token amount
     * @return number of shares
     */
    function getSharesForDepositTokens(uint256 amount, uint256 priceX)
        public
        view
        returns (uint256)
    {
        (uint256 totalReserveX, uint256 totalReserveY) = getTotalFunds();
        uint256 totalDeposits = (totalReserveY + ((totalReserveX * priceX) / 10**18));
        uint256 totalSupply = totalSupply();

        if (totalSupply == 0 || totalDeposits == 0) {
            return amount * 10**(18 - IERC20Metadata(tokenX).decimals() + 12);
        }
        return (amount * totalSupply) / totalDeposits;
    }

    /**
     * @notice Returns reserves outside of the active bin
     * @dev Useful in order to compute withdraw amount
     * @return totalReserveX amount of tokenX available outside of the active bin
     * @return totalReserveY amount of tokenY available outside of the active bin
     */
    function reservesOutsideActive()
        public
        view
        returns (uint256 totalReserveX, uint256 totalReserveY)
    {
        uint256 length = depositedIds.length();
        (uint256 reservesX, uint256 reservesY, uint256 activeId) = getPairInfos();
        for (uint256 i; i < length; i++) {
            uint256 currentBin = depositedIds.at(i);
            if (currentBin != activeId) {
                (uint256 binReserveX, uint256 binReserveY) = getReserveForBin(currentBin);
                totalReserveX += binReserveX;
                totalReserveY += binReserveY;
            }
        }
    }

    /**
     * @notice Compute max(a-b, 0)
     * @param a uint256
     * @param b uint256
     * @return uint256 max(a-b, 0)
     */
    function _diffOrZero(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /**
     * @notice Returns pending rewards per bin (as fees are computed per bin)
     * @param ids list of bins that we want to compute fees from
     * @return rewardsX amount of tokenX as fees
     * @return rewardsY amount of tokenY as fees
     */
    function pendingRewards(uint256[] calldata ids)
        external
        view
        returns (uint256 rewardsX, uint256 rewardsY)
    {
        (rewardsX, rewardsY) = pair.pendingFees(address(this), ids);
    }

    /**
     * @notice Harvest fees, and distributes caller fee, strategist fee and protocol fee
     * @param callerFeeRecipient user to send callerFee to
     */
    function harvest(address callerFeeRecipient) public {
        uint256 length = depositedIds.length();
        uint256[] memory depositedBins = new uint256[](length);
        for (uint256 i; i < length; i++) {
            depositedBins[i] = depositedIds.at(i);
        }
        receiptsManager.harvest(depositedBins, msg.sender);
    }

    /**
     * @notice deposit for msg sender
     * @param amountX amount of tokenX to deposit
     * @param amountY amount of tokenY to deposit
     */
    function deposit(uint256 amountX, uint256 amountY) external nonReentrant {
        _depositFor(amountX, amountY, msg.sender);
    }

    /**
     * @notice deposit for "_for"
     * @param amountX amount of tokenX to deposit
     * @param amountY amount of tokenY to deposit
     */
    function _depositFor(
        uint256 amountX,
        uint256 amountY,
        address _for
    ) internal {
        checkPrice(depositThreshold);
        harvest(msg.sender);
        uint256 oraclePrice = oracle.getPriceOfXInYUnits(tokenX, tokenY);
        uint256 depositValueY = amountY;
        uint256 depositValueX = (amountX * oraclePrice) / 10**18;
        uint256 shares = getSharesForDepositTokens(depositValueX + depositValueY, oraclePrice);
        IERC20(tokenX).safeTransferFrom(msg.sender, address(this), amountX);
        IERC20(tokenY).safeTransferFrom(msg.sender, address(this), amountY);
        emit Deposit(_for, amountX, amountY);
        require(shares > 0, "Cannot mint 0 shares");
        _mint(_for, shares);
        lastDepositedTime[_for] = block.timestamp;
    }

    /**
     * @notice Internal function to add liquidity, checks approval and handles the depositedIds
     * @param parameters parameters of the liquidity to be added see ILBRouter.LiquidityParameters
     */
    function _addLiquidity(ILBRouter.LiquidityParameters memory parameters) internal {
        checkPrice(addLiquidityThreshold);
        //will revert if more than 50 bins

        IERC20(tokenX).safeTransfer(address(receiptsManager), parameters.amountX);
        IERC20(tokenY).safeTransfer(address(receiptsManager), parameters.amountY);

        uint256[] memory depositIds = receiptsManager.addLiquidity(parameters);

        uint256 length = depositIds.length;
        for (uint256 i; i < length; i++) {
            depositedIds.add(depositIds[i]);
        }
        require(depositedIds.length() < 50, "Too much bins deposited");
    }

    /**
     * @notice Add all liquidity based on the current strategy, only available to the strategist
     * @param respectRatio In order to avoid fees when depositing in the active bin, strategist can indicate to respect the ratio
     */
    function addAllLiquidity(
        int256[] memory ids,
        uint256[] memory distributionX,
        uint256[] memory distributionY,
        bool respectRatio
    ) public onlyStrategy {
        addLiquidity(
            IERC20(tokenX).balanceOf(address(this)),
            IERC20(tokenY).balanceOf(address(this)),
            ids,
            distributionX,
            distributionY,
            respectRatio
        );
    }

    /**
     * @notice Add Liquidity without following the strategy, only available to the strategist
     * @dev the strategist can only deposit in the 50 range bin
     * @param amountX see ILBRouter.LiquidityParameters
     * @param amountY see ILBRouter.LiquidityParameters
     * @param _deltaIds see ILBRouter.LiquidityParameters
     * @param _distributionX see ILBRouter.LiquidityParameters
     * @param _distributionY see ILBRouter.LiquidityParameters
     * @param respectRatio In order to avoid fees when depositing in the active bin, strategist can indicate to respect the ratio
     */
    function addLiquidity(
        uint256 amountX,
        uint256 amountY,
        int256[] memory _deltaIds,
        uint256[] memory _distributionX,
        uint256[] memory _distributionY,
        bool respectRatio
    ) public onlyStrategy {
        (, , uint256 activeId) = getPairInfos();
        if (respectRatio) {
            (uint256 reserveX, uint256 reserveY) = getTotalReserveForBin(activeId);
            uint256 ratio = (reserveX * getPriceFromActiveBin()) / (reserveY + EPSILON);
            (_deltaIds, _distributionX, _distributionY) = viewHelper
                .computeDistributionToRespectRatio(
                    (amountX * getPriceFromActiveBin()) / 1e18,
                    amountY,
                    ratio,
                    _deltaIds,
                    _distributionX,
                    _distributionY
                );
        }
        ILBRouter.LiquidityParameters memory parameters = ILBRouter.LiquidityParameters({
            tokenX: tokenX,
            tokenY: tokenY,
            binStep: binStep,
            amountX: amountX,
            amountY: amountY,
            amountXMin: 0,
            amountYMin: 0,
            activeIdDesired: activeId,
            idSlippage: 0,
            deltaIds: _deltaIds,
            distributionX: _distributionX,
            distributionY: _distributionY,
            to: address(receiptsManager),
            deadline: block.timestamp
        });
        emit LiquidityAdded(_deltaIds, _distributionX, _distributionY, amountX, amountY);

        _addLiquidity(parameters);
    }

    /**
     * @notice Add Liquidity following the strategy, only available to the strategist
     * @dev This needs to have safeguards, as this can be front-run and/or used to manipulate the market
     * @param _for token to swap to
     * @param amountIn amount to swap
     * @param amountOutMin minimum amount to get of the _for token
     * @return amountOut amount of the _for token actually received
     */
    function swap(
        address _for,
        uint256 amountIn,
        uint256 amountOutMin
    ) public onlyStrategy returns (uint256 amountOut) {
        require(lastSwap + delayBetweenSwaps < block.timestamp);
        lastSwap = block.timestamp;
        checkSwapStatus(amountIn, _for);
        checkPrice(swapThreshold);
        (, , uint256 previousId) = getPairInfos();
        require(_for == tokenX || _for == tokenY, "Swap : Bad token");
        address otherToken = _for == tokenX ? tokenY : tokenX;
        address[] memory path = new address[](2);
        path[0] = otherToken;
        path[1] = _for;
        uint256[] memory binSteps = new uint256[](1);
        binSteps[0] = binStep;
        amountOut = router.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            binSteps,
            path,
            address(this),
            block.timestamp
        ); // use the router instead of pair to delegate the handling of minAmount
        (, , uint256 newId) = getPairInfos();
        uint256 delta = (newId > previousId) ? (newId - previousId) : (previousId - newId);
        require(delta < deltaSwapSafeguard, "deltaSwapSafeguard");
        emit SwapToken(otherToken, amountIn, _for, amountOut);
    }

    /**
     * @notice Withdraw a certain amount of token X and token Y.
     * @dev It will first try to withdraw from non-deposited tokens, then from outside bins, and finaly from the active bin.
     * @param amountX amount of token X to withdraw
     * @param amountY amount of token Y to withdraw
     * @param _harvest if the user wants to harvest fees before withdrawing in order to get the rewards.
     */
    function withdraw(
        uint256 amountX,
        uint256 amountY,
        bool _harvest
    ) external nonReentrant {
        _withdraw(amountX, amountY, _harvest);
    }

    function _withdraw(
        uint256 amountX,
        uint256 amountY,
        bool _harvest
    ) internal {
        emit Withdrawal(msg.sender, amountX, amountY);
        if (_harvest) {
            harvest(msg.sender);
        }
        uint256 oraclePrice = oracle.getPriceOfXInYUnits(tokenX, tokenY);
        uint256 neededShares = getSharesForDepositTokens(
            (amountX * oraclePrice) / 10**18 + amountY + 1,
            oraclePrice
        ) + 1;

        _burn(msg.sender, neededShares);

        uint256 fee = block.timestamp < lastDepositedTime[msg.sender] + withdrawalFeeDelay
            ? withdrawalFee
            : 0;
        {
            uint256 amountXAfterFee = amountX - (amountX * fee) / PRECISION;
            uint256 amountYAfterFee = amountY - (amountY * fee) / PRECISION;
            (uint256 balanceX, uint256 balanceY) = getBalances();
            amountX = _diffOrZero(amountXAfterFee, balanceX);
            amountY = _diffOrZero(amountYAfterFee, balanceY);
            if (amountX > 0 || amountY > 0) {
                _withdrawLiquidity(amountX, amountY);
            }
            if (amountX > 0) {
                uint256 balance = IERC20(tokenX).balanceOf(address(this));
                uint256 amountToSend = balance > amountXAfterFee ? amountXAfterFee : balance;
                IERC20(tokenX).safeTransfer(msg.sender, amountToSend);
            } else {
                IERC20(tokenX).safeTransfer(msg.sender, amountXAfterFee);
            }
            if (amountY > 0) {
                uint256 balance = IERC20(tokenY).balanceOf(address(this));
                uint256 amountToSend = balance > amountYAfterFee ? amountYAfterFee : balance;
                IERC20(tokenY).safeTransfer(msg.sender, amountToSend);
            } else {
                IERC20(tokenY).safeTransfer(msg.sender, amountYAfterFee);
            }
        }
    }

    /**
     * @notice Withdraw a certain amount of token X and token Y.
     * @dev It will first try to withdraw from non-deposited tokens, then from outside bins, and finaly from the active bin.
     * @param shares the amount of shares to withdraw
     * @param _harvest if the user wants to harvest fees before withdrawing in order to get the rewards.
     */
    function withdrawByShares(uint256 shares, bool _harvest) external nonReentrant {
        // emit Withdraw(msg.sender, amountX, amountY);
        if (_harvest) {
            harvest(msg.sender);
        }
        uint256 oraclePrice = oracle.getPriceOfXInYUnits(tokenX, tokenY);

        (uint256 availableAmountX, uint256 availableAmountY) = getTotalFunds();

        uint256 effectiveShares = shares - (getSharesForDepositTokens(1, oraclePrice) + 1);
        uint256 amountX = (availableAmountX * effectiveShares) / totalSupply();
        uint256 amountY = (availableAmountY * effectiveShares) / totalSupply();
        require(
            getSharesForDepositTokens((amountX * oraclePrice) / 10**18 + amountY + 1, oraclePrice) +
                1 <=
                shares
        );

        _withdraw(amountX, amountY, false);
    }

    /**
     * @notice Withdraw all liquidity of the vault, only strategist
     */
    function withdrawAllLiquidity() public onlyStrategy {
        uint256 length = depositedIds.length();
        if (length > 0) {
            uint256[] memory receiptBalances = new uint256[](length);
            uint256[] memory _ids = new uint256[](length);
            for (uint256 i; i < length; i++) {
                uint256 binNumber = depositedIds.at(i);
                uint256 binBalance = receiptToken.balanceOf(address(receiptsManager), binNumber);
                receiptBalances[i] = binBalance;
                _ids[i] = binNumber;
            }
            _removeLiquidity(_ids, receiptBalances);
            emit LiquidityRemoved(_ids, receiptBalances);
        }
    }

    /**
     * @notice Executes rebalance based on the current params.
     * @param respectRatio see trader joe fee based on deposit.
     */
    function executeRebalance(
        int256[] memory ids,
        uint256[] memory distributionX,
        uint256[] memory distributionY,
        bool respectRatio
    ) external onlyStrategy {
        withdrawAllLiquidity();
        addAllLiquidity(ids, distributionX, distributionY, respectRatio);
    }

    /**
     * @notice Withdraw liquidity from specific bins
     * @param ids bins to withdraw from
     * @param amounts amount of receipt token to burn
     */
    function withdrawLiquidityFromBins(uint256[] calldata ids, uint256[] calldata amounts)
        public
        onlyStrategy
    {
        _removeLiquidity(ids, amounts);
    }

    function _removeLiquidity(uint256[] memory ids, uint256[] memory amounts) internal {
        receiptsManager.removeLiquidity(ids, amounts);
        emit LiquidityRemoved(ids, amounts);
        uint256 length = ids.length;
        for (uint256 i; i < length; i++) {
            if (receiptToken.balanceOf(address(receiptsManager), ids[i]) == 0) {
                depositedIds.remove(ids[i]);
            }
        }
    }

    /**
     * @notice Withdraw amount X and amount Y of each token
     * @param amountX amount of token X to withdraw
     * @param amountY amount of token Y to withdraw
     */
    function withdrawLiquidity(uint256 amountX, uint256 amountY) public onlyStrategy {
        _withdrawLiquidity(amountX, amountY);
    }

    /**
     * @notice Withdraw amount X and amount Y of each token
     * @param amountX amount of token X to withdraw
     * @param amountY amount of token Y to withdraw
     */
    function _withdrawLiquidity(uint256 amountX, uint256 amountY) internal {
        (, , uint256 activeId) = getPairInfos();
        (uint256 reservesX, uint256 reservesY) = getReserveForBin(activeId);
        uint256 sharesFromActive;
        {
            (
                uint256 reservesXOutsideActive,
                uint256 reservesYOutsideActive
            ) = reservesOutsideActive();
            uint256 neededX = _diffOrZero(amountX, reservesXOutsideActive);
            uint256 neededY = _diffOrZero(amountY, reservesYOutsideActive);
            require(
                (amountX <= reservesXOutsideActive + reservesX) &&
                    (amountY <= reservesYOutsideActive + reservesY),
                "Not enough reserves"
            );

            if (neededX > 0 || neededY > 0) {
                if (neededY * reservesX > reservesY * neededX) {
                    uint256 amountXObtained;
                    (sharesFromActive, amountXObtained) = viewHelper
                        ._computeWithdrawAmountsFromActiveBin(
                            0,
                            neededY,
                            activeId,
                            address(receiptsManager)
                        );
                    amountX = _diffOrZero(amountX, amountXObtained);
                    amountY = _diffOrZero(amountY, neededY);
                } else {
                    uint256 amountYObtained;
                    (sharesFromActive, amountYObtained) = viewHelper
                        ._computeWithdrawAmountsFromActiveBin(
                            neededX,
                            0,
                            activeId,
                            address(receiptsManager)
                        );
                    amountY = _diffOrZero(amountY, amountYObtained);
                    amountX = _diffOrZero(amountX, neededX);
                }
            }
        }
        uint256 lengthX;
        uint256 lengthY;
        uint256[] memory finalAmountsY;
        uint256[] memory idsY;
        uint256[] memory finalAmountsX;
        uint256[] memory idsX;
        if (amountY > 0) {
            (finalAmountsY, idsY) = viewHelper.computeAmountsForWithdrawY(amountY);
            lengthY = finalAmountsY.length;
        }
        if (amountX > 0) {
            (finalAmountsX, idsX) = viewHelper.computeAmountsForWithdrawX(amountX);
            lengthX = finalAmountsX.length;
        }
        uint256 totalLength = lengthX + lengthY;
        totalLength = sharesFromActive > 0 ? totalLength + 1 : totalLength;
        uint256[] memory finalAmounts = new uint256[](totalLength);
        uint256[] memory ids = new uint256[](totalLength);

        for (uint256 i; i < lengthY; i++) {
            ids[i] = idsY[i];
            finalAmounts[i] = finalAmountsY[i];
        }
        if (sharesFromActive > 0) {
            ids[lengthY] = activeId;
            finalAmounts[lengthY] = sharesFromActive;
            for (uint256 i = lengthY + 1; i < totalLength; i++) {
                ids[i] = idsX[i - lengthY - 1];
                finalAmounts[i] = finalAmountsX[i - lengthY - 1];
            }
        } else {
            for (uint256 i = lengthY; i < totalLength; i++) {
                ids[i] = idsX[i - lengthY];
                finalAmounts[i] = finalAmountsX[i - lengthY];
            }
        }
        _removeLiquidity(ids, finalAmounts);
        emit LiquidityRemoved(ids, finalAmounts);
    }

    function _approveTokenIfNeeded(address token, address to) private {
        if (IERC20(token).allowance(address(this), to) == 0) {
            IERC20(token).safeApprove(to, type(uint256).max);
        }
    }
}
