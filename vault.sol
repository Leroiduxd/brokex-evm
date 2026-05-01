// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IBrokexCorePnl {
    function getGlobalUnrealizedPnl(bytes calldata proof) external returns (int256);
}

contract BrokexPublicVault {
    uint256 public constant PRECISION = 1e6;

    IERC20 public immutable stable;

    address public owner;
    address public pendingOwner;
    address public core;
    bool public coreLocked;
    bool public paused;
    bool private locked;

    string public name = "Brokex LP Share";
    string public symbol = "BLP";
    uint8 public decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public lpLockedCapital;
    uint256 public minDeposit;
    uint256 public minWithdrawShares;

    uint256 public nextRequestId = 1;
    uint256 public nextRequestToProcess = 1;
    uint256 public pendingWithdrawShares;

    mapping(address => uint256) public activeWithdrawRequestId;

    struct WithdrawRequest {
        address user;
        uint256 sharesRemaining;
        bool active;
    }

    mapping(uint256 => WithdrawRequest) public withdrawRequests;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event WithdrawRequested(uint256 indexed id, address indexed user, uint256 shares);
    event WithdrawProcessed(
        uint256 indexed id,
        address indexed user,
        uint256 sharesBurned,
        uint256 amountPaid,
        bool finished
    );

    error NotOwner();
    error NotCore();
    error ZeroAddress();
    error ZeroAmount();
    error Paused();
    error Reentrancy();
    error TransferFailed();
    error CoreAlreadyLocked();
    error CoreNotSet();
    error InsufficientBalance();
    error InsufficientFreeCapital();
    error ActiveWithdrawRequest();
    error NoActiveWithdrawRequest();
    error AmountTooSmall();
    error InvalidVaultValue();
    error InvalidUnlockAmount();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyCore() {
        if (msg.sender != core) revert NotCore();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor(
        address stableToken,
        uint256 minDeposit_,
        uint256 minWithdrawShares_
    ) {
        if (stableToken == address(0)) revert ZeroAddress();

        stable = IERC20(stableToken);
        owner = msg.sender;

        minDeposit = minDeposit_;
        minWithdrawShares = minWithdrawShares_;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();

        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function setCore(address newCore) external onlyOwner {
        if (coreLocked) revert CoreAlreadyLocked();
        if (newCore == address(0)) revert ZeroAddress();

        core = newCore;
    }

    function lockCore() external onlyOwner {
        if (core == address(0)) revert CoreNotSet();

        coreLocked = true;
    }

    function setMinimums(
        uint256 minDeposit_,
        uint256 minWithdrawShares_
    ) external onlyOwner {
        minDeposit = minDeposit_;
        minWithdrawShares = minWithdrawShares_;
    }

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transferShares(msg.sender, to, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];

        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientBalance();

            allowance[from][msg.sender] = allowed - amount;
        }

        _transferShares(from, to, amount);

        return true;
    }

    function deposit(
        uint256 amount,
        bytes calldata proof
    ) external nonReentrant whenNotPaused returns (uint256 sharesMinted) {
        if (core == address(0)) revert CoreNotSet();
        if (amount == 0) revert ZeroAmount();
        if (amount < minDeposit) revert AmountTooSmall();

        int256 traderUnrealizedPnl = IBrokexCorePnl(core).getGlobalUnrealizedPnl(proof);

        uint256 valueBefore = vaultValueFromPnl(traderUnrealizedPnl);

        if (totalSupply == 0) {
            sharesMinted = amount;
        } else {
            if (valueBefore == 0) revert InvalidVaultValue();

            sharesMinted = amount * totalSupply / valueBefore;
        }

        if (sharesMinted == 0) revert AmountTooSmall();

        _safeTransferFrom(msg.sender, address(this), amount);

        _mint(msg.sender, sharesMinted);
    }

    function requestWithdraw(
        uint256 shares
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        if (shares == 0) revert ZeroAmount();
        if (shares < minWithdrawShares) revert AmountTooSmall();
        if (activeWithdrawRequestId[msg.sender] != 0) revert ActiveWithdrawRequest();
        if (balanceOf[msg.sender] < shares) revert InsufficientBalance();

        balanceOf[msg.sender] -= shares;
        balanceOf[address(this)] += shares;

        pendingWithdrawShares += shares;

        id = nextRequestId++;

        activeWithdrawRequestId[msg.sender] = id;

        withdrawRequests[id] = WithdrawRequest({
            user: msg.sender,
            sharesRemaining: shares,
            active: true
        });

        emit Transfer(msg.sender, address(this), shares);
        emit WithdrawRequested(id, msg.sender, shares);
    }

    function cancelWithdrawRequest() external nonReentrant {
        uint256 id = activeWithdrawRequestId[msg.sender];

        if (id == 0) revert NoActiveWithdrawRequest();

        WithdrawRequest storage r = withdrawRequests[id];

        uint256 shares = r.sharesRemaining;

        if (!r.active || shares == 0) revert NoActiveWithdrawRequest();

        r.active = false;
        r.sharesRemaining = 0;

        activeWithdrawRequestId[msg.sender] = 0;
        pendingWithdrawShares -= shares;

        balanceOf[address(this)] -= shares;
        balanceOf[msg.sender] += shares;

        emit Transfer(address(this), msg.sender, shares);
    }

    function processWithdrawals(
        bytes calldata proof,
        uint256 maxRequests
    ) external nonReentrant whenNotPaused returns (uint256 paidTotal) {
        if (core == address(0)) revert CoreNotSet();
        if (maxRequests == 0) revert ZeroAmount();
        if (totalSupply == 0) return 0;

        int256 traderUnrealizedPnl = IBrokexCorePnl(core).getGlobalUnrealizedPnl(proof);

        uint256 value = vaultValueFromPnl(traderUnrealizedPnl);

        if (value == 0) revert InvalidVaultValue();

        uint256 sharePrice = value * PRECISION / totalSupply;

        if (sharePrice == 0) revert InvalidVaultValue();

        uint256 processed;
        uint256 free = lpFreeCapital();

        while (
            processed < maxRequests &&
            nextRequestToProcess < nextRequestId &&
            free > 0
        ) {
            uint256 id = nextRequestToProcess;

            WithdrawRequest storage r = withdrawRequests[id];

            if (!r.active || r.sharesRemaining == 0) {
                nextRequestToProcess++;
                continue;
            }

            uint256 fullAmount = r.sharesRemaining * sharePrice / PRECISION;

            uint256 amountToPay = fullAmount <= free ? fullAmount : free;

            if (amountToPay == 0) break;

            uint256 sharesToBurn = amountToPay * PRECISION / sharePrice;

            if (sharesToBurn == 0) break;

            if (sharesToBurn > r.sharesRemaining) {
                sharesToBurn = r.sharesRemaining;
            }

            amountToPay = sharesToBurn * sharePrice / PRECISION;

            if (amountToPay == 0 || amountToPay > free) break;

            r.sharesRemaining -= sharesToBurn;
            pendingWithdrawShares -= sharesToBurn;

            _burn(address(this), sharesToBurn);

            _safeTransfer(r.user, amountToPay);

            bool finished = r.sharesRemaining == 0;

            if (finished) {
                r.active = false;
                activeWithdrawRequestId[r.user] = 0;
                nextRequestToProcess++;
                processed++;
            }

            free -= amountToPay;
            paidTotal += amountToPay;

            emit WithdrawProcessed(
                id,
                r.user,
                sharesToBurn,
                amountToPay,
                finished
            );
        }
    }

    function lockCapital(uint256 amount) external onlyCore whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        if (amount > availableForTrading()) {
            revert InsufficientFreeCapital();
        }

        lpLockedCapital += amount;
    }

    function unlockCapital(uint256 amount) external onlyCore {
        if (amount == 0) revert ZeroAmount();

        if (amount > lpLockedCapital) {
            revert InvalidUnlockAmount();
        }

        lpLockedCapital -= amount;
    }

    function payTrader(address trader, uint256 amount) external onlyCore whenNotPaused {
        if (trader == address(0)) revert ZeroAddress();

        if (amount == 0) return;

        _safeTransfer(trader, amount);
    }

    function collectLoss(uint256 amount) external onlyCore whenNotPaused {
        if (amount == 0) return;

        _safeTransferFrom(msg.sender, address(this), amount);
    }

    function collectCommission(uint256 amount) external onlyCore whenNotPaused {
        if (amount == 0) return;

        _safeTransferFrom(msg.sender, address(this), amount);
    }

    function sharePrice(bytes calldata proof) external returns (uint256) {
        if (core == address(0)) revert CoreNotSet();

        if (totalSupply == 0) {
            return PRECISION;
        }

        int256 traderUnrealizedPnl = IBrokexCorePnl(core).getGlobalUnrealizedPnl(proof);

        return vaultValueFromPnl(traderUnrealizedPnl) * PRECISION / totalSupply;
    }

    function vaultValueFromPnl(
        int256 traderUnrealizedPnl
    ) public view returns (uint256) {
        uint256 balance = stable.balanceOf(address(this));

        if (traderUnrealizedPnl >= 0) {
            uint256 pnl = uint256(traderUnrealizedPnl);

            if (pnl >= balance) {
                return 0;
            }

            return balance - pnl;
        }

        return balance + uint256(-traderUnrealizedPnl);
    }

    function lpFreeCapital() public view returns (uint256) {
        uint256 balance = stable.balanceOf(address(this));

        if (balance <= lpLockedCapital) {
            return 0;
        }

        return balance - lpLockedCapital;
    }

    function pendingWithdrawValueFromPnl(
        int256 traderUnrealizedPnl
    ) public view returns (uint256) {
        if (totalSupply == 0 || pendingWithdrawShares == 0) {
            return 0;
        }

        return vaultValueFromPnl(traderUnrealizedPnl) * pendingWithdrawShares / totalSupply;
    }

    function availableForTrading() public view returns (uint256) {
        uint256 free = lpFreeCapital();

        if (totalSupply == 0 || pendingWithdrawShares == 0) {
            return free;
        }

        uint256 reserve = stable.balanceOf(address(this)) * pendingWithdrawShares / totalSupply;

        if (reserve >= free) {
            return 0;
        }

        return free - reserve;
    }

    function _transferShares(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();

        if (balanceOf[from] < amount) {
            revert InsufficientBalance();
        }

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        if (balanceOf[from] < amount) {
            revert InsufficientBalance();
        }

        balanceOf[from] -= amount;
        totalSupply -= amount;

        emit Transfer(from, address(0), amount);
    }

    function _safeTransfer(address to, uint256 amount) internal {
        bool ok = stable.transfer(to, amount);

        if (!ok) revert TransferFailed();
    }

    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        bool ok = stable.transferFrom(from, to, amount);

        if (!ok) revert TransferFailed();
    }
}
