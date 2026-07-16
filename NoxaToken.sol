// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The noxa2.finance protocol token (NOXA). Fixed supply of 1,000,000, minted
/// once to the deployer at construction — no mint authority, no owner, no upgradeability.
/// This is a plain ERC-20 (the airdrop token / protocol token); it is deliberately NOT a
/// launchpad LaunchToken and carries no fee, snapshot, or transfer-restriction logic.
///
/// It DOES expose the legacy on-chain metadata surface (getTokenInfo / logo / description /
/// socials) so the indexer and frontend can read its logo the same way they read a
/// first-generation LaunchToken. All metadata is immutable, set once at construction.
contract Noxa2Token is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 1e18;

    // Field order matches the indexer's getTokenInfo decoder: (telegram, twitter, discord, website, farcaster).
    struct Socials {
        string telegram;
        string twitter;
        string discord;
        string website;
        string farcaster;
    }

    address public immutable deployer;
    string private _logo;
    string private _description;
    Socials private _socials;

    constructor(
        address recipient,
        string memory logo_,
        string memory description_,
        Socials memory socials_
    ) ERC20("noxa2.finance", "NOXA") {
        deployer = recipient;
        _logo = logo_;
        _description = description_;
        _socials = socials_;
        _mint(recipient, INITIAL_SUPPLY);
    }

    /// @notice Creator logo URI (ipfs:// or https://).
    function logo() external view returns (string memory) {
        return _logo;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice (telegram, twitter, discord, website, farcaster).
    function socials()
        external
        view
        returns (string memory telegram, string memory twitter, string memory discord, string memory website, string memory farcaster)
    {
        Socials memory s = _socials;
        return (s.telegram, s.twitter, s.discord, s.website, s.farcaster);
    }

    /// @notice Aggregate metadata read, matching the first-generation LaunchToken getter the
    /// indexer backfills from: (deployer, logo, description, socials).
    function getTokenInfo()
        external
        view
        returns (address deployer_, string memory logo_, string memory description_, Socials memory socials_)
    {
        return (deployer, _logo, _description, _socials);
    }
}
