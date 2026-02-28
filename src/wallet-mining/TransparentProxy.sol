// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {AuthorizerUpgradeable} from "./AuthorizerUpgradeable.sol";

// @audit High - Proxy State Variable Introduces Storage Collision With Implementation Layout
//
// - Impact
// TransparentProxy defines upgrader address as a normal state variable stored at storage slot 0.
// Since the proxy delegates calls to the implementation, any implementation variable at slot 0 will read/write the proxy’s upgrader storage.
// This causes storage layout corruption and unpredictable behavior in proxied contracts, including:
//      - initialization guards reading incorrect values,
//      - authorization logic becoming unreliable,
//      - state corruption across upgrades,
//      - potential bricking of upgradeable instances.
// In this system, AuthorizerUpgradeable.needsInit (slot 0) collides with TransparentProxy.upgrader (slot 0), causing needsInit reads to return a large non-zero value derived from the upgrader address.
// Because both variables occupy slot 0, calling init() (which sets needsInit = 0) will also overwrite the proxy’s upgrader value with 0, effectively disabling any logic relying on the upgrader address.
//
// - Root Cause
// The proxy mixes EIP-1967 unstructured storage (admin/implementation stored at unique hashed slots) with structured storage (normal Solidity state variables at low slots).
// Because delegatecalls execute in the proxy’s storage context, slot 0 is shared between proxy and implementation layouts.
//
// - Recommendation
// Avoid declaring regular Solidity state variables in proxy contracts. Instead:
//      - Store proxy-specific state in unstructured storage slots (EIP-1967 style / dedicated keccak slots), or
//      - Use OpenZeppelin’s standard TransparentUpgradeableProxy implementation which avoids structured storage collisions, or
//      - Place proxy variables in dedicated storage namespaces (e.g., bytes32 internal constant UPGRADER_SLOT = keccak256("...")) and read/write via assembly.

/**
 * @notice Transparent proxy with an upgrader role handled by its admin.
 */
contract TransparentProxy is ERC1967Proxy {
    // @audit Storage collision caused by mixing EIP-1967 unstructured storage with structured storage
    address public upgrader = msg.sender;

    constructor(address _logic, bytes memory _data) ERC1967Proxy(_logic, _data) {
        ERC1967Utils.changeAdmin(msg.sender);
    }

    function setUpgrader(address who) external {
        require(msg.sender == ERC1967Utils.getAdmin(), "!admin");
        upgrader = who;
    }

    function isUpgrader(address who) public view returns (bool) {
        return who == upgrader;
    }

    function _fallback() internal override {
        if (isUpgrader(msg.sender)) {
            require(msg.sig == bytes4(keccak256("upgradeToAndCall(address, bytes)")));
            _dispatchUpgradeToAndCall();
        } else {
            super._fallback();
        }
    }

    function _dispatchUpgradeToAndCall() private {
        (address newImplementation, bytes memory data) = abi.decode(msg.data[4:], (address, bytes));
        ERC1967Utils.upgradeToAndCall(newImplementation, data);
    }
}
