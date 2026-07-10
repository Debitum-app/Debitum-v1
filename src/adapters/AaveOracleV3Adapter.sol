// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAaveStylePriceOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

/// @title  AaveOracleV3Adapter
/// @notice Adapts an Aave-style `getAssetPrice(asset)` oracle to the Chainlink
///         `AggregatorV3Interface` that Debitum's BondFactory/BondContract consume
///         (`decimals()` + `latestRoundData()`).
/// @dev    ⚠️ SECURITY: the Aave `getAssetPrice` interface exposes NO update
///         timestamp, so `updatedAt` is reported as `block.timestamp`. This makes
///         the consuming bond's staleness (StaleOracle) check a no-op for this
///         feed — the price is always treated as fresh. Only use with a source you
///         trust to keep prices current. Reverts if the source returns 0.
contract AaveOracleV3Adapter {
    IAaveStylePriceOracle public immutable source;
    address public immutable asset;
    uint8   private immutable _decimals;
    string  private _description;

    error ZeroPrice();

    constructor(address source_, address asset_, uint8 decimals_, string memory description_) {
        source       = IAaveStylePriceOracle(source_);
        asset        = asset_;
        _decimals    = decimals_;
        _description = description_;
    }

    function decimals() external view returns (uint8) { return _decimals; }
    function description() external view returns (string memory) { return _description; }
    function version() external pure returns (uint256) { return 1; }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint256 price = source.getAssetPrice(asset);
        if (price == 0) revert ZeroPrice();
        return (1, int256(price), block.timestamp, block.timestamp, 1);
    }
}
