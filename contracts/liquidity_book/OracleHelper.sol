// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract OracleHelper is Ownable {
    uint8 public constant OUTPUT_DECIMALS = 18;
    mapping(address => AggregatorV3Interface) public tokenToFeed;
    mapping(address => bool) public isStable;

    function setFeedForToken(address token, address feed) external onlyOwner {
        tokenToFeed[token] = AggregatorV3Interface(feed);
    }

    function setIsStable(address token, bool state) external onlyOwner {
        isStable[token] = state;
    }

    function getPrice(address token) public view returns (uint256) {
        AggregatorV3Interface feed = tokenToFeed[token];
        if (isStable[token] && address(feed) == address(0)) {
            return 10**OUTPUT_DECIMALS;
        }
        require(address(feed) != address(0), "invalid token");
        (, int256 price, , , ) = feed.latestRoundData();
        return uint256(price) * 10**(OUTPUT_DECIMALS - feed.decimals());
    }

    function getPriceOfXInYUnits(address tokenX, address tokenY) external view returns (uint256) {
        uint256 priceXInUsd = getPrice(tokenX);
        uint256 priceYInUsd = getPrice(tokenY);
        return (priceXInUsd * 10**OUTPUT_DECIMALS) / priceYInUsd;
    }
}
