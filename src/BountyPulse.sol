// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  BountyPulse
 * @notice Decentralized micro-bounty platform with on-chain escrow, a 2% protocol
 *         fee, arbitrated dispute resolution and a freelancer reputation system.
 *
 * @dev ARCHITECTURE
 *      Two layers, deliberately split to keep chain state small:
 *
 *        Storage layer (off-chain)  : avatars, bounty briefs and delivered work
 *                                     files are pinned to IPFS via Pinata. Only
 *                                     the resulting CID (a short string) is ever
 *                                     written to storage. Storing a 2 MB image
 *                                     on-chain would cost millions of gas; a CID
 *                                     costs two storage slots.
 *
 *        Settlement layer (on-chain): this contract. It is the sole registry of
 *                                     users, the escrow vault, the fee collector
 *                                     and the reputation ledger.
 *
 * @dev SECURITY POSTURE
 *      - Checks-Effects-Interactions is applied without exception: every state
 *        mutation completes before any value transfer.
 *      - A minimal non-reentrancy guard protects every function that moves ETH.
 *      - Payouts use the pull-payment pattern (`claimFunds`). The contract never
 *        depends on a recipient accepting a push transfer to make progress.
 *      - The two places where the specification mandates an immediate refund
 *        (escrow overpayment, dispute won by the client) attempt a direct send
 *        and fall back to crediting the withdrawable balance if that send fails.
 *        This satisfies "refund in the same transaction" for ordinary wallets
 *        while making it impossible for a reverting recipient to brick a bounty.
 *      - All revert reasons are custom errors: cheaper than strings and they
 *        carry structured data the DApp can decode and display.
 *      - Every state change emits an event, so the DApp can stay in sync purely
 *        from logs with no polling and no page reloads.
 *
 * @dev ACCOUNTING INVARIANT
 *      address(this).balance >= totalEscrowed + totalWithdrawable
 *      Held escrow and credited-but-unclaimed balances are always fully backed.
 *      The test suite asserts this after every state-changing operation.
 */
