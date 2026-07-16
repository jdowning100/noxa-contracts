// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "./interfaces/IUniswapV3.sol";

/// @notice Splits LP fees collected by the LauncherLocker between the token
/// creator (feeWallet) and the protocol treasury. Pair-token fees paid in WETH
/// are unwrapped to native ETH before payout.
contract FeeRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidBasisPoints();
    error ZeroAddress();
    error EthTransferFailed();
    error NotLocker();
    error AlreadyInitialized();

    event FeesDistributed(
        address indexed token,
        address indexed feeWallet,
        uint256 creatorTokenAmount,
        uint256 creatorPairAmount,
        uint256 protocolTokenAmount,
        uint256 protocolPairAmount
    );
    event TreasuryUpdated(address treasury);
    event ProtocolShareUpdated(uint16 protocolShareBps);
    event TokenTreasuryShareUpdated(uint16 tokenTreasuryShareBps);
    event LockerUpdated(address locker);

    uint16 public constant MAX_BPS = 10_000;

    address public immutable weth;
    address public treasury;
    address public locker;
    /// @notice Protocol share of pair-token (ETH) fees, in bps.
    uint16 public protocolShare;
    /// @notice Protocol share of launched-token fees, in bps.
    uint16 public tokenTreasuryShare;

    constructor(address weth_, address treasury_, uint16 protocolShare_, uint16 tokenTreasuryShare_)
        Ownable(msg.sender)
    {
        if (weth_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (protocolShare_ > MAX_BPS || tokenTreasuryShare_ > MAX_BPS) revert InvalidBasisPoints();
        weth = weth_;
        treasury = treasury_;
        protocolShare = protocolShare_;
        tokenTreasuryShare = tokenTreasuryShare_;
    }

    receive() external payable {}

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setProtocolShare(uint16 bps) external onlyOwner {
        if (bps > MAX_BPS) revert InvalidBasisPoints();
        protocolShare = bps;
        emit ProtocolShareUpdated(bps);
    }

    function setTokenTreasuryShare(uint16 bps) external onlyOwner {
        if (bps > MAX_BPS) revert InvalidBasisPoints();
        tokenTreasuryShare = bps;
        emit TokenTreasuryShareUpdated(bps);
    }

    /// @notice One-time wiring of the locker (set at deployment).
    function setLocker(address locker_) external onlyOwner {
        if (locker_ == address(0)) revert ZeroAddress();
        if (locker != address(0)) revert AlreadyInitialized();
        locker = locker_;
        emit LockerUpdated(locker_);
    }

    /// @notice Distribute fees previously transferred to this contract by the locker.
    /// @dev Only callable by the locker, within the same tx as the collect.
    function distribute(address token, address pairToken, uint256 tokenAmount, uint256 pairAmount, address feeWallet)
        external
        nonReentrant
    {
        if (msg.sender != locker) revert NotLocker();

        uint256 protocolTokenAmt = (tokenAmount * tokenTreasuryShare) / MAX_BPS;
        uint256 creatorTokenAmt = tokenAmount - protocolTokenAmt;
        uint256 protocolPairAmt = (pairAmount * protocolShare) / MAX_BPS;
        uint256 creatorPairAmt = pairAmount - protocolPairAmt;

        if (protocolTokenAmt > 0) IERC20(token).safeTransfer(treasury, protocolTokenAmt);
        if (creatorTokenAmt > 0) IERC20(token).safeTransfer(feeWallet, creatorTokenAmt);

        if (pairToken == weth && pairAmount > 0) {
            IWETH9(weth).withdraw(pairAmount);
            if (protocolPairAmt > 0) _sendEth(treasury, protocolPairAmt);
            if (creatorPairAmt > 0) _sendEth(feeWallet, creatorPairAmt);
        } else {
            if (protocolPairAmt > 0) IERC20(pairToken).safeTransfer(treasury, protocolPairAmt);
            if (creatorPairAmt > 0) IERC20(pairToken).safeTransfer(feeWallet, creatorPairAmt);
        }

        emit FeesDistributed(token, feeWallet, creatorTokenAmt, creatorPairAmt, protocolTokenAmt, protocolPairAmt);
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
