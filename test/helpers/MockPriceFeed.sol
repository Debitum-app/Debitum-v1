// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockPriceFeed {
    uint8   public decimals;
    int256  public answer;
    uint256 public updatedAt;
    bool    public shouldRevert;

    constructor(uint8 dec, int256 ans) {
        decimals  = dec;
        answer    = ans;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 ans) external { answer = ans; }
    function setUpdatedAt(uint256 ts) external { updatedAt = ts; }
    function setShouldRevert(bool v) external { shouldRevert = v; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!shouldRevert, "feed: revert");
        return (1, answer, block.timestamp, updatedAt, 1);
    }
}

/// @notice Feed that reverts on latestRoundData — simulates a broken oracle.
contract BrokenPriceFeed {
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("broken feed");
    }
}

/// @notice Feed with no decimals function — not a valid Chainlink feed.
contract NodecimalsFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}
