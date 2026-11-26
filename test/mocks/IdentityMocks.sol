// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev Minimal ERC-721-like / SBT balance holder for tests (BABT and Agent ID stand-ins).
contract MockIdentityToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to) external {
        balanceOf[to] += 1;
    }
}

/// @dev balanceOf always reverts.
contract RevertingToken {
    fallback() external {
        revert("nope");
    }
}

/// @dev balanceOf burns all forwarded gas.
contract GuzzlerToken {
    fallback() external {
        assembly {
            for {} 1 {} {}
        }
    }
}

/// @dev Returns only 31 bytes (a non-zero one).
contract ShortReturnToken {
    fallback() external {
        assembly {
            mstore(0, not(0))
            return(1, 31)
        }
    }
}

/// @dev Returns `size` bytes whose first word is 1 (huge returndata).
contract ReturnBombToken {
    uint256 public immutable size;

    constructor(uint256 size_) {
        size = size_;
    }

    fallback() external {
        uint256 s = size;
        assembly {
            mstore(0, 1)
            return(0, s)
        }
    }
}

/// @dev Returns a non-zero garbage word regardless of the queried wallet.
contract GarbageToken {
    fallback() external {
        assembly {
            mstore(0, 0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef)
            return(0, 32)
        }
    }
}
