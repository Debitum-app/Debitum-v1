// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20}                     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}                  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBondFactory}   from "./interfaces/IBondFactory.sol";
import {IBondContract}  from "./interfaces/IBondContract.sol";
import {IVestingModule} from "./interfaces/IModules.sol";
import {IBondNFT}       from "./interfaces/IModules.sol";
import {ITokenGate}     from "./interfaces/IModules.sol";

interface IPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract BondContract is Initializable, ReentrancyGuardUpgradeable, IBondContract {
    using SafeERC20 for IERC20;

    uint32 private constant DEFAULT_MAX_PRICE_AGE = 3600;

    BondConfig private _config;
    bytes      private _vestingParams;

    uint256 public protocolFeeBps;
    address public feeCollector;

    IVestingModule public vestingModule;
    IBondNFT       public bondNFT;
    ITokenGate     public tokenGate;

    BondState private _state;
    uint256   private _pendingETH;
    uint256   private _pendingFee;

    bool    public escrowDeposited;
    mapping(address => bool)    public whitelist;
    // Note: purchasedByWallet is bond-lifetime, not per-NFT — intentional by design.
    // Selling an NFT does not reset the wallet's purchase limit for this bond.
    mapping(address => uint128) public purchasedByWallet;

    modifier onlyCreator() { if (msg.sender != _config.creator) revert NotCreator(); _; }
    modifier bondActive()  { if (_state.paused) revert BondPaused(); if (_state.closed) revert BondIsClosed(); _; }

    constructor() { _disableInitializers(); }

    function initialize(
        IBondFactory.BondParams calldata params,
        address creator,
        address[] calldata whitelist_,
        address vestingModule_,
        address bondNFT_,
        address tokenGate_,
        address feeCollector_,
        uint256 protocolFeeBps_
    ) external initializer {
        if (creator      == address(0) || vestingModule_ == address(0) ||
            bondNFT_     == address(0) || tokenGate_     == address(0) ||
            feeCollector_ == address(0)) revert ZeroAddress();
        __ReentrancyGuard_init();
        _config = BondConfig({
            creator:              creator,
            paymentToken:         params.paymentToken,
            principalToken:       params.principalToken,
            capacityInPrincipal:  params.capacityInPrincipal,
            pricePerPrincipal:    params.pricePerPrincipal,
            discountBps:          params.discountBps,
            minPurchasePrincipal: params.minPurchasePrincipal,
            maxPurchasePrincipal: params.maxPurchasePrincipal,
            vestingType:          params.vestingType,
            isOTC:                params.isOTC,
            depositPrincipal:     params.depositPrincipal,
            priceFeed:            params.priceFeed,
            maxPriceAge:          params.maxPriceAge == 0 ? DEFAULT_MAX_PRICE_AGE : params.maxPriceAge
        });
        _vestingParams = params.vestingParams;
        vestingModule  = IVestingModule(vestingModule_);
        bondNFT        = IBondNFT(bondNFT_);
        tokenGate      = ITokenGate(tokenGate_);
        feeCollector   = feeCollector_;
        protocolFeeBps = protocolFeeBps_;
        for (uint256 i = 0; i < whitelist_.length;) { whitelist[whitelist_[i]] = true; unchecked { ++i; } }
        // Pre-approve bondNFT once so claims never need an inline cross-contract call.
        // Safe: bondNFT is a trusted immutable module set by the factory.
        IERC20(params.principalToken).approve(bondNFT_, type(uint256).max);
    }

    function currentPrice() public view returns (uint256 price18) {
        BondConfig memory cfg = _config;
        if (cfg.priceFeed == address(0)) {
            uint8 payDec = _paymentDecimals(cfg.paymentToken);
            if (payDec < 18)      return cfg.pricePerPrincipal * (10 ** (18 - payDec));
            else if (payDec > 18) return cfg.pricePerPrincipal / (10 ** (payDec - 18));
            else                  return cfg.pricePerPrincipal;
        }
        IPriceFeed feed = IPriceFeed(cfg.priceFeed);
        (, int256 answer, , uint256 updatedAt,) = feed.latestRoundData();
        if (block.timestamp - updatedAt > cfg.maxPriceAge) revert StaleOracle();
        if (answer <= 0) revert OracleUnavailable();
        uint8 dec = feed.decimals();
        if (dec < 18)      price18 = uint256(answer) * (10 ** (18 - dec));
        else if (dec > 18) price18 = uint256(answer) / (10 ** (dec - 18));
        else               price18 = uint256(answer);
    }

