// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

interface IStrategy {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);

    function __Strategy_init_(
        address _tokenX,
        address _tokenY,
        uint256 _binStep,
        address _vault
    ) external;

    function _validateParams(
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY
    ) external view;

    function addAllLiquidity(bool respectRatio) external;

    function addLiquidity(
        uint256 amountX,
        uint256 amountY,
        bool respectRatio
    ) external;

    function addLiquidityWithCustomParams(
        uint256 amountX,
        uint256 amountY,
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY,
        bool respectRatio
    ) external;

    function binStep() external view returns (uint256);

    function customRebalance(
        uint256[] calldata binsToWithdraw,
        uint256[] calldata amountsToWithdraw,
        uint256 swapAmount,
        address swapToken,
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY,
        bool respectRatio
    ) external;

    function deltaIds(uint256) external view returns (int256);

    function distributionX(uint256) external view returns (uint256);

    function distributionY(uint256) external view returns (uint256);

    function executeRebalance(bool respectRatio) external;

    function manager() external view returns (address);

    function owner() external view returns (address);

    function paused() external view returns (bool);

    function rebalanceWithCustomWithdrawal(
        uint256[] calldata binsToWithdraw,
        uint256[] calldata amountsToWithdraw,
        bool respectRatio
    ) external;

    function renounceOwnership() external;

    function setCallerFee(uint256 value) external;

    function setManager(address newManager) external;

    function setManagerFee(uint256 value) external;

    function setParams(
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY,
        bool _executeRebalance,
        bool respectRatio
    ) external;

    function swap(
        address _for,
        uint256 amountIn,
        uint256 amountOutMin
    ) external;

    function tokenX() external view returns (address);

    function tokenY() external view returns (address);

    function transferOwnership(address newOwner) external;

    function vault() external view returns (address);

    function withdrawAllLiquidity() external;

    function withdrawLiquidity(uint256 amountX, uint256 amountY) external;

    function withdrawLiquidityFromBins(uint256[] calldata ids, uint256[] calldata amounts) external;
}
