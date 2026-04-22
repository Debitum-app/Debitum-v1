// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Upgradeable}         from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC2981Upgradeable}        from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {AccessControlUpgradeable}  from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable}from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Initializable}             from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Metadata}            from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20}                    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}                 from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64}                    from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings}                   from "@openzeppelin/contracts/utils/Strings.sol";

import {IBondNFT}       from "./interfaces/IModules.sol";
import {IVestingModule} from "./interfaces/IModules.sol";

/// @title  BondNFT
/// @author Debitum
/// @notice ERC721 where each token represents a vesting position.
///         The owner can claim unlocked tokens at any time.
///         Transferring the NFT passes all remaining claim rights to the new owner.
///
/// @dev    CLAIM FLOW
///         1. Owner calls claim(tokenId)
///         2. BondNFT queries VestingModule.claimable(schedule, alreadyClaimed)
///         3. Updates position.claimedAmount
///         4. Transfers tokens from the bond contract address (or escrow) directly to the owner
///
///         TRANSFER SEMANTICS
///         claimedAmount stays on the position — the new owner only receives
///         what has NOT yet been claimed. This is correct and expected for
///         marketplace trading: the NFT price reflects the remaining unvested tokens.
///
///         ON-CHAIN METADATA
///         tokenURI() returns base64-encoded JSON with a live SVG image.
///         The SVG dynamically shows vesting progress — visible in any wallet
///         and marketplace with no external dependencies (no IPFS / server).
contract BondNFT is
    Initializable,
    ERC721Upgradeable,
    ERC2981Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IBondNFT
{
    using SafeERC20 for IERC20;
    using Strings   for uint256;

    // ─────────────────────────────────────────────────────────────────────────
    // Roles
    // ─────────────────────────────────────────────────────────────────────────

    bytes32 public constant ADMIN_ROLE       = keccak256("ADMIN_ROLE");
    /// @notice Granted to BondFactory — allows it to register bond contracts as minters
    bytes32 public constant REGISTRAR_ROLE   = keccak256("REGISTRAR_ROLE");
    /// @notice Granted to individual BondContract clones — allows them to mint
    bytes32 public constant MINTER_ROLE      = keccak256("MINTER_ROLE");

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    error ZeroAddress();

    uint256 private _nextTokenId;

    /// @notice Full position data per token ID
    mapping(uint256 => Position) private _positions;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor / Initializer
    // ─────────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address admin,
        address factory,        // gets REGISTRAR_ROLE — can register bond contracts
        uint96  royaltyBps      // ERC2981 royalty (e.g. 250 = 2.5%)
    ) external initializer {
        if (admin == address(0) || factory == address(0)) revert ZeroAddress();
        __ERC721_init("Bond Position", "BOND");
        __ERC2981_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE,         admin);
        _grantRole(REGISTRAR_ROLE,     factory);

        // Default royalty: sent to admin address, configurable later
        _setDefaultRoyalty(admin, royaltyBps);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Registration — BondFactory registers each new bond clone as a minter
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Called by BondFactory after deploying a new bond clone
    /// @dev    Only REGISTRAR_ROLE (= BondFactory) can call this
    function nextTokenId() external view returns (uint256) { return _nextTokenId; }

    function registerBond(address bondContract) external onlyRole(REGISTRAR_ROLE) {
        _grantRole(MINTER_ROLE, bondContract);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mint — called by BondContract on every purchase
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IBondNFT
    function mint(
        address to,
        address bondContract,
        IVestingModule.Schedule calldata schedule,
        address paymentToken,
        uint128 purchasePrice
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        tokenId = _nextTokenId++;

        // Resolve principal token from the bond contract's config
        // We call a minimal selector — avoids importing the full IBondContract
        (bool ok, bytes memory data) = bondContract.staticcall(
            abi.encodeWithSignature("config()")
        );
        address principalToken;
        if (ok && data.length >= 96) {
            // config() returns BondConfig struct; principalToken is the 3rd field
            // Memory layout of bytes: [32b length][32b creator][32b paymentToken][32b principalToken...]
            assembly { principalToken := mload(add(data, 96)) }
        }

        // Snapshot the vestingModule address from the bond contract.
        // This permanently binds this position to the exact vesting logic
        // that existed at purchase time — no admin action can ever change it.
        address vm;
        (bool vmOk, bytes memory vmData) = bondContract.staticcall(
            abi.encodeWithSignature("vestingModule()")
        );
        if (vmOk && vmData.length == 32) vm = abi.decode(vmData, (address));

        _positions[tokenId] = Position({
            vestingModule:   vm,
            bondContract:    bondContract,
            principalToken:  principalToken,
            paymentToken:    paymentToken,
            principalAmount: schedule.totalAmount,
            claimedAmount:   0,
            purchasePrice:   purchasePrice,
            schedule:        schedule
        });

        _safeMint(to, tokenId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Claim
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IBondNFT
    /// @dev  CEI pattern:
    ///       1. Read state
    ///       2. Update claimedAmount (before external call)
    ///       3. Transfer tokens
    function claim(uint256 tokenId) external nonReentrant {
        address owner = ownerOf(tokenId); // reverts if token doesn't exist
        if (msg.sender != owner) revert NotOwner();
        _claim(tokenId, owner);
    }

    /// @notice Claim on behalf of the owner (for approved operators / bots)
    function claimFor(uint256 tokenId, address owner) external nonReentrant {
        if (ownerOf(tokenId) != owner) revert NotOwner();
        // Caller must be approved operator or the owner themselves
        if (
            msg.sender != owner &&
            !isApprovedForAll(owner, msg.sender) &&
            getApproved(tokenId) != msg.sender
        ) revert NotOwner();
        _claim(tokenId, owner);
    }

    function _claim(uint256 tokenId, address owner) internal {
        Position storage pos = _positions[tokenId];

        uint128 amount = IVestingModule(pos.vestingModule).claimable(pos.schedule, pos.claimedAmount);
        if (amount == 0) revert NothingToClaim();

        // ── Update state BEFORE transfer (CEI) ───────────────────────────────
        pos.claimedAmount += amount;

        // ── Transfer principal tokens to owner ────────────────────────────────
        // Prefer pulling from BondContract (normal path) to avoid cross-bond token
        // contamination if the same token was sent directly to BondNFT (rescue scenario).
        if (IERC20(pos.principalToken).balanceOf(pos.bondContract) >= amount) {
            IERC20(pos.principalToken).safeTransferFrom(pos.bondContract, owner, amount);
        } else {
            // Rescue path: tokens deposited directly to BondNFT
            IERC20(pos.principalToken).safeTransfer(owner, amount);
        }

        emit Claimed(tokenId, owner, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IBondNFT
    function claimable(uint256 tokenId) external view returns (uint128) {
        Position storage pos = _positions[tokenId];
        return IVestingModule(pos.vestingModule).claimable(pos.schedule, pos.claimedAmount);
    }

    /// @inheritdoc IBondNFT
    function position(uint256 tokenId) external view returns (Position memory) {
        return _positions[tokenId];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // On-chain metadata — dynamic SVG
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns base64-encoded JSON metadata with a live SVG showing vesting progress.
    ///         No IPFS, no server. Works in any wallet that supports tokenURI.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        ownerOf(tokenId); // reverts if burned / nonexistent

        Position memory pos = _positions[tokenId];

        IVestingModule vm = IVestingModule(pos.vestingModule);

        // Compute live progress percentage (0–100)
        uint256 pct = pos.principalAmount > 0
            ? uint256(pos.claimedAmount + vm.claimable(pos.schedule, pos.claimedAmount))
              * 100 / uint256(pos.principalAmount)
            : 0;

        string memory vestingLabel = _vestingLabel(pos.schedule.vestingType);
        string memory symbol       = _safeSymbol(pos.principalToken);
        uint64  endTime            = vm.vestingEnd(pos.schedule);
        string memory remaining    = _formatTimeRemaining(endTime);

        string memory svg = _buildSVG(tokenId, symbol, pct, vestingLabel, remaining);

        string memory json = string(abi.encodePacked(
            '{"name":"Debitum Bond #', tokenId.toString(),
            '","description":"Debitum Protocol bond position. Holds vesting rights to discounted tokens. Transfer this NFT to transfer all remaining claim rights.",',
            '"attributes":[',
                '{"trait_type":"Principal Token","value":"', symbol, '"},',
                '{"trait_type":"Vesting Type","value":"', vestingLabel, '"},',
                '{"trait_type":"Total Amount","value":"', uint256(pos.principalAmount).toString(), '"},',
                '{"trait_type":"Claimed Amount","value":"', uint256(pos.claimedAmount).toString(), '"},',
                '{"trait_type":"Vested Percent","value":', pct.toString(), '},',
                '{"trait_type":"Vesting End","value":', uint256(endTime).toString(), '}',
            '],"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '"}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    /// @dev Sanitize a string for safe embedding in SVG/XML — removes special chars
    function _sanitize(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory result = new bytes(b.length);
        uint256 j = 0;
        for (uint256 i = 0; i < b.length && i < 8; i++) {
            bytes1 c = b[i];
            // Allow only alphanumeric and basic punctuation
            if ((c >= 0x30 && c <= 0x39) || // 0-9
                (c >= 0x41 && c <= 0x5A) || // A-Z
                (c >= 0x61 && c <= 0x7A) || // a-z
                c == 0x2D || c == 0x2E || c == 0x5F) { // - . _
                result[j++] = c;
            }
        }
        bytes memory trimmed = new bytes(j);
        for (uint256 i = 0; i < j; i++) trimmed[i] = result[i];
        return string(trimmed);
    }

    function _buildSVG(
        uint256 tokenId,
        string memory symbol,
        uint256 pct,
        string memory vestingLabel,
        string memory remaining
    ) internal pure returns (string memory) {
        // Sanitize all user-supplied strings before embedding in SVG (prevents XSS L-2)
        symbol = _sanitize(symbol);
        // Progress bar width: max 260px at 100%
        uint256 barWidth = pct * 260 / 100;

        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 180" style="border-radius:12px">',

            // Background
            '<rect width="300" height="180" rx="12" fill="#0f0f14"/>',

            // Header bar
            '<rect width="300" height="44" rx="12" fill="#1a1a24"/>',
            '<rect y="32" width="300" height="12" fill="#1a1a24"/>',

            // Bond icon dot
            '<circle cx="22" cy="22" r="8" fill="#6366f1" opacity="0.9"/>',

            // Title
            '<text x="38" y="27" font-family="monospace" font-size="13" font-weight="600" fill="#e2e2e8">Bond Position #', tokenId.toString(), '</text>',

            // Token label
            '<text x="20" y="68" font-family="monospace" font-size="11" fill="#8888a0">PRINCIPAL TOKEN</text>',
            '<text x="20" y="86" font-family="monospace" font-size="16" font-weight="700" fill="#e2e2e8">', symbol, '</text>',

            // Vesting type
            '<text x="160" y="68" font-family="monospace" font-size="11" fill="#8888a0">VESTING TYPE</text>',
            '<text x="160" y="86" font-family="monospace" font-size="14" font-weight="600" fill="#a5b4fc">', vestingLabel, '</text>',

            // Progress label
            '<text x="20" y="114" font-family="monospace" font-size="11" fill="#8888a0">VESTED</text>',
            '<text x="270" y="114" font-family="monospace" font-size="11" fill="#8888a0" text-anchor="end">', pct.toString(), '%</text>',

            // Progress bar track
            '<rect x="20" y="120" width="260" height="8" rx="4" fill="#2a2a38"/>',

            // Progress bar fill (colour shifts: grey→purple→green as it fills)
            '<rect x="20" y="120" width="', barWidth.toString(), '" height="8" rx="4" fill="',
                pct < 50 ? '#6366f1' : pct < 100 ? '#818cf8' : '#34d399',
            '"/>',

            // Time remaining
            '<text x="20" y="152" font-family="monospace" font-size="11" fill="#8888a0">TIME REMAINING</text>',
            '<text x="20" y="168" font-family="monospace" font-size="12" fill="#e2e2e8">', remaining, '</text>',

            // Watermark
            '<text x="290" y="168" font-family="monospace" font-size="9" fill="#3a3a50" text-anchor="end">Debitum</text>',

            '</svg>'
        ));
    }

    function _vestingLabel(IVestingModule.VestingType vt) internal pure returns (string memory) {
        if (vt == IVestingModule.VestingType.Linear) return "Linear";
        if (vt == IVestingModule.VestingType.Cliff)  return "Cliff";
        if (vt == IVestingModule.VestingType.Step)   return "Step";
        return "Unknown";
    }

    function _safeSymbol(address token) internal view returns (string memory) {
        if (token == address(0)) return "ETH";
        try IERC20Metadata(token).symbol() returns (string memory sym) {
            return bytes(sym).length > 0 ? sym : "???";
        } catch {
            return "???";
        }
    }

    function _formatTimeRemaining(uint64 endTime) internal view returns (string memory) {
        if (block.timestamp >= endTime) return "Fully vested";
        uint256 secs = endTime - block.timestamp;
        uint256 days_ = secs / 86400;
        if (days_ > 0) return string(abi.encodePacked(days_.toString(), " days"));
        uint256 hrs = secs / 3600;
        if (hrs > 0) return string(abi.encodePacked(hrs.toString(), " hours"));
        return string(abi.encodePacked((secs / 60).toString(), " minutes"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC165 supportsInterface
    // ─────────────────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721Upgradeable, ERC2981Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function setRoyalty(address receiver, uint96 bps) external onlyRole(ADMIN_ROLE) {
        _setDefaultRoyalty(receiver, bps);
    }

}
