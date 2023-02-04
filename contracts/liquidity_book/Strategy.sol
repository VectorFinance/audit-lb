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

    function __Strategy_init_(
        address _tokenX,
        address _tokenY,
        uint256 _binStep,
        address _vault
    ) external initializer {
        __Ownable_init();
        __Pausable_init();
        tokenX = _tokenX;
        tokenY = _tokenY;
        binStep = _binStep;
        vault = _vault;
    }

    function setManager(address newManager) external onlyOwner {
        manager = newManager;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "Not Manager");
        _;
    }

    function setManagerFee(uint256 value) external onlyManager {
        ILBPool(vault).setManagerFee(value);
    }

    function setCallerFee(uint256 value) external onlyManager {
        ILBPool(vault).setCallerFee(value);
    }

    /**
     * @notice Set params of the strategy, only strategist
     * @param _deltaIds see ILBRouter.LiquidityParameters
     * @param _distributionX see ILBRouter.LiquidityParameters
     * @param _distributionY see ILBRouter.LiquidityParameters
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
    }

    function _validateParams(
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY
    ) public view {
        int256 minDelta;
        int256 maxDelta;
        uint256 length = _deltaIds.length;
        uint256 sumDistX;
        uint256 sumDistY;
        require(
            length == _distributionX.length && length == _distributionY.length,
            "Incorrect Lengths"
        );
        for (uint256 i; i < length; i++) {
            int256 delta = _deltaIds[i];
            if (delta < minDelta) {
                minDelta = delta;
            } else if (delta > maxDelta) {
                maxDelta = delta;
            }
            sumDistX += _distributionX[i];
            sumDistY += _distributionY[i];
        }
        require(maxDelta - minDelta < 50, "Too much bins");
        require(sumDistX <= 10**18, "Bad X distribution");
        require(sumDistY <= 10**18, "Bad Y distribution");
    }

    /**
     * @notice Add Liquidity following the strategy, only available to the strategist
     * @dev This needs to have safeguards, as this can be front-run and/or used to manipulate the market
     * @param _for token to swap to
     * @param amountIn amount to swap
     * @param amountOutMin minimum amount to get of the _for token
     */
    function swap(
        address _for,
        uint256 amountIn,
        uint256 amountOutMin
    ) public onlyManager {
        ILBPool(vault).swap(_for, amountIn, amountOutMin);
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
     * @param swapToken token to swap
     * @param _deltaIds see ILBRouter.LiquidityParameters
     * @param _distributionX see ILBRouter.LiquidityParameters
     * @param _distributionY see ILBRouter.LiquidityParameters
     * @param respectRatio In order to avoid fees when depositing in the active bin, strategist can indicate to respect the ratio
     */
    function customRebalance(
        uint256[] memory binsToWithdraw,
        uint256[] memory amountsToWithdraw,
        uint256 swapAmount,
        address swapToken,
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY,
        bool respectRatio
    ) external onlyManager {
        _validateParams(_deltaIds, _distributionX, _distributionY);
        ILBPool(vault).withdrawLiquidityFromBins(binsToWithdraw, amountsToWithdraw);
        ILBPool(vault).swap(swapToken, swapAmount, 0);
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
