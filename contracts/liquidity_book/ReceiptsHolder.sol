// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "@openzeppelinUpgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelinUpgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelinUpgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelinUpgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";

import "./../../interfaces/ILBPair.sol";
import "./../../interfaces/ILBRouter.sol";
import "./../../interfaces/ILBToken.sol";
import "./../../interfaces/IOracleHelper.sol";
import "./../../interfaces/IStrategy.sol";
import "./../../interfaces/IViewHelper.sol";
import "./../../interfaces/ILBPool.sol";

contract ReceiptsHolder is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    address public vault;

    IERC20 public tokenX;
    IERC20 public tokenY;
    uint256 public binStep;

    address public strategy;
    uint256 public MANAGER_FEE;

    address public protocolFeeRecipient;
    uint256 public PROTOCOL_FEE;

    uint256 public CALLER_FEE;
    uint256 public constant PRECISION = 10000;

    ILBRouter public router;
    ILBPair public pair;
    ILBToken public receiptToken;
    IViewHelper public viewHelper;

    event Harvest(address indexed user, uint256 amountX, uint256 amountY);
    event FeeDistributed(address indexed user, uint256 amount, IERC20 token);

    function __ReceiptsHolder_init(
        address _vault,
        address _tokenX,
        address _tokenY,
        uint256 _binStep,
        address _router,
        address _pair,
        address _viewHelper
    ) external initializer {
        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        vault = _vault;
        router = ILBRouter(_router);
        tokenX = IERC20(_tokenX);
        tokenY = IERC20(_tokenY);
        binStep = _binStep;
        pair = ILBPair(_pair);
        _approveTokenIfNeeded(tokenX, _router);
        _approveTokenIfNeeded(tokenY, _router);
        receiptToken = ILBToken(_pair);
        receiptToken.setApprovalForAll(_router, true);
        viewHelper = IViewHelper(_viewHelper);
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    modifier onlyStrategy() {
        require(msg.sender == strategy, "Only strategy");
        _;
    }
    event SetStrategy(address);

    function setStrategy(address _strategy) external onlyOwner {
        strategy = _strategy;
        emit SetStrategy(_strategy);
    }

    event SetProtocolFee(uint256);

    function setProtocolFee(uint256 _value) external onlyOwner {
        PROTOCOL_FEE = _value;
        emit SetProtocolFee(_value);
    }

    event SetProtocolFeeRecipient(address);

    function setProtocolFeeRecipient(address _value) external onlyOwner {
        protocolFeeRecipient = _value;
        emit SetProtocolFeeRecipient(_value);
    }

    function setCallerFee(uint256 _value) external onlyStrategy {
        require(_value < 500, "Too high");
        CALLER_FEE = _value;
    }

    function setManagerFee(uint256 _value) external onlyStrategy {
        require(_value < 2000, "Too high");
        MANAGER_FEE = _value;
    }

    function _approveTokenIfNeeded(IERC20 token, address to) private {
        if (token.allowance(address(this), to) == 0) {
            token.safeApprove(to, type(uint256).max);
        }
    }

    function addLiquidity(ILBRouter.LiquidityParameters memory parameters)
        public
        onlyVault
        returns (uint256[] memory depositIds)
    {
        uint256 balanceX = tokenX.balanceOf(address(this));
        uint256 balanceY = tokenY.balanceOf(address(this));
        (depositIds, ) = router.addLiquidity(parameters);
        tokenX.safeTransfer(vault, _diffOrZero(tokenX.balanceOf(address(this)), balanceX));
        tokenY.safeTransfer(vault, _diffOrZero(tokenY.balanceOf(address(this)), balanceY));
    }

    function getReserveForBin(uint256 bin)
        public
        view
        returns (
            uint256 reserveX,
            uint256 reserveY,
            uint256 receiptBalance
        )
    {
        return viewHelper.getReserveForBin(address(pair), bin, address(this));
    }

    function _diffOrZero(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function removeLiquidity(uint256[] memory ids, uint256[] memory amounts) external onlyVault {
        uint256 balanceX = tokenX.balanceOf(address(this));
        uint256 balanceY = tokenY.balanceOf(address(this));
        router.removeLiquidity(
            address(tokenX),
            address(tokenY),
            uint16(binStep),
            0,
            0,
            ids,
            amounts,
            address(this),
            block.timestamp
        );
        tokenX.safeTransfer(vault, tokenX.balanceOf(address(this)) - balanceX);
        tokenY.safeTransfer(vault, tokenY.balanceOf(address(this)) - balanceY);
    }

    function harvest(uint256[] memory depositedBins, address caller) external onlyVault {
        pair.collectFees(address(this), depositedBins);

        uint256 XCollected = tokenX.balanceOf(address(this));
        uint256 YCollected = tokenY.balanceOf(address(this));

        emit Harvest(msg.sender, XCollected, YCollected);
        if (XCollected > 0) {
            _handleFee(tokenX, XCollected, caller);
        }
        if (YCollected > 0) {
            _handleFee(tokenY, YCollected, caller);
        }
    }

    function _handleFee(
        IERC20 token,
        uint256 collectedAmount,
        address caller
    ) internal {
        uint256 callerFee = (collectedAmount * CALLER_FEE) / PRECISION;
        uint256 managerFee = (collectedAmount * MANAGER_FEE) / PRECISION;
        uint256 protocolFee = (collectedAmount * PROTOCOL_FEE) / PRECISION;
        if (callerFee > 0) {
            token.safeTransfer(caller, callerFee);
            emit FeeDistributed(caller, callerFee, token);
        }
        if (managerFee > 0) {
            token.safeTransfer(IStrategy(strategy).manager(), managerFee);
            emit FeeDistributed(IStrategy(strategy).manager(), managerFee, token);
        }
        if (protocolFee > 0) {
            token.safeTransfer(protocolFeeRecipient, protocolFee);
            emit FeeDistributed(protocolFeeRecipient, protocolFee, token);
        }
        uint256 remainingBalance = token.balanceOf(address(this));
        token.safeTransfer(vault, remainingBalance);
        emit FeeDistributed(vault, remainingBalance, token);
    }
}