    function purchase(uint256 paymentAmount, uint256 minPrincipal) external nonReentrant bondActive returns (uint256) {
        BondConfig memory cfg = _config;
        if (cfg.paymentToken == address(0)) revert InvalidPaymentAmount();
        if (paymentAmount == 0)             revert InvalidPaymentAmount();
        return _purchase(cfg, msg.sender, paymentAmount, minPrincipal, new bytes32[](0), 0);
    }

    function purchaseWithETH(uint256 minPrincipal) external payable nonReentrant bondActive returns (uint256) {
        BondConfig memory cfg = _config;
        if (cfg.paymentToken != address(0)) revert InvalidPaymentAmount();
        if (msg.value == 0)                 revert InvalidPaymentAmount();
        return _purchase(cfg, msg.sender, msg.value, minPrincipal, new bytes32[](0), 0);
    }

    function purchaseWithProof(
        uint256 paymentAmount,
        uint256 minPrincipal,
        bytes32[] calldata proof,
        uint128 allocation
    ) external nonReentrant bondActive returns (uint256) {
        BondConfig memory cfg = _config;
        if (cfg.paymentToken == address(0)) revert InvalidPaymentAmount();
        if (paymentAmount == 0)             revert InvalidPaymentAmount();
        return _purchase(cfg, msg.sender, paymentAmount, minPrincipal, proof, allocation);
    }

    function purchaseWithETHAndProof(
        uint256 minPrincipal,
        bytes32[] calldata proof,
        uint128 allocation
    ) external payable nonReentrant bondActive returns (uint256) {
        BondConfig memory cfg = _config;
        if (cfg.paymentToken != address(0)) revert InvalidPaymentAmount();
        if (msg.value == 0)                 revert InvalidPaymentAmount();
        return _purchase(cfg, msg.sender, msg.value, minPrincipal, proof, allocation);
    }

    function _purchase(
        BondConfig memory cfg,
        address buyer,
        uint256 paymentAmount,
        uint256 minPrincipal,
        bytes32[] memory proof,
        uint128 allocation
    ) internal returns (uint256 tokenId) {
        if (cfg.isOTC && !whitelist[buyer])           revert NotWhitelisted();
        if (cfg.depositPrincipal && !escrowDeposited) revert EscrowNotDeposited();

        (uint256 principalAmount, uint256 effectiveDiscountBps) = _computePrincipal(cfg, buyer, paymentAmount, proof, allocation);

        if (principalAmount < minPrincipal)             revert SlippageExceeded();
        if (principalAmount < cfg.minPurchasePrincipal) revert BelowMinPurchase();
        if (principalAmount > type(uint128).max)        revert InvalidAmount();

        uint128 walletTotal  = purchasedByWallet[buyer] + uint128(principalAmount);
        if (walletTotal > cfg.maxPurchasePrincipal)     revert ExceedsMaxPurchase();

        uint128 newTotalSold = _state.totalSold + uint128(principalAmount);
        if (newTotalSold > cfg.capacityInPrincipal)     revert ExceedsCapacity();

        _state.totalSold         = newTotalSold;
        purchasedByWallet[buyer] = walletTotal;

        if (newTotalSold == cfg.capacityInPrincipal) { _state.closed = true; emit BondClosed(); }

        uint256 fee            = paymentAmount * protocolFeeBps / 10_000;
        uint256 creatorPayment = paymentAmount - fee;

        if (cfg.paymentToken == address(0)) {
            // Pull pattern for both creator and fee — avoids push-to-contract DoS
            _pendingETH += creatorPayment;
            _pendingFee += fee;
        } else {
            IERC20 pt = IERC20(cfg.paymentToken);
            if (fee > 0) pt.safeTransferFrom(buyer, feeCollector, fee);
            pt.safeTransferFrom(buyer, cfg.creator, creatorPayment);
        }

        if (!cfg.depositPrincipal) {
            IERC20(cfg.principalToken).safeTransferFrom(cfg.creator, address(this), principalAmount);
        }

        IVestingModule.Schedule memory schedule = vestingModule.buildSchedule(
            cfg.vestingType, _vestingParams, uint128(principalAmount), uint64(block.timestamp)
        );
        tokenId = bondNFT.mint(buyer, address(this), schedule, cfg.paymentToken, uint128(paymentAmount));
        emit BondPurchased(buyer, paymentAmount, principalAmount, effectiveDiscountBps, tokenId);
    }

