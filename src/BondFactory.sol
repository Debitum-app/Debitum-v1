// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones}                        from "@openzeppelin/contracts/proxy/Clones.sol";
import {AccessControlUpgradeable}      from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable}                 from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable}    from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import {IBondFactory}  from "./interfaces/IBondFactory.sol";
import {IBondContract} from "./interfaces/IBondContract.sol";

interface IBondNFTRegister { function registerBond(address bondContract) external; }

/// @notice Immutable factory — modules and bond implementation cannot be changed after deploy.
///         A new factory version means a new deployment, not an upgrade.
///         Only protocolFeeBps and feeCollector are mutable (admin-only), as they
///         only affect bonds created after the change and do not touch existing users.
contract BondFactory is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, IBondFactory {
    using Clones for address;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint256 public constant MAX_FEE_BPS = 500;

    address public bondImplementation;
    address public vestingModule;
    address public bondNFT;
    address public tokenGate;
    address public feeCollector;
    uint256 public protocolFeeBps;

    address[] private _allBonds;
    mapping(address => bool)      public isBond;
    mapping(address => address[]) private _bondsByCreator;

    constructor() { _disableInitializers(); }

    function initialize(
        address admin_,
        address impl_,
        address vestingModule_,
        address bondNFT_,
        address tokenGate_,
        address feeCollector_,
        uint256 feeBps_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        if (admin_ == address(0) || impl_ == address(0) || vestingModule_ == address(0) ||
            bondNFT_ == address(0) || tokenGate_ == address(0) || feeCollector_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE,         admin_);
        bondImplementation = impl_;
        vestingModule      = vestingModule_;
        bondNFT            = bondNFT_;
        tokenGate          = tokenGate_;
        feeCollector       = feeCollector_;
        protocolFeeBps     = feeBps_;
    }

    function createBond(BondParams calldata params, address[] calldata whitelist) external nonReentrant returns (address bond) {
        if (params.principalToken == address(0))                             revert ZeroAddress();
        if (params.capacityInPrincipal == 0)                                 revert InvalidCapacity();
        if (params.discountBps >= 10_000)                                    revert InvalidDiscount();
        if (params.isOTC && whitelist.length == 0)                           revert OTCWhitelistRequired();
        if (params.minPurchasePrincipal > params.maxPurchasePrincipal)       revert InvalidCapacity();
        if (params.maxPurchasePrincipal > params.capacityInPrincipal)        revert InvalidCapacity();
        if (params.priceFeed == address(0) && params.pricePerPrincipal == 0) revert InvalidPrice();

        bond = bondImplementation.clone();
        IBondContract(bond).initialize(params, msg.sender, whitelist, vestingModule, bondNFT, tokenGate, feeCollector, protocolFeeBps);
        IBondNFTRegister(bondNFT).registerBond(bond);

        uint256 index = _allBonds.length;
        _allBonds.push(bond);
        isBond[bond] = true;
        _bondsByCreator[msg.sender].push(bond);
        emit BondCreated(bond, msg.sender, index);
    }

    function bondCount() external view returns (uint256) { return _allBonds.length; }
    function allBonds(uint256 i) external view returns (address) { return _allBonds[i]; }
    function bondsByCreator(address c) external view returns (address[] memory) { return _bondsByCreator[c]; }

    // ── Admin — only affects bonds created after these calls, never existing users ──

    function setProtocolFee(uint256 newFeeBps) external onlyRole(ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit ProtocolFeeUpdated(protocolFeeBps, newFeeBps);
        protocolFeeBps = newFeeBps;
    }

    function setFeeCollector(address newCollector) external onlyRole(ADMIN_ROLE) {
        if (newCollector == address(0)) revert ZeroAddress();
        emit FeeCollectorUpdated(feeCollector, newCollector);
        feeCollector = newCollector;
    }
}
