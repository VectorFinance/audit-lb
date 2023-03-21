// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelinUpgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelinUpgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelinUpgradeable/contracts/security/PausableUpgradeable.sol";

import "./../../interfaces/ILBPool.sol";
import "./../../interfaces/ILBPair.sol";
import "./../../interfaces/ILBRouter.sol";
import "./../../interfaces/ILBFactory.sol";
import "./../../interfaces/ILBToken.sol";
import "./../../interfaces/IReceiptsHolder.sol";

import "./BinHelper.sol";

/// @title Locker
/// @author Vector Team
contract Strategy is Initializable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    address public tokenX;
    address public tokenY;
    uint256 public binStep;

    address public manager;
    address public vault;
    uint256 public maxSlippage;

    int256[] public deltaIds;
    uint256[] public distributionX;
    uint256[] public distributionY;

    struct LiquidityParameters {
        IERC20 tokenX;
        IERC20 tokenY;
        uint256 binStep;
        uint256 amountX;
        uint256 amountY;
        uint256 amountXMin;
        uint256 amountYMin;
        uint256 activeIdDesired;
        uint256 idSlippage;
        int256[] deltaIds;
        uint256[] distributionX;
        uint256[] distributionY;
        address to;
        uint256 deadline;
    }

    event SetManager(address manager);
    event SetParams(int256[] _deltaIds, uint256[] _distributionX, uint256[] _distributionY);

    function __Strategy_init_(address _vault) external initializer {
        __Ownable_init();
        __Pausable_init();
        vault = _vault;
        tokenX = ILBPool(vault).tokenX();
        tokenY = ILBPool(vault).tokenY();
        binStep = ILBPool(vault).binStep();
    }

    function setManager(address newManager) external onlyOwner {
        manager = newManager;
        emit SetManager(newManager);
    }

    modifier onlyManager() {
        require(msg.sender == manager, "Not Manager");
        _;
    }

    event SetManagerFee(uint256 fee);
    event SetCallerFee(uint256 fee);
    event SetMaxSlippage(uint256 slippage);

    function setManagerFee(uint256 value) external onlyManager {
        IReceiptsHolder(ILBPool(vault).receiptsManager()).setManagerFee(value);
        emit SetManagerFee(value);
    }

    function setCallerFee(uint256 value) external onlyManager {
        IReceiptsHolder(ILBPool(vault).receiptsManager()).setCallerFee(value);
        emit SetCallerFee(value);
    }

    function setMaxSlippage(uint256 value) external onlyOwner {
        require(value <= 1000);
        maxSlippage = value;
        emit SetMaxSlippage(value);
    }

    /**
     * @notice Set params of the strategy, only strategist
     * @param _deltaIds see ILBRouter.LiquidityParameters
     * @param _distributionX see ILBRouter.LiquidityParameters
     * @param _distributionY see ILBRouter.LiquidityParameters
     * @param _executeRebalance boolean for the Manager to execute rebalance right after changing the parameters
     * @param respectRatio boolean for the execute rebalance to respect the active bin ratio.
     */
    function setParams(
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY,
        bool _executeRebalance,
        bool respectRatio
    ) external onlyManager {
        _validateParams(_deltaIds, _distributionX, _distributionY);
        distributionX = _distributionX;
        distributionY = _distributionY;
        deltaIds = _deltaIds;
        if (_executeRebalance) {
            executeRebalance(respectRatio);
        }
        emit SetParams(_deltaIds, _distributionX, _distributionY);
    }

    /**
     * @notice Validates the expected liquidity parameters before passing them onto the vault
     * @param _deltaIds see ILBRouter.LiquidityParameters
     * @param _distributionX see ILBRouter.LiquidityParameters
     * @param _distributionY see ILBRouter.LiquidityParameters
     */
    function _validateParams(
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY
    ) public view {
        int256 previousId = _deltaIds[0] - 1;
        uint256 length = _deltaIds.length;
        uint256 sumDistX;
        uint256 sumDistY;
        require(
            length == _distributionX.length && length == _distributionY.length,
            "Incorrect Lengths"
        );
        for (uint256 i; i < length; i++) {
            int256 delta = _deltaIds[i];
            require(delta > previousId, "Not ascending order");
            previousId = delta;
            sumDistX += _distributionX[i];
            sumDistY += _distributionY[i];
        }
        require(_deltaIds[length - 1] - _deltaIds[0] < 50, "Too much bins");
        require(sumDistX <= 10**18, "Bad X distribution");
        require(sumDistY <= 10**18, "Bad Y distribution");
    }

    /**
     * @notice Swaps for the the _for token
     * @dev This needs to have safeguards, as this can be front-run and/or used to manipulate the market
     * @param _for token to swap to
     * @param amountIn amount to swap
     * @param amountOutMin minimum amount to get of the _for token,
     */
    function swap(
        address _for,
        uint256 amountIn,
        uint256 amountOutMin
    ) public onlyManager {
        uint256 minimumExpectedAmount = expectedAmount(_for, amountIn);
        require(amountOutMin >= minimumExpectedAmount, "insufficient amountOutMin");
        ILBPool(vault).swap(_for, amountIn, amountOutMin);
    }

    function expectedAmount(address _for, uint256 amountIn)
        public
        view
        returns (uint256 minimumExpectedAmount)
    {
        uint256 oraclePrice = ILBPool(vault).getOraclePrice();
        minimumExpectedAmount =
            ((
                (_for == tokenX)
                    ? (amountIn * 10**18) / oraclePrice
                    : (amountIn * oraclePrice) / 10**18
            ) * (10000 - maxSlippage)) /
            10000; // 1% slippage max.
    }

    /**
     * @notice Executes rebalance based on the current params.
     * @param respectRatio see trader joe fee based on deposit.
     */
    function executeRebalance(bool respectRatio) public onlyManager {
        ILBPool(vault).executeRebalance(deltaIds, distributionX, distributionY, respectRatio);
    }

    /**
     * @notice Withdraw liquidity from specific bins and adds it back
     * @param binsToWithdraw bins to withdraw from
     * @param amountsToWithdraw amount of receipt token to burn
     * @param respectRatio In order to avoid fees when depositing in the active bin, strategist can indicate to respect the ratio
     */
    function rebalanceWithCustomWithdrawal(
        uint256[] calldata binsToWithdraw,
        uint256[] calldata amountsToWithdraw,
        bool respectRatio
    ) external onlyManager {
        ILBPool(vault).withdrawLiquidityFromBins(binsToWithdraw, amountsToWithdraw);
        ILBPool(vault).addAllLiquidity(deltaIds, distributionX, distributionY, respectRatio);
    }

    /**
     * @notice Rebalances by swapping and without  following the strategy, only available to the strategist
     * @dev the strategist can only deposit in the 50 range bin
     * @param binsToWithdraw bins to withdraw from
     * @param amountsToWithdraw amount of receipt token to burn
     * @param swapAmount amount of the token to swap
     * @param swapToken token to swap for
     * @param _deltaIds see ILBRouter.LiquidityParameters
     * @param _distributionX see ILBRouter.LiquidityParameters
     * @param _distributionY see ILBRouter.LiquidityParameters
     * @param respectRatio In order to avoid fees when depositing in the active bin, strategist can indicate to respect the ratio
     */
    function customRebalance(
        uint256[] memory binsToWithdraw,
        uint256[] memory amountsToWithdraw,
        uint256 swapAmount,
        uint256 amountOutMin,
        address swapToken,
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY,
        bool respectRatio
    ) external onlyManager {
        _validateParams(_deltaIds, _distributionX, _distributionY);
        ILBPool(vault).withdrawLiquidityFromBins(binsToWithdraw, amountsToWithdraw);
        uint256 minimumExpectedAmount = expectedAmount(swapToken, swapAmount);
        require(amountOutMin >= minimumExpectedAmount, "amountOutMin < minimumExpectedAmount");
        ILBPool(vault).swap(swapToken, swapAmount, amountOutMin);
        ILBPool(vault).addLiquidity(
            IERC20(tokenX).balanceOf(vault),
            IERC20(tokenY).balanceOf(vault),
            _deltaIds,
            _distributionX,
            _distributionY,
            respectRatio
        );
    }

    /**
     * @notice Withdraw all liquidity of the vault, only strategist
     */
    function withdrawAllLiquidity() public onlyManager {
        ILBPool(vault).withdrawAllLiquidity();
    }

    /**
     * @notice Withdraw amount X and amount Y of each token
     * @param amountX amount of token X to withdraw
     * @param amountY amount of token Y to withdraw
     */
    function withdrawLiquidity(uint256 amountX, uint256 amountY) public onlyManager {
        ILBPool(vault).withdrawLiquidity(amountX, amountY);
    }

    /**
     * @notice Withdraw liquidity from specific bins
     * @param ids bins to withdraw from
     * @param amounts amount of receipt token to burn
     */
    function withdrawLiquidityFromBins(uint256[] calldata ids, uint256[] calldata amounts)
        public
        onlyManager
    {
        ILBPool(vault).withdrawLiquidityFromBins(ids, amounts);
    }

    /**
     * @notice Add Liquidity following the strategy, only available to the strategist
     * @dev the strategist can only deposit in the 50 range bin
     * @param amountX see ILBRouter.LiquidityParameters
     * @param amountY see ILBRouter.LiquidityParameters
     * @param respectRatio In order to avoid fees when depositing in the active bin, strategist can indicate to respect the ratio
     */
    function addLiquidity(
        uint256 amountX,
        uint256 amountY,
        bool respectRatio
    ) public onlyManager {
        ILBPool(vault).addLiquidity(
            amountX,
            amountY,
            deltaIds,
            distributionX,
            distributionY,
            respectRatio
        );
    }

    /**
     * @notice Add all liquidity based on the current strategy, only available to the strategist
     * @param respectRatio In order to avoid fees when depositing in the active bin, strategist can indicate to respect the ratio
     */
    function addAllLiquidity(bool respectRatio) external onlyManager {
        ILBPool(vault).addAllLiquidity(deltaIds, distributionX, distributionY, respectRatio);
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
    function addLiquidityWithCustomParams(
        uint256 amountX,
        uint256 amountY,
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY,
        bool respectRatio
    ) public onlyManager {
        _validateParams(_deltaIds, _distributionX, _distributionY);
        ILBPool(vault).addLiquidity(
            amountX,
            amountY,
            _deltaIds,
            _distributionX,
            _distributionY,
            respectRatio
        );
    }
}
