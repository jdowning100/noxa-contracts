// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Compact initializer/ownership/reentrancy primitives for contracts deployed behind a transparent proxy.
/// The storage gaps and initializer discipline follow OpenZeppelin's upgradeable-contract pattern.
abstract contract Initializable {
    error InvalidInitialization();
    error NotInitializing();

    uint8 private _initialized;
    bool private _initializing;

    event Initialized(uint8 version);

    modifier initializer() {
        if (_initializing || _initialized != 0) revert InvalidInitialization();
        _initialized = 1;
        _initializing = true;
        _;
        _initializing = false;
        emit Initialized(1);
    }

    modifier reinitializer(uint8 version) {
        if (_initializing || version == 0 || _initialized >= version) revert InvalidInitialization();
        _initialized = version;
        _initializing = true;
        _;
        _initializing = false;
        emit Initialized(version);
    }

    modifier onlyInitializing() {
        if (!_initializing) revert NotInitializing();
        _;
    }

    function _disableInitializers() internal {
        if (_initializing) revert InvalidInitialization();
        if (_initialized != type(uint8).max) {
            _initialized = type(uint8).max;
            emit Initialized(type(uint8).max);
        }
    }
}

abstract contract OwnableUpgradeable is Initializable {
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != _owner) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    function __Ownable_init(address initialOwner) internal onlyInitializing {
        if (initialOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _transferOwnership(initialOwner);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _transferOwnership(newOwner);
    }

    function renounceOwnership() external onlyOwner {
        _transferOwnership(address(0));
    }

    function _transferOwnership(address newOwner) internal {
        address previousOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    uint256[49] private __gap;
}

abstract contract ReentrancyGuardUpgradeable is Initializable {
    error ReentrancyGuardReentrantCall();

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _status;

    modifier nonReentrant() {
        if (_status == ENTERED) revert ReentrancyGuardReentrantCall();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    function __ReentrancyGuard_init() internal onlyInitializing {
        _status = NOT_ENTERED;
    }

    uint256[49] private __gap;
}
