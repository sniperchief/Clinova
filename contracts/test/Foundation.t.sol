// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// Compile-time check that the planned OpenZeppelin primitives resolve under our remappings and compiler.
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ClinovaTypes} from "../src/libraries/ClinovaTypes.sol";
import {IProviderRegistry} from "../src/interfaces/IProviderRegistry.sol";
import {IServiceMarketplace} from "../src/interfaces/IServiceMarketplace.sol";
import {IClinovaEscrow} from "../src/interfaces/IClinovaEscrow.sol";
import {IProofOfService} from "../src/interfaces/IProofOfService.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";

/// @notice Phase 1 foundation checks: types match the spec; optional Arbitrum Sepolia fork checks.
contract FoundationTest is Test {
    uint256 internal constant ARB_SEPOLIA_CHAIN_ID = 421614;

    function test_StatusNoneIsZero() public pure {
        assertEq(uint8(ClinovaTypes.Status.NONE), 0);
    }

    function test_TerminalStates() public pure {
        assertTrue(ClinovaTypes.isTerminal(ClinovaTypes.Status.SETTLED));
        assertTrue(ClinovaTypes.isTerminal(ClinovaTypes.Status.CANCELLED));
        assertTrue(ClinovaTypes.isTerminal(ClinovaTypes.Status.EXPIRED));
        assertTrue(ClinovaTypes.isTerminal(ClinovaTypes.Status.REFUNDED));

        assertFalse(ClinovaTypes.isTerminal(ClinovaTypes.Status.NONE));
        assertFalse(ClinovaTypes.isTerminal(ClinovaTypes.Status.OPEN));
        assertFalse(ClinovaTypes.isTerminal(ClinovaTypes.Status.ACCEPTED));
        assertFalse(ClinovaTypes.isTerminal(ClinovaTypes.Status.IN_SERVICE));
        assertFalse(ClinovaTypes.isTerminal(ClinovaTypes.Status.COMPLETED));
        assertFalse(ClinovaTypes.isTerminal(ClinovaTypes.Status.DISPUTED));
    }

    /// @dev Runs only when ARB_SEPOLIA_RPC_URL and USDC_ADDRESS are set; otherwise skipped.
    function test_Fork_ArbitrumSepoliaUsdc() public {
        string memory rpc = vm.envOr("ARB_SEPOLIA_RPC_URL", string(""));
        address usdc = vm.envOr("USDC_ADDRESS", address(0));
        if (bytes(rpc).length == 0 || usdc == address(0)) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, ARB_SEPOLIA_CHAIN_ID, "not Arbitrum Sepolia");
        assertGt(usdc.code.length, 0, "USDC has no code");
        assertEq(IERC20Metadata(usdc).decimals(), 6, "USDC decimals");
        assertEq(IERC20Metadata(usdc).symbol(), "USDC");
    }
}