    function _paymentDecimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18;
        try IERC20Decimals(token).decimals() returns (uint8 d) { return d; }
        catch { return 18; }
    }

    function _computePrincipal(
        BondConfig memory cfg,
        address buyer,
        uint256 paymentAmount,
        bytes32[] memory proof,
        uint128 allocation
    ) internal view returns (uint256 principalAmount, uint256 effectiveDiscountBps) {
        uint256 gateDiscountBps = proof.length > 0
            ? tokenGate.getDiscountWithProof(buyer, address(this), proof, allocation)
            : tokenGate.getDiscount(buyer, address(this));

        uint256 basePrice      = currentPrice();
        uint256 effectivePrice = basePrice * (10_000 - cfg.discountBps) * (10_000 - gateDiscountBps) / 1e8;
        if (effectivePrice == 0) revert InvalidPrice();

        uint8 payDec = _paymentDecimals(cfg.paymentToken);
        uint256 paymentAmount18 = payDec < 18
            ? paymentAmount * (10 ** (18 - payDec))
            : payDec > 18
                ? paymentAmount / (10 ** (payDec - 18))
                : paymentAmount;

        principalAmount      = paymentAmount18 * 1e18 / effectivePrice;
        effectiveDiscountBps = 10_000 - (effectivePrice * 10_000 / basePrice);
    }

    function previewPurchase(address buyer, uint256 paymentAmount) external view returns (uint256, uint256) {
        if (paymentAmount == 0) return (0, 0);
        return _computePrincipal(_config, buyer, paymentAmount, new bytes32[](0), 0);
    }

    function depositEscrow() external nonReentrant onlyCreator {
        BondConfig memory cfg = _config;
        if (!cfg.depositPrincipal) revert EscrowNotDeposited();
        if (escrowDeposited)       revert EscrowAlreadyDeposited();
        escrowDeposited = true;
        IERC20(cfg.principalToken).safeTransferFrom(msg.sender, address(this), cfg.capacityInPrincipal);
        emit EscrowDeposited(msg.sender, cfg.capacityInPrincipal);
    }

    function withdrawETH() external nonReentrant onlyCreator {
        uint256 amount = _pendingETH;
        if (amount == 0) revert InvalidAmount();
        _pendingETH = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit ETHWithdrawn(msg.sender, amount);
    }

    function collectFee() external nonReentrant {
        uint256 amount = _pendingFee;
        if (amount == 0) revert InvalidAmount();
        _pendingFee = 0;
        (bool ok,) = feeCollector.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit FeeCollected(feeCollector, amount);
    }

    function withdrawEscrow() external nonReentrant onlyCreator {
        BondConfig memory cfg = _config;
        if (!cfg.depositPrincipal) revert EscrowNotDeposited();
        if (!escrowDeposited)      revert EscrowNotDeposited();
        if (!_state.closed)        revert BondNotClosed();
        uint256 unsold = cfg.capacityInPrincipal - _state.totalSold;
        if (unsold == 0) return;
        IERC20(cfg.principalToken).safeTransfer(cfg.creator, unsold);
        emit EscrowWithdrawn(cfg.creator, unsold);
    }

    function setPaused(bool p) external onlyCreator { _state.paused = p; emit PauseToggled(p); }
    function closeBond()       external onlyCreator { _state.closed = true; emit BondClosed(); }

    function addToWhitelist(address[] calldata a) external onlyCreator {
        for (uint i; i < a.length;) { whitelist[a[i]] = true; emit WhitelistUpdated(a[i], true); unchecked { ++i; } }
    }
    function removeFromWhitelist(address[] calldata a) external onlyCreator {
        for (uint i; i < a.length;) { whitelist[a[i]] = false; emit WhitelistUpdated(a[i], false); unchecked { ++i; } }
    }

    function config()            external view returns (BondConfig memory) { return _config; }
    function state()             external view returns (BondState memory)  { return _state; }
    function vestingParams()     external view returns (bytes memory)      { return _vestingParams; }
    function remainingCapacity() external view returns (uint256) { return _config.capacityInPrincipal - _state.totalSold; }
    function isWhitelisted(address a) external view returns (bool) { return _config.isOTC ? whitelist[a] : true; }
    function pendingETH()        external view returns (uint256) { return _pendingETH; }
    function pendingFee()        external view returns (uint256) { return _pendingFee; }
}
