// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal EIP-1967 proxy with atomic constructor initialization, used
/// for fork-testing the NoxaCTOFund deployment (mirrors the IntegrationProxy
/// pattern from the test suite). Production deployments should use a standard
/// transparent proxy behind a timelocked multisig admin per CTO_DEPLOYMENT.md.
contract CTOProxy {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation, bytes memory initializationCall) {
        assembly ("memory-safe") {
            sstore(IMPLEMENTATION_SLOT, implementation)
        }
        (bool ok, bytes memory result) = implementation.delegatecall(initializationCall);
        if (!ok) _revert(result);
    }

    fallback() external payable {
        _delegate();
    }

    receive() external payable {
        _delegate();
    }

    function _delegate() private {
        assembly ("memory-safe") {
            let implementation := sload(IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _revert(bytes memory result) private pure {
        assembly ("memory-safe") {
            revert(add(result, 32), mload(result))
        }
    }
}
