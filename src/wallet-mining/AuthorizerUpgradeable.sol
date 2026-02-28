// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

// @audit Critical - Uninitialized Proxy Allows Arbitrary Authorization Takeover
//
// - Impact
// AuthorizerUpgradeable is intended to be used behind a proxy, meaning all usable state is stored in the proxy, not the implementation.
// The contract exposes an externally callable init() function that relies on a `needsInit` flag which is not reliably initialized in proxy storage.
// Because constructors do not initialize proxy storage, proxy instances may have needsInit in an uninitialized or corrupted state.
// In this deployment, slot 0 is occupied by proxy state (upgrader), causing a storage collision that makes the initialization guard unreliable.
// An attacker can call init() through the proxy before the legitimate deployer does, granting themselves authorization for arbitrary (usr, aim) pairs via _rely().
// This fully compromises the authorization layer enforced by can(usr, aim), allowing bypass of downstream permission checks that depend on this contract.
//
// - Root Cause
// The contract mixes upgradeable proxy assumptions with constructor-based initialization.
// In proxy-based upgradeable systems, constructors execute only in the implementation context and do not initialize proxy storage.
// As a result, proxy instances may remain uninitialized.
// Because init() is externally callable and lacks access control, the first caller can initialize proxy storage and assign arbitrary permissions.
//
// Contributing Factor:
// The proxy stores `upgrader` at slot 0, colliding with `needsInit` (slot 0) in the implementation layout.
// This storage collision makes the initialization guard unreliable and amplifies the severity of the issue.
//
// - Recommended Fix
// Adopt a standard upgradeable initialization pattern:
//   • Replace init() with initialize() protected by OpenZeppelin's `initializer` modifier.
//   • Ensure initialization is performed atomically during proxy deployment.
//   • Remove constructor-based “freeze” logic and instead call _disableInitializers() in the implementation constructor (if using OZ upgradeable patterns).
// Additional hardening (optional):
//   • Validate that _wards.length == _aims.length.
//   • Emit an event signaling initialization completion.
contract AuthorizerUpgradeable {
    // @audit INFO: State variable initializers (e.g. `uint256 needsInit = 1;`) compile into constructor logic.
    // In upgradeable proxy patterns, constructors do not initialize proxy storage.
    // Initialization must occur via an initializer function executed through the proxy.
    // Constants are exempt because they do not consume storage slots; they are inlined into bytecode at compile time.
    uint256 public needsInit = 1;
    mapping(address => mapping(address => uint256)) private wards;

    event Rely(address indexed usr, address aim);

    // @audit This constructor only affects the implementation contract.
    // It does not prevent initialization of proxy instances.
    // Freezing the implementation does not secure proxy storage.
    constructor() {
        needsInit = 0; // freeze implementation
    }

    // @audit Initializer Not Protected / Not Atomically Executed
    // This function can be called by anyone, even though initialization is supposedly disabled by constructor.
    // This allows anyone to assign any ward to any aim which bypasses the intended functionality of this contract.
    // If initialization were performed atomically during proxy deployment (setting needsInit = 0 in proxy storage), this takeover vector would not exist.
    // However, leaving init() permissionless makes any uninitialized proxy instance vulnerable to takeover.
    function init(address[] memory _wards, address[] memory _aims) external {
        require(needsInit != 0, "cannot init");
        for (uint256 i = 0; i < _wards.length; i++) {
            _rely(_wards[i], _aims[i]);
        }
        needsInit = 0;
    }

    function _rely(address usr, address aim) private {
        wards[usr][aim] = 1;
        emit Rely(usr, aim);
    }

    function can(address usr, address aim) external view returns (bool) {
        return wards[usr][aim] == 1;
    }
}
