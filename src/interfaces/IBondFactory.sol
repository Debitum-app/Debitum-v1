// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBondFactory {
    struct BondParams {
        address paymentToken;
        address principalToken;
        uint128 capacityInPrincipal;
        uint128 pricePerPrincipal;
        uint16  discountBps;
        uint128 minPurchasePrincipal;
        uint128 maxPurchasePrincipal;
        uint8   vestingType;
        bytes   vestingParams;
        address[] gateTokens;
        bytes   gateConfig;
        bool    isOTC;
        bool    depositPrincipal;
        address priceFeed;
        uint32  maxPriceAge;
    }
    event BondCreated(address indexed bond, address indexed creator, uint256 index);
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeCollectorUpdated(address oldCollector, address newCollector);
    error ZeroAddress();
    error FeeTooHigh();
    error InvalidDiscount();
    error InvalidCapacity();
    error InvalidPrice();
    error OTCWhitelistRequired();
    function createBond(BondParams calldata params, address[] calldata whitelist) external returns (address bond);
    function bondCount() external view returns (uint256);
    function allBonds(uint256 index) external view returns (address);
    function isBond(address addr) external view returns (bool);
    function bondsByCreator(address creator) external view returns (address[] memory);
    function protocolFeeBps() external view returns (uint256);
    function feeCollector() external view returns (address);
    function bondImplementation() external view returns (address);
}
