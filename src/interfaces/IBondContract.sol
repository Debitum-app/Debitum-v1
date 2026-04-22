// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IBondFactory} from "./IBondFactory.sol";
interface IBondContract {
    struct BondConfig {
        address creator;
        address paymentToken;
        address principalToken;
        uint128 capacityInPrincipal;
        uint128 pricePerPrincipal;
        uint16  discountBps;
        uint128 minPurchasePrincipal;
        uint128 maxPurchasePrincipal;
        uint8   vestingType;
        bool    isOTC;
        bool    depositPrincipal;
        address priceFeed;
        uint32  maxPriceAge;
    }
    struct BondState { uint128 totalSold; bool paused; bool closed; }
    event BondPurchased(address indexed buyer, uint256 paymentAmount, uint256 principalAmount, uint256 discountBps, uint256 indexed tokenId);
    event PauseToggled(bool paused);
    event BondClosed();
    event EscrowDeposited(address indexed creator, uint256 amount);
    event EscrowWithdrawn(address to, uint256 amount);
    event WhitelistUpdated(address indexed account, bool added);
    event ETHWithdrawn(address indexed to, uint256 amount);
    event FeeCollected(address indexed to, uint256 amount);
    error ZeroAddress();
    error NotCreator(); error NotWhitelisted(); error BondPaused(); error BondIsClosed();
    error BondSoldOut(); error BelowMinPurchase(); error ExceedsMaxPurchase(); error ExceedsCapacity();
    error SlippageExceeded();
    error InvalidAmount();
    error BondNotClosed(); error StaleOracle(); error OracleUnavailable(); error InvalidPaymentAmount();
    error EscrowAlreadyDeposited(); error EscrowNotDeposited(); error InsufficientPrincipalBalance(); error InvalidPrice();
    function initialize(IBondFactory.BondParams calldata params, address creator, address[] calldata whitelist, address vestingModule, address bondNFT, address tokenGate, address feeCollector, uint256 protocolFeeBps) external;
    function purchase(uint256 paymentAmount, uint256 minPrincipal) external returns (uint256);
    function purchaseWithETH(uint256 minPrincipal) external payable returns (uint256);
    function purchaseWithProof(uint256 paymentAmount, uint256 minPrincipal, bytes32[] calldata proof, uint128 allocation) external returns (uint256);
    function purchaseWithETHAndProof(uint256 minPrincipal, bytes32[] calldata proof, uint128 allocation) external payable returns (uint256);
    function depositEscrow() external;
    function withdrawEscrow() external;
    function withdrawETH() external;
    function collectFee() external;
    function setPaused(bool paused) external;
    function closeBond() external;
    function addToWhitelist(address[] calldata accounts) external;
    function removeFromWhitelist(address[] calldata accounts) external;
    function config() external view returns (BondConfig memory);
    function state() external view returns (BondState memory);
    function previewPurchase(address buyer, uint256 paymentAmount) external view returns (uint256, uint256);
    function remainingCapacity() external view returns (uint256);
    function isWhitelisted(address account) external view returns (bool);
    function purchasedByWallet(address wallet) external view returns (uint128);
    function vestingParams() external view returns (bytes memory);
    function currentPrice() external view returns (uint256);
    function pendingETH() external view returns (uint256);
    function pendingFee() external view returns (uint256);
}
