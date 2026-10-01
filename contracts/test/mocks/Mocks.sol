// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 6-decimal USDC stand-in.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure virtual override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Wrong decimals, to test constructor validation.
contract Mock18Decimals is ERC20 {
    constructor() ERC20("Wrong", "WRONG") {}
}

/// @notice Takes a 1% fee on every transfer, so the recipient receives less than `amount`.
contract FeeOnTransferToken is MockUSDC {
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xFEE), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice Returns false instead of reverting when `failTransfers` is set (non-reverting failure mode).
contract FalseReturnToken is MockUSDC {
    bool public failTransfers;

    function setFail(bool fail) external {
        failTransfers = fail;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (failTransfers) return false;
        return super.transferFrom(from, to, value);
    }
}

interface ITokenReceiverHook {
    function onTokenTransfer() external;
}

/// @notice ERC777-style token that calls opted-in senders/recipients during transfers (exercises reentrancy).
contract HookToken is MockUSDC {
    mapping(address => bool) public hooked;

    function setHooked(address account, bool on) external {
        hooked[account] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (hooked[from]) ITokenReceiverHook(from).onTokenTransfer();
        super._update(from, to, value);
        if (hooked[to]) ITokenReceiverHook(to).onTokenTransfer();
    }
}

/// @notice USDT-style token: `transfer`/`transferFrom` return nothing. SafeERC20 must accept it.
contract NoReturnToken {
    string public constant name = "No Return";
    string public constant symbol = "NRT";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Every transfer reverts while `broken` is set (e.g. an issuer-side outage or a paused token).
contract RevertingToken is MockUSDC {
    error TokenBroken();

    bool public broken;

    function setBroken(bool b) external {
        broken = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (broken && from != address(0) && to != address(0)) revert TokenBroken();
        super._update(from, to, value);
    }
}

/// @notice Returns true but moves nothing while `lying` is set (a token that violates ERC-20 silently).
contract LyingToken is MockUSDC {
    bool public lying;

    function setLying(bool l) external {
        lying = l;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (lying) return true;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (lying) return true;
        return super.transferFrom(from, to, value);
    }
}

/// @notice Models Circle FiatToken controls: a global pause and a per-address blacklist (sender or recipient).
contract BlacklistToken is MockUSDC {
    error Blacklisted(address account);
    error TokenPaused();

    mapping(address => bool) public isBlacklisted;
    bool public paused;

    function blacklist(address a, bool on) external {
        isBlacklisted[a] = on;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert TokenPaused();
        if (isBlacklisted[from]) revert Blacklisted(from);
        if (isBlacklisted[to]) revert Blacklisted(to);
        super._update(from, to, value);
    }
}