contract BountyPulse {
    // =========================================================================
    //                                  TYPES
    // =========================================================================

    /// @notice Platform roles. `Unregistered` is the zero value, so an unknown
    ///         address naturally reads as having no role.
    enum Role {
        Unregistered,
        Client,
        Freelancer,
        Arbiter
    }

    /// @notice Bounty lifecycle.
    ///
    ///  None      -> slot never used (zero value; guards against id typos)
    ///  Open      -> posted, accepting bids, no funds held
    ///  Locked    -> a bid was accepted and the exact amount sits in escrow
    ///  Submitted -> the freelancer delivered work (an IPFS CID) for review
    ///  Disputed  -> the client rejected the delivery; awaiting the Arbiter
    ///  Resolved  -> terminal: the freelancer was paid (approval or dispute B)
    ///  Refunded  -> terminal: the client got the escrow back (dispute A)
    ///
    /// `Resolved` and `Refunded` are distinct terminal states on purpose: the
    /// UI, and any future analytics, must be able to tell a successful delivery
    /// apart from a refunded failure without replaying the event log.
    enum BountyStatus {
        None,
        Open,
        Locked,
        Submitted,
        Disputed,
        Resolved,
        Refunded
    }

    /// @notice The Arbiter's verdict on a disputed bounty.
    enum DisputeOutcome {
        FreelancerFault, // escrow returns to the client, freelancer loses reputation
        ClientFault // freelancer is paid the escrow minus the protocol fee
    }

    struct User {
        string name;
        string ipfsAvatarHash;
        Role role;
        uint32 reputation; // freelancers only; clients/arbiter carry 0
        uint64 registeredAt;
        bool isRegistered;
    }

    struct Bounty {
        uint256 id;
        address client;
        address freelancer; // address(0) until escrow is funded
        uint256 maxBudget; // ceiling advertised by the client, in wei
        uint256 escrowAmount; // exact accepted bid held by this contract, in wei
        string ipfsDetailsHash; // CID of the gig brief
        string ipfsWorkHash; // CID of the delivered work (empty until submitted)
        BountyStatus status;
        uint64 createdAt;
        uint64 updatedAt;
    }

    struct Bid {
        address freelancer;
        uint256 amount; // asking price in wei, <= bounty.maxBudget
        uint64 placedAt;
    }

    // =========================================================================
    //                                CONSTANTS
    // =========================================================================

    /// @notice Protocol fee in basis points. 200 bps = 2%.
    uint256 public constant PLATFORM_FEE_BPS = 200;

    /// @notice Basis-point denominator. 10_000 bps = 100%.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Reputation granted to every new freelancer.
    uint32 public constant INITIAL_REPUTATION = 100;

    /// @notice A freelancer whose reputation is strictly below this cannot bid.
    uint32 public constant MIN_BID_REPUTATION = 40;

    /// @notice Reputation awarded when a client approves delivered work.
    uint32 public constant REPUTATION_REWARD = 15;

    /// @notice Reputation removed when the Arbiter rules the freelancer at fault.
    uint32 public constant REPUTATION_PENALTY = 30;

    /// @dev Bounds for IPFS CID strings.
    ///      A CIDv0 ("Qm...", base58) is exactly 46 characters, which is what the
    ///      specification describes. A CIDv1 ("bafybei...", base32) is 59. Pinata
    ///      returns either depending on account configuration, so hard-coding 46
    ///      would reject perfectly valid pins. We validate a sane range instead
    ///      and keep the cheap, decisive check (non-empty) as the real guard.
    uint256 private constant MIN_CID_LENGTH = 32;
    uint256 private constant MAX_CID_LENGTH = 100;

    /// @dev Upper bound on a user's display name. Unbounded strings are a griefing
    ///      vector: they inflate calldata cost for everyone reading the registry.
    uint256 private constant MAX_NAME_LENGTH = 64;

    // =========================================================================
    //                                 STORAGE
    // =========================================================================

    /// @notice Platform overseer, fixed at deployment. Immutable: there is no
    ///         ownership-transfer path, so there is no ownership-takeover risk.
    address public immutable arbiter;

    /// @notice Number of bounties ever posted. Ids are 1-based; id 0 is invalid.
    uint256 public bountyCount;

    /// @notice Wei currently locked in escrow across all `Locked`/`Submitted`/
    ///         `Disputed` bounties.
    uint256 public totalEscrowed;

    /// @notice Sum of every credited-but-unclaimed balance.
    uint256 public totalWithdrawable;

    /// @notice Pull-payment ledger: earnings, fees and failed refunds land here
    ///         and are withdrawn by their owner via {claimFunds}.
    mapping(address => uint256) public withdrawableBalance;

    mapping(address => User) private _users;
    address[] private _registeredUsers;

    mapping(uint256 => Bounty) private _bounties;
    mapping(uint256 => Bid[]) private _bids;

    /// @dev bountyId => freelancer => (index in `_bids[bountyId]`) + 1.
    ///      The +1 offset lets 0 mean "no bid" without a second lookup.
    mapping(uint256 => mapping(address => uint256)) private _bidIndexPlusOne;

    /// @dev Non-reentrancy guard state. 1 = idle, 2 = executing.
    uint256 private _reentrancyStatus = 1;

    // =========================================================================
    //                                  EVENTS
    // =========================================================================
    // Every state transition emits exactly one primary event plus, where money
    // or reputation moves, a secondary ledger event. The DApp reconstructs its
    // entire view from these logs.

    event UserRegistered(
        address indexed user, Role indexed role, string name, string ipfsAvatarHash, uint32 reputation
    );

    event BountyPosted(uint256 indexed bountyId, address indexed client, uint256 maxBudget, string ipfsDetailsHash);

    event BidPlaced(uint256 indexed bountyId, address indexed freelancer, uint256 amount, uint256 bidIndex);

    event EscrowFunded(
        uint256 indexed bountyId,
        address indexed client,
        address indexed freelancer,
        uint256 escrowAmount,
        uint256 refundedExcess
    );

    event WorkSubmitted(uint256 indexed bountyId, address indexed freelancer, string ipfsWorkFileHash);

    event WorkApproved(
        uint256 indexed bountyId,
        address indexed client,
        address indexed freelancer,
        uint256 freelancerPayout,
        uint256 platformFee
    );

    event DisputeRaised(uint256 indexed bountyId, address indexed client, BountyStatus previousStatus);

    event DisputeResolved(
        uint256 indexed bountyId,
        address indexed resolvedBy,
        DisputeOutcome outcome,
        uint256 clientRefund,
        uint256 freelancerPayout,
        uint256 platformFee
    );

    event BountyStatusChanged(uint256 indexed bountyId, BountyStatus previousStatus, BountyStatus newStatus);

    event ReputationChanged(
        address indexed freelancer, uint32 previousScore, uint32 newScore, int256 delta, string reason
    );

    /// @notice Funds added to an account's pull-payment balance.
    event BalanceCredited(address indexed account, uint256 amount, uint256 newBalance);

    /// @notice An account withdrew its accumulated balance.
    event FundsClaimed(address indexed account, uint256 amount);

    /// @notice A same-transaction push transfer succeeded (overpayment refund or
    ///         dispute refund).
    event DirectRefund(address indexed to, uint256 amount);

    /// @notice A push transfer failed and was converted into a claimable balance.
    event RefundDeferred(address indexed to, uint256 amount);

    // =========================================================================
    //                                  ERRORS
    // =========================================================================

    error AlreadyRegistered(address account);
    error NotRegistered(address account);
    error InvalidRole(Role provided);
    error ArbiterIsFixedAtDeployment();
    error EmptyName();
    error NameTooLong(uint256 length, uint256 maxLength);
    error InvalidCid(string cid);
    error CallerIsNotClient(address caller);
    error CallerIsNotFreelancer(address caller);
    error CallerIsNotArbiter(address caller);
    error NotBountyOwner(uint256 bountyId, address caller);
    error NotAwardedFreelancer(uint256 bountyId, address caller);
    error BountyDoesNotExist(uint256 bountyId);
    error InvalidBountyStatus(uint256 bountyId, BountyStatus current, BountyStatus required);
    error ZeroBudget();
    error ZeroBidAmount();
    error BidExceedsBudget(uint256 bidAmount, uint256 maxBudget);
    error ReputationTooLow(uint256 reputation, uint256 required);
    error DuplicateBid(uint256 bountyId, address freelancer);
    error BidNotFound(uint256 bountyId, address freelancer);
    error InsufficientEscrowPayment(uint256 required, uint256 sent);
    error NothingToClaim(address account);
    error TransferFailed(address to, uint256 amount);
    error ReentrantCall();
    error DirectPaymentsNotAccepted();

    // =========================================================================
    //                                MODIFIERS
    // =========================================================================

    /**
     * @dev Minimal reentrancy guard. Two storage writes; no inherited library.
     *      Applied to every function that transfers value, including the ones
     *      that only *might* transfer value through the refund fallback.
     */
    modifier nonReentrant() {
        if (_reentrancyStatus == 2) revert ReentrantCall();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert CallerIsNotArbiter(msg.sender);
        _;
    }

    modifier onlyClient() {
        if (_users[msg.sender].role != Role.Client) revert CallerIsNotClient(msg.sender);
        _;
    }

    modifier onlyFreelancer() {
        if (_users[msg.sender].role != Role.Freelancer) revert CallerIsNotFreelancer(msg.sender);
        _;
    }

    /// @dev Rejects id 0 and any id past the counter before storage is touched.
    modifier bountyExists(uint256 bountyId) {
        if (bountyId == 0 || bountyId > bountyCount) revert BountyDoesNotExist(bountyId);
        _;
    }

    // =========================================================================
    //                               CONSTRUCTOR
    // =========================================================================

    /**
     * @notice Deploys the platform and registers the deployer as the Arbiter.
     * @dev    Registering the Arbiter here — rather than exposing an Arbiter
     *         option in {registerUser} — is what makes the role unforgeable.
     *         There is exactly one Arbiter and it is the deployer, permanently.
     * @param  arbiterName       Display name of the platform overseer.
     * @param  arbiterAvatarCid  IPFS CID of the overseer's avatar.
     */
    constructor(string memory arbiterName, string memory arbiterAvatarCid) {
        _validateName(arbiterName);
        _validateCid(arbiterAvatarCid);

        arbiter = msg.sender;

        _users[msg.sender] = User({
            name: arbiterName,
            ipfsAvatarHash: arbiterAvatarCid,
            role: Role.Arbiter,
            reputation: 0, // reputation is a freelancer-only metric
            registeredAt: uint64(block.timestamp),
            isRegistered: true
        });
        _registeredUsers.push(msg.sender);

        emit UserRegistered(msg.sender, Role.Arbiter, arbiterName, arbiterAvatarCid, 0);
    }

    // =========================================================================
    //                            REGISTRY (SECTION 2.1)
    // =========================================================================

    /**
     * @notice Registers `msg.sender` as a Client or a Freelancer.
     * @dev    One address, one account, forever: re-registration reverts. This
     *         is what makes the contract a trustworthy registry rather than a
     *         mutable profile store, and it is what stops a freelancer from
     *         wiping a reputation penalty by re-registering.
     *
     *         The Arbiter role cannot be requested here — see {constructor}.
     *
     * @param  name        Display name (1..64 bytes).
     * @param  role        Role.Client or Role.Freelancer.
     * @param  avatarCid   IPFS CID of the profile avatar.
     */
    function registerUser(string calldata name, Role role, string calldata avatarCid) external {
        if (_users[msg.sender].isRegistered) revert AlreadyRegistered(msg.sender);
        if (role == Role.Arbiter) revert ArbiterIsFixedAtDeployment();
        if (role != Role.Client && role != Role.Freelancer) revert InvalidRole(role);

        _validateName(name);
        _validateCid(avatarCid);

        // Freelancers start at 100 reputation; the score is meaningless for a
        // client, so it stays at zero rather than being silently misinterpreted.
        uint32 startingReputation = role == Role.Freelancer ? INITIAL_REPUTATION : 0;

        _users[msg.sender] = User({
            name: name,
            ipfsAvatarHash: avatarCid,
            role: role,
            reputation: startingReputation,
            registeredAt: uint64(block.timestamp),
            isRegistered: true
        });
        _registeredUsers.push(msg.sender);

        emit UserRegistered(msg.sender, role, name, avatarCid, startingReputation);
    }

    // =========================================================================
    //                        BOUNTY LIFECYCLE (SECTION 2.2)
    // =========================================================================

    /**
     * @notice Posts a new bounty. Clients only. No ETH is moved at this stage —
     *         `maxBudget` is an advertised ceiling, not a deposit.
     * @param  maxBudget   Maximum the client is willing to pay, in wei.
     * @param  detailsCid  IPFS CID of the gig description.
     * @return bountyId    The 1-based id of the new bounty.
     */
    function postBounty(uint256 maxBudget, string calldata detailsCid)
        external
        onlyClient
        returns (uint256 bountyId)
    {
        if (maxBudget == 0) revert ZeroBudget();
        _validateCid(detailsCid);

        bountyId = ++bountyCount;

        _bounties[bountyId] = Bounty({
            id: bountyId,
            client: msg.sender,
            freelancer: address(0),
            maxBudget: maxBudget,
            escrowAmount: 0,
            ipfsDetailsHash: detailsCid,
            ipfsWorkHash: "",
            status: BountyStatus.Open,
            createdAt: uint64(block.timestamp),
            updatedAt: uint64(block.timestamp)
        });

        emit BountyPosted(bountyId, msg.sender, maxBudget, detailsCid);
        emit BountyStatusChanged(bountyId, BountyStatus.None, BountyStatus.Open);
    }

    /**
     * @notice Submits a price quote for an open bounty.
     *
     * @dev    NON-PAYABLE BY DESIGN. A bid is a promise to work for a price, not
     *         a deposit. The absence of the `payable` keyword makes it impossible
     *         for this function to accept ETH: the EVM reverts any call carrying
     *         value before a single line of this body executes.
     *
     *         Two gates, both from the specification:
     *           1. Budget ceiling  - the quote may not exceed the client's cap.
     *           2. Reputation gate - a freelancer below 40 reputation is barred.
     *
     *         One bid per freelancer per bounty. Replacing a bid would let a
     *         freelancer front-run competitors by re-quoting after seeing their
     *         numbers, so the quote is final.
     *
     * @param  bountyId Bounty being bid on.
     * @param  amount   Asking price in wei.
     */
    function placeBid(uint256 bountyId, uint256 amount) external onlyFreelancer bountyExists(bountyId) {
        Bounty storage bounty = _bounties[bountyId];
        if (bounty.status != BountyStatus.Open) {
            revert InvalidBountyStatus(bountyId, bounty.status, BountyStatus.Open);
        }
        if (amount == 0) revert ZeroBidAmount();
        if (amount > bounty.maxBudget) revert BidExceedsBudget(amount, bounty.maxBudget);

        uint32 reputation = _users[msg.sender].reputation;
        if (reputation < MIN_BID_REPUTATION) revert ReputationTooLow(reputation, MIN_BID_REPUTATION);

        if (_bidIndexPlusOne[bountyId][msg.sender] != 0) revert DuplicateBid(bountyId, msg.sender);

        _bids[bountyId].push(Bid({freelancer: msg.sender, amount: amount, placedAt: uint64(block.timestamp)}));
        uint256 bidIndex = _bids[bountyId].length - 1;
        _bidIndexPlusOne[bountyId][msg.sender] = bidIndex + 1;

        emit BidPlaced(bountyId, msg.sender, amount, bidIndex);
    }

    /**
     * @notice Accepts a bid and locks the exact quoted amount into escrow.
     *
     * @dev    STRICT PAYMENT CONSTRAINT (specification 2.2.3):
     *           msg.value <  bid   -> revert, nothing is kept
     *           msg.value == bid   -> exact escrow, no refund
     *           msg.value >  bid   -> exact escrow, excess returned immediately
     *
     *         The refund is attempted as a direct send inside this transaction,
     *         as specified. If the client is a contract that rejects ETH, the
     *         excess becomes a claimable balance instead of reverting the whole
     *         funding — the bounty must not be blocked by the caller's fallback.
     *
     *         Checks-Effects-Interactions: escrow accounting and the status
     *         transition are complete before the refund call is made, and the
     *         function is `nonReentrant`.
     *
     * @param  bountyId   Bounty to fund.
     * @param  freelancer Address of the winning bidder.
     */
    function fundEscrow(uint256 bountyId, address freelancer) external payable nonReentrant bountyExists(bountyId) {
        Bounty storage bounty = _bounties[bountyId];

        if (msg.sender != bounty.client) revert NotBountyOwner(bountyId, msg.sender);
        if (bounty.status != BountyStatus.Open) {
            revert InvalidBountyStatus(bountyId, bounty.status, BountyStatus.Open);
        }

        uint256 indexPlusOne = _bidIndexPlusOne[bountyId][freelancer];
        if (indexPlusOne == 0) revert BidNotFound(bountyId, freelancer);

        uint256 bidAmount = _bids[bountyId][indexPlusOne - 1].amount;

        // Underpayment reverts the entire transaction; the EVM returns every wei
        // of msg.value to the caller automatically.
        if (msg.value < bidAmount) revert InsufficientEscrowPayment(bidAmount, msg.value);

        uint256 excess = msg.value - bidAmount;

        // ---- Effects -------------------------------------------------------
        bounty.freelancer = freelancer;
        bounty.escrowAmount = bidAmount;
        bounty.updatedAt = uint64(block.timestamp);
        totalEscrowed += bidAmount;
        _setStatus(bounty, BountyStatus.Locked);

        emit EscrowFunded(bountyId, msg.sender, freelancer, bidAmount, excess);

        // ---- Interactions --------------------------------------------------
        if (excess > 0) _refundOrCredit(msg.sender, excess);
    }

    /**
     * @notice Delivers the finished work as an IPFS CID.
     * @param  bountyId    Bounty being delivered.
     * @param  workFileCid IPFS CID of the deliverable.
     */
    function submitWork(uint256 bountyId, string calldata workFileCid) external bountyExists(bountyId) {
        Bounty storage bounty = _bounties[bountyId];

        if (msg.sender != bounty.freelancer) revert NotAwardedFreelancer(bountyId, msg.sender);
        if (bounty.status != BountyStatus.Locked) {
            revert InvalidBountyStatus(bountyId, bounty.status, BountyStatus.Locked);
        }
        _validateCid(workFileCid);

        bounty.ipfsWorkHash = workFileCid;
        bounty.updatedAt = uint64(block.timestamp);
        _setStatus(bounty, BountyStatus.Submitted);

        emit WorkSubmitted(bountyId, msg.sender, workFileCid);
    }

    /**
     * @notice Approves delivered work, releasing escrow.
     *
     * @dev    PERCENTAGE MATH: a 2% protocol fee is credited to the Arbiter and
     *         the remaining 98% is credited to the freelancer. Integer division
     *         floors the fee, so any rounding dust favours the freelancer, and
     *         `fee + payout == escrow` holds exactly for every possible amount.
     *         No wei is ever stranded in the contract.
     *
     *         PULL PAYMENT: nothing is sent here. Both parties call
     *         {claimFunds}. A push transfer to a freelancer contract with an
     *         expensive or reverting fallback would let that freelancer hold the
     *         client's approval hostage.
     *
     * @param  bountyId Bounty to approve.
     */
    function approveWork(uint256 bountyId) external bountyExists(bountyId) {
        Bounty storage bounty = _bounties[bountyId];

        if (msg.sender != bounty.client) revert NotBountyOwner(bountyId, msg.sender);
        if (bounty.status != BountyStatus.Submitted) {
            revert InvalidBountyStatus(bountyId, bounty.status, BountyStatus.Submitted);
        }

        uint256 escrow = bounty.escrowAmount;
        (uint256 fee, uint256 payout) = previewFeeSplit(escrow);
        address freelancer = bounty.freelancer;

        // ---- Effects (no external calls in this function at all) -----------
        bounty.updatedAt = uint64(block.timestamp);
        totalEscrowed -= escrow;
        _setStatus(bounty, BountyStatus.Resolved);

        _credit(freelancer, payout);
        _credit(arbiter, fee);
        _increaseReputation(freelancer, REPUTATION_REWARD, "work_approved");

        emit WorkApproved(bountyId, msg.sender, freelancer, payout, fee);
    }

    /**
     * @notice Flags delivered work as unsatisfactory and escalates to the Arbiter.
     * @dev    Permitted from `Locked` as well as `Submitted`. Without that, a
     *         freelancer who takes the job and vanishes would trap the client's
     *         escrow forever with no path to recovery.
     * @param  bountyId Bounty to dispute.
     */
    function raiseDispute(uint256 bountyId) external bountyExists(bountyId) {
        Bounty storage bounty = _bounties[bountyId];

        if (msg.sender != bounty.client) revert NotBountyOwner(bountyId, msg.sender);

        BountyStatus current = bounty.status;
        if (current != BountyStatus.Submitted && current != BountyStatus.Locked) {
            revert InvalidBountyStatus(bountyId, current, BountyStatus.Submitted);
        }

        bounty.updatedAt = uint64(block.timestamp);
        _setStatus(bounty, BountyStatus.Disputed);

        emit DisputeRaised(bountyId, msg.sender, current);
    }

    /**
     * @notice Arbiter's binding verdict on a disputed bounty.
     *
     * @dev    Outcome A - FreelancerFault:
     *             100% of the escrow goes back to the client (direct send, with
     *             a claimable-balance fallback) and the freelancer loses 30
     *             reputation, floored at 0. No fee is taken: the platform does
     *             not profit from a failed engagement.
     *
     *         Outcome B - ClientFault:
     *             the freelancer is credited the escrow minus the 2% fee, which
     *             goes to the Arbiter. Reputation is unchanged — the freelancer
     *             did nothing wrong, and the specification awards the +15 bonus
     *             only for an approved delivery.
     *
     * @param  bountyId Disputed bounty.
     * @param  outcome  The verdict.
     */
    function resolveDispute(uint256 bountyId, DisputeOutcome outcome)
        external
        onlyArbiter
        nonReentrant
        bountyExists(bountyId)
    {
        Bounty storage bounty = _bounties[bountyId];

        if (bounty.status != BountyStatus.Disputed) {
            revert InvalidBountyStatus(bountyId, bounty.status, BountyStatus.Disputed);
        }

        uint256 escrow = bounty.escrowAmount;
        address client = bounty.client;
        address freelancer = bounty.freelancer;

        // ---- Effects -------------------------------------------------------
        bounty.updatedAt = uint64(block.timestamp);
        totalEscrowed -= escrow;

        uint256 clientRefund;
        uint256 freelancerPayout;
        uint256 fee;

        if (outcome == DisputeOutcome.FreelancerFault) {
            clientRefund = escrow;
            _setStatus(bounty, BountyStatus.Refunded);
            _decreaseReputation(freelancer, REPUTATION_PENALTY, "dispute_lost");
        } else {
            (fee, freelancerPayout) = previewFeeSplit(escrow);
            _setStatus(bounty, BountyStatus.Resolved);
            _credit(freelancer, freelancerPayout);
            _credit(arbiter, fee);
        }

        emit DisputeResolved(bountyId, msg.sender, outcome, clientRefund, freelancerPayout, fee);

        // ---- Interactions --------------------------------------------------
        if (clientRefund > 0) _refundOrCredit(client, clientRefund);
    }

    /**
     * @notice Withdraws the caller's accumulated balance to their wallet.
     * @dev    The one and only ETH exit for earnings and fees. Deliberately not
     *         role-gated: freelancer payouts, Arbiter fees and deferred client
     *         refunds all live in the same ledger, and the balance itself is the
     *         authorization. Balance is zeroed before the transfer.
     * @return amount The amount withdrawn, in wei.
     */
    function claimFunds() external nonReentrant returns (uint256 amount) {
        amount = withdrawableBalance[msg.sender];
        if (amount == 0) revert NothingToClaim(msg.sender);

        // ---- Effects (before the call: this is the reentrancy fix) ---------
        withdrawableBalance[msg.sender] = 0;
        totalWithdrawable -= amount;

        emit FundsClaimed(msg.sender, amount);

        // ---- Interactions --------------------------------------------------
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed(msg.sender, amount);
    }

    // =========================================================================
    //                             INTERNAL HELPERS
    // =========================================================================

    function _setStatus(Bounty storage bounty, BountyStatus newStatus) private {
        BountyStatus previous = bounty.status;
        bounty.status = newStatus;
        emit BountyStatusChanged(bounty.id, previous, newStatus);
    }

    /// @dev Single entry point for the pull-payment ledger so `totalWithdrawable`
    ///      can never drift out of step with the individual balances.
    function _credit(address account, uint256 amount) private {
        if (amount == 0) return;
        uint256 newBalance = withdrawableBalance[account] + amount;
        withdrawableBalance[account] = newBalance;
        totalWithdrawable += amount;
        emit BalanceCredited(account, amount, newBalance);
    }

    /**
     * @dev Attempts an immediate refund, degrading to a claimable balance.
     *      MUST be called last (interactions phase) from a `nonReentrant`
     *      function: it hands control to an arbitrary address.
     */
    function _refundOrCredit(address to, uint256 amount) private {
        (bool sent,) = payable(to).call{value: amount}("");
        if (sent) {
            emit DirectRefund(to, amount);
        } else {
            _credit(to, amount);
            emit RefundDeferred(to, amount);
        }
    }

    function _increaseReputation(address freelancer, uint32 delta, string memory reason) private {
        uint32 previous = _users[freelancer].reputation;
        uint32 updated = previous + delta; // uint32 headroom is enormous; 0.8.x reverts on overflow
        _users[freelancer].reputation = updated;
        emit ReputationChanged(freelancer, previous, updated, int256(uint256(delta)), reason);
    }

    /// @dev Saturating subtraction: reputation floors at 0 instead of underflowing.
    function _decreaseReputation(address freelancer, uint32 delta, string memory reason) private {
        uint32 previous = _users[freelancer].reputation;
        uint32 updated = previous > delta ? previous - delta : 0;
        _users[freelancer].reputation = updated;
        emit ReputationChanged(freelancer, previous, updated, -int256(uint256(previous - updated)), reason);
    }

    function _validateName(string memory name) private pure {
        uint256 length = bytes(name).length;
        if (length == 0) revert EmptyName();
        if (length > MAX_NAME_LENGTH) revert NameTooLong(length, MAX_NAME_LENGTH);
    }

    function _validateCid(string memory cid) private pure {
        uint256 length = bytes(cid).length;
        if (length < MIN_CID_LENGTH || length > MAX_CID_LENGTH) revert InvalidCid(cid);
    }

    // =========================================================================
    //                              VIEW FUNCTIONS
    // =========================================================================
    //
    // GAS NOTE (specification 3.2)
    // These are `view` functions. When the DApp calls them through `eth_call`
    // they execute on the node and cost the user nothing. That is precisely why
    // BountyPulse exposes raw, unsorted collections and does all filtering and
    // sorting in JavaScript: an on-chain sort would burn real gas on every read
    // and would have to be paid for by whoever triggered it. Sorting 200 bounties
    // on-chain costs an O(n log n) pile of SLOADs; sorting them in the browser
    // costs nothing. See frontend/js/app.js > sortBounties.
    // =========================================================================

    /// @notice Splits an escrow amount into the protocol fee and the payout.
    /// @dev    `pure`, so the DApp and the tests can verify the arithmetic
    ///         without touching state. fee + payout == amount, always.
    function previewFeeSplit(uint256 amount) public pure returns (uint256 fee, uint256 payout) {
        fee = (amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        payout = amount - fee;
    }

    function getUser(address account) external view returns (User memory) {
        return _users[account];
    }

    function isRegistered(address account) external view returns (bool) {
        return _users[account].isRegistered;
    }

    function getRole(address account) external view returns (Role) {
        return _users[account].role;
    }

    function getReputation(address account) external view returns (uint32) {
        return _users[account].reputation;
    }

    /// @notice True when `account` currently satisfies the bidding reputation gate.
    function canBid(address account) external view returns (bool) {
        User storage user = _users[account];
        return user.role == Role.Freelancer && user.reputation >= MIN_BID_REPUTATION;
    }

    function getRegisteredUserCount() external view returns (uint256) {
        return _registeredUsers.length;
    }

    function getRegisteredUsers() external view returns (address[] memory) {
        return _registeredUsers;
    }

    function getBounty(uint256 bountyId) external view bountyExists(bountyId) returns (Bounty memory) {
        return _bounties[bountyId];
    }

    /**
     * @notice Returns every bounty, oldest first.
     * @dev    Unbounded loop, intentionally: this is a `view` helper for an
     *         `eth_call`, never reachable from a transaction, so it consumes no
     *         user gas. For a large deployment the DApp should page with
     *         {getBountiesPaged}; the RPC node's own gas cap, not the chain, is
     *         the limit here.
     */
    function getAllBounties() external view returns (Bounty[] memory bounties) {
        uint256 count = bountyCount;
        bounties = new Bounty[](count);
        for (uint256 i = 0; i < count; ++i) {
            bounties[i] = _bounties[i + 1]; // ids are 1-based
        }
    }

    /**
     * @notice Page through bounties, oldest first.
     * @param  offset Zero-based index into the id space (id = offset + 1).
     * @param  limit  Maximum number of bounties to return.
     */
    function getBountiesPaged(uint256 offset, uint256 limit)
        external
        view
        returns (Bounty[] memory bounties, uint256 total)
    {
        total = bountyCount;
        if (offset >= total) return (new Bounty[](0), total);

        uint256 remaining = total - offset;
        uint256 size = remaining < limit ? remaining : limit;

        bounties = new Bounty[](size);
        for (uint256 i = 0; i < size; ++i) {
            bounties[i] = _bounties[offset + i + 1];
        }
    }

    function getBids(uint256 bountyId) external view bountyExists(bountyId) returns (Bid[] memory) {
        return _bids[bountyId];
    }

    function getBidCount(uint256 bountyId) external view returns (uint256) {
        return _bids[bountyId].length;
    }

    /// @notice Returns the bid `freelancer` placed on `bountyId`.
    /// @dev    Reverts when no such bid exists, so the caller can never mistake
    ///         a zero-filled struct for a real 0-wei quote.
    function getBid(uint256 bountyId, address freelancer) external view bountyExists(bountyId) returns (Bid memory) {
        uint256 indexPlusOne = _bidIndexPlusOne[bountyId][freelancer];
        if (indexPlusOne == 0) revert BidNotFound(bountyId, freelancer);
        return _bids[bountyId][indexPlusOne - 1];
    }

    function hasBid(uint256 bountyId, address freelancer) external view returns (bool) {
        return _bidIndexPlusOne[bountyId][freelancer] != 0;
    }

    /// @notice Unclaimed earnings for the DApp's "Unclaimed Earnings" tracker.
    function getWithdrawableBalance(address account) external view returns (uint256) {
        return withdrawableBalance[account];
    }

    /// @notice Total ETH this contract owes: live escrow plus unclaimed balances.
    /// @dev    `address(this).balance` must always be >= this value.
    function totalLiabilities() external view returns (uint256) {
        return totalEscrowed + totalWithdrawable;
    }

    // =========================================================================
    //                           FALLBACK PROTECTION
    // =========================================================================

    /**
     * @dev The contract accepts ETH exclusively through {fundEscrow}. A bare
     *      transfer has no bounty to attach itself to and would become
     *      permanently unrecoverable, so it is rejected loudly instead of
     *      silently swallowed.
     *
     *      Note this does NOT break {_refundOrCredit}: that path sends ETH out,
     *      it never receives.
     */
    receive() external payable {
        revert DirectPaymentsNotAccepted();
    }

    fallback() external payable {
        revert DirectPaymentsNotAccepted();
    }
}
