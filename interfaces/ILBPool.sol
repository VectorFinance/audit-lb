// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

interface ILBPool {
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed user, uint256 amountX, uint256 amountY);
    event FeeDistributed(address indexed user, uint256 amount, address token);
    event Harvest(address indexed user, uint256 amountX, uint256 amountY);
    event LiquidityAdded(
        int256[] deltaIds,
        uint256[] distributionX,
        uint256[] distributionY,
        uint256 amountX,
        uint256 amountY
    );
    event LiquidityRemoved(uint256[] ids, uint256[] receiptBalances);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ParamsSet(int256[] _deltaIds, uint256[] _distributionX, uint256[] _distributionY);
    event Paused(address account);
    event Rebalance();
    event SwapToken(
        address inToken,
        uint256 inTokenAmount,
        address outToken,
        uint256 outTokenAmount
    );
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Unpaused(address account);
    event Withdraw(address indexed user, uint256 amountX, uint256 amountY);

    function CALLER_FEE() external view returns (uint256);

    function MANAGER_FEE() external view returns (uint256);

    function PRECISION() external view returns (uint256);

    function PROTOCOL_FEE() external view returns (uint256);

    function __LBPool_init(
        address _tokenX,
        address _tokenY,
        uint256 _binStep,
        address _router,
        address _receipt
    ) external;

    function addAllLiquidity(
        int256[] calldata ids,
        uint256[] calldata distributionX,
        uint256[] calldata distributionY,
        bool respectRatio
    ) external;

    function addLiquidity(
        uint256 amountX,
        uint256 amountY,
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY,
        bool respectRatio
    ) external;

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function binStep() external view returns (uint256);

    function receiptsManager() external view returns (address);

    function checkPrice(uint256 threshold) external view;

    function checkSwapStatus(uint256 amountIn, address _for) external view;

    function receiptsHolder() external view returns (address);

    function computeDistributionToRespectRatio(
        uint256 amountX,
        uint256 amountY,
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY
    )
        external
        view
        returns (
            int256[] memory finalIds,
            uint256[] memory finalDistributionX,
            uint256[] memory finalDistributionY
        );

    function decimals() external view returns (uint8);

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool);

    function deltaIds(uint256) external view returns (int256);

    function deposit(uint256 amountX, uint256 amountY) external;

    function depositFor(
        uint256 amountX,
        uint256 amountY,
        address _for
    ) external;

    function depositThreshold() external view returns (uint256);

    function executeRebalance(
        int256[] calldata ids,
        uint256[] calldata distributionX,
        uint256[] calldata distributionY,
        bool respectRatio
    ) external;

    function factory() external view returns (address);

    function getAllReserves() external view returns (uint256 totalReserveX, uint256 totalReserveY);

    function getBalances() external view returns (uint256 tokenXbalance, uint256 tokenYBalance);

    function getDepositTokensForShares(uint256 amount, uint256 priceX)
        external
        view
        returns (uint256);

    function getDepositTokensXForShares(uint256 amount, uint256 priceX)
        external
        view
        returns (uint256 totalAmount, uint256 totalReserveXAvailable);

    function getDepositTokensYForShares(uint256 amount, uint256 priceX)
        external
        view
        returns (uint256 totalAmount, uint256 totalReserveYAvailable);

    function getDepositedBins() external view returns (uint256[] memory _depositedIds);

    function getHighestAndLowestBin() external view returns (uint256 highestBin, uint256 lowestBin);

    function getMaximumWithdrawalTokenXWithoutSwapping()
        external
        view
        returns (uint256 finalAmountX, uint256 finalAmountY);

    function getMaximumWithdrawalTokenYWithoutSwapping()
        external
        view
        returns (uint256 finalAmountX, uint256 finalAmountY);

    function getOraclePrice() external view returns (uint256 oraclePrice);

    function getPairInfos()
        external
        view
        returns (
            uint256 reservesX,
            uint256 reservesY,
            uint256 activeId
        );

    function getPriceFromActiveBin() external view returns (uint256 price);

    function getReserveForBin(uint256 bin)
        external
        view
        returns (uint256 reserveX, uint256 reserveY);

    function getSharesForDepositTokens(uint256 amount, uint256 priceX)
        external
        view
        returns (uint256);

    function getTotalFunds() external view returns (uint256 totalX, uint256 totalY);

    function getTotalReserveForBin(uint256 bin)
        external
        view
        returns (uint256 pairReserveX, uint256 pairReserveY);

    function harvest(address callerFeeRecipient) external;

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);

    function lastDepositedTime(address) external view returns (uint256);

    function name() external view returns (string memory);

    function oracle() external view returns (address);

    function owner() external view returns (address);

    function pair() external view returns (address);

    function paused() external view returns (bool);

    function pendingRewards(uint256[] calldata ids)
        external
        view
        returns (uint256 rewardsX, uint256 rewardsY);

    function protocolFeeRecipient() external view returns (address);

    function receiptToken() external view returns (address);

    function renounceOwnership() external;

    function reservesOutsideActive()
        external
        view
        returns (uint256 totalReserveX, uint256 totalReserveY);

    function router() external view returns (address);

    function setAddLiquidityThreshold(uint256 _value) external;

    function setCallerFee(uint256 _value) external;

    function setDepositThreshold(uint256 _value) external;

    function setManagerFee(uint256 _value) external;

    function setOracle(address _oracle) external;

    function setProtocolFee(uint256 _value) external;

    function setProtocolFeeRecipient(address _value) external;

    function setStrategy(address _strategy) external;

    function setSwapThreshold(uint256 _value) external;

    function setWithdrawalFee(uint256 delay, uint256 value) external;

    function strategy() external view returns (address);

    function swap(
        address _for,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 amountOut);

    function swapThreshold() external view returns (uint256);

    function symbol() external view returns (string memory);

    function tokenX() external view returns (address);

    function tokenY() external view returns (address);

    function totalSupply() external view returns (uint256);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function transferOwnership(address newOwner) external;

    function withdraw(
        uint256 amountX,
        uint256 amountY,
        bool _harvest
    ) external;

    function withdrawAllLiquidity() external;

    function withdrawLiquidity(uint256 amountX, uint256 amountY) external;

    function withdrawLiquidityFromBins(uint256[] calldata ids, uint256[] calldata amounts) external;

    function withdrawalFee() external view returns (uint256);

    function withdrawalFeeDelay() external view returns (uint256);
}
