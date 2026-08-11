// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BountyPulse} from "../src/BountyPulse.sol";

/*//////////////////////////////////////////////////////////////////////////////
                              TEST DOUBLES
//////////////////////////////////////////////////////////////////////////////*/

/// @dev A Client implemented as a contract whose `receive` always reverts. Used
///      to prove that a rejecting recipient cannot brick escrow funding: the
///      overpayment refund degrades to a claimable balance instead of reverting.
contract EthRejectingClient {
    BountyPulse private immutable pulse;

    constructor(BountyPulse pulse_) {
        pulse = pulse_;
    }

    function register(string calldata name, string calldata cid) external {
        pulse.registerUser(name, BountyPulse.Role.Client, cid);
    }

    function postBounty(uint256 budget, string calldata cid) external returns (uint256) {
        return pulse.postBounty(budget, cid);
    }

    function fund(uint256 bountyId, address freelancer, uint256 value) external {
        pulse.fundEscrow{value: value}(bountyId, freelancer);
    }

    function claim() external {
        pulse.claimFunds();
    }

    receive() external payable {
        revert("EthRejectingClient: no ETH accepted");
    }
}

/// @dev A Freelancer that tries to re-enter {claimFunds} from its `receive`
///      hook. The re-entry is wrapped in try/catch so the attack is observable
///      rather than simply bubbling up as a failed transfer.
contract ReentrantFreelancer {
    BountyPulse private immutable pulse;

    uint256 public reentryAttempts;
    bool public reentryReverted;

    constructor(BountyPulse pulse_) {
        pulse = pulse_;
    }

    function register(string calldata name, string calldata cid) external {
        pulse.registerUser(name, BountyPulse.Role.Freelancer, cid);
    }

    function bid(uint256 bountyId, uint256 amount) external {
        pulse.placeBid(bountyId, amount);
    }

    function submit(uint256 bountyId, string calldata cid) external {
        pulse.submitWork(bountyId, cid);
    }

    function claim() external {
        pulse.claimFunds();
    }

    receive() external payable {
        if (reentryAttempts == 0) {
            reentryAttempts = 1;
            try pulse.claimFunds() {
            // Reaching here would mean the guard failed and funds were paid twice.
            }
            catch {
                reentryReverted = true;
            }
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////////
                                 TEST SUITE
//////////////////////////////////////////////////////////////////////////////*/

contract BountyPulseTest is Test {
    BountyPulse internal pulse;

    address internal arbiter = makeAddr("arbiter");
    address internal client = makeAddr("client");
    address internal client2 = makeAddr("client2");
    address internal freelancer = makeAddr("freelancer");
    address internal freelancer2 = makeAddr("freelancer2");
    address internal stranger = makeAddr("stranger");

    // A real 46-character CIDv0, the length the specification describes.
    string internal constant AVATAR_CID = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG";
    string internal constant DETAILS_CID = "QmT78zSuBmuS4z925WZfrqQ1qHaJ56DQaTfyMUF7F8ff5o";
    string internal constant WORK_CID = "QmRAQB6YaCyidP37UdDnjFY5vQuiBrcqdyoW1CuDgwxkD4";
    // A CIDv1 (base32, 59 chars) — must also be accepted.
    string internal constant CID_V1 = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

    uint256 internal constant BID = 1 ether;
    uint256 internal constant BUDGET = 2 ether;

    /*//////////////////////////////////////////////////////////////////////////
                            EVENT MIRRORS (for expectEmit)
    //////////////////////////////////////////////////////////////////////////*/
    // Re-declared with identical names, types and `indexed` positions so that
    // topic0 and the topic layout match the contract's events exactly.

    event UserRegistered(
        address indexed user, BountyPulse.Role indexed role, string name, string ipfsAvatarHash, uint32 reputation
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
    event DisputeRaised(uint256 indexed bountyId, address indexed client, BountyPulse.BountyStatus previousStatus);
    event DisputeResolved(
        uint256 indexed bountyId,
        address indexed resolvedBy,
        BountyPulse.DisputeOutcome outcome,
        uint256 clientRefund,
        uint256 freelancerPayout,
        uint256 platformFee
    );
    event BountyStatusChanged(
        uint256 indexed bountyId, BountyPulse.BountyStatus previousStatus, BountyPulse.BountyStatus newStatus
    );
    event ReputationChanged(
        address indexed freelancer, uint32 previousScore, uint32 newScore, int256 delta, string reason
    );
    event BalanceCredited(address indexed account, uint256 amount, uint256 newBalance);
    event FundsClaimed(address indexed account, uint256 amount);
    event DirectRefund(address indexed to, uint256 amount);
    event RefundDeferred(address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                     SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public {
        vm.prank(arbiter);
        pulse = new BountyPulse("BountyPulse Arbiter", AVATAR_CID);

        vm.deal(client, 100 ether);
        vm.deal(client2, 100 ether);
        vm.deal(freelancer, 1 ether);
        vm.deal(stranger, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _registerClient(address who) internal {
        vm.prank(who);
        pulse.registerUser("Acme Corp", BountyPulse.Role.Client, AVATAR_CID);
    }

    function _registerFreelancer(address who) internal {
        vm.prank(who);
        pulse.registerUser("Ada Dev", BountyPulse.Role.Freelancer, AVATAR_CID);
    }

    function _postBounty(address who, uint256 budget) internal returns (uint256 bountyId) {
        vm.prank(who);
        bountyId = pulse.postBounty(budget, DETAILS_CID);
    }

    function _bid(address who, uint256 bountyId, uint256 amount) internal {
        vm.prank(who);
        pulse.placeBid(bountyId, amount);
    }

    function _fund(address who, uint256 bountyId, address winner, uint256 value) internal {
        vm.prank(who);
        pulse.fundEscrow{value: value}(bountyId, winner);
    }

    /// @dev Fast-forward to a `Submitted` bounty with `BID` in escrow.
    function _scenarioSubmitted() internal returns (uint256 bountyId) {
        _registerClient(client);
        _registerFreelancer(freelancer);
        bountyId = _postBounty(client, BUDGET);
        _bid(freelancer, bountyId, BID);
        _fund(client, bountyId, freelancer, BID);
        vm.prank(freelancer);
        pulse.submitWork(bountyId, WORK_CID);
    }

    /// @dev The core solvency invariant. Asserted after every money-moving test.
    function _assertSolvent() internal view {
        assertGe(
            address(pulse).balance,
            pulse.totalEscrowed() + pulse.totalWithdrawable(),
            "INSOLVENT: contract balance does not cover escrow + unclaimed balances"
        );
    }

    function _status(uint256 bountyId) internal view returns (BountyPulse.BountyStatus) {
        return pulse.getBounty(bountyId).status;
    }

    /*//////////////////////////////////////////////////////////////////////////
                          1. DEPLOYMENT & ARBITER ROLE
    //////////////////////////////////////////////////////////////////////////*/

    function test_Deployment_RegistersDeployerAsArbiter() public view {
        assertEq(pulse.arbiter(), arbiter, "deployer must be the arbiter");

        BountyPulse.User memory user = pulse.getUser(arbiter);
        assertTrue(user.isRegistered);
        assertEq(uint8(user.role), uint8(BountyPulse.Role.Arbiter));
        assertEq(user.name, "BountyPulse Arbiter");
        assertEq(user.ipfsAvatarHash, AVATAR_CID);
        assertEq(user.reputation, 0, "reputation is a freelancer-only metric");
    }

    function test_Deployment_ConstantsMatchSpecification() public view {
        assertEq(pulse.PLATFORM_FEE_BPS(), 200, "2% fee");
        assertEq(pulse.BPS_DENOMINATOR(), 10_000);
        assertEq(pulse.INITIAL_REPUTATION(), 100);
        assertEq(pulse.MIN_BID_REPUTATION(), 40);
        assertEq(pulse.REPUTATION_REWARD(), 15);
        assertEq(pulse.REPUTATION_PENALTY(), 30);
        assertEq(pulse.bountyCount(), 0);
    }

    function test_Deployment_RevertWhen_NameEmpty() public {
        vm.expectRevert(BountyPulse.EmptyName.selector);
        new BountyPulse("", AVATAR_CID);
    }

    function test_Deployment_RevertWhen_AvatarCidInvalid() public {
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.InvalidCid.selector, "too-short"));
        new BountyPulse("Arbiter", "too-short");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        2. REGISTRY (spec 2.1) — registration
    //////////////////////////////////////////////////////////////////////////*/

    function test_RegisterUser_Client() public {
        vm.expectEmit(true, true, true, true, address(pulse));
        emit UserRegistered(client, BountyPulse.Role.Client, "Acme Corp", AVATAR_CID, 0);
        _registerClient(client);

        BountyPulse.User memory user = pulse.getUser(client);
        assertTrue(user.isRegistered);
        assertEq(uint8(user.role), uint8(BountyPulse.Role.Client));
        assertEq(user.reputation, 0, "clients carry no reputation score");
        assertEq(user.registeredAt, uint64(block.timestamp));
    }

    function test_RegisterUser_FreelancerStartsWith100Reputation() public {
        vm.expectEmit(true, true, true, true, address(pulse));
        emit UserRegistered(freelancer, BountyPulse.Role.Freelancer, "Ada Dev", AVATAR_CID, 100);
        _registerFreelancer(freelancer);

        assertEq(pulse.getReputation(freelancer), 100, "freelancers must start at exactly 100");
        assertTrue(pulse.canBid(freelancer));
    }

    /// @notice SPEC: "A wallet address cannot be registered twice."
    function test_RegisterUser_RevertWhen_AlreadyRegistered() public {
        _registerClient(client);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.AlreadyRegistered.selector, client));
        pulse.registerUser("Acme Corp Again", BountyPulse.Role.Client, AVATAR_CID);
    }

    /// @notice A duplicate registration must not be possible even when switching role,
    ///         otherwise a penalised freelancer could launder their reputation.
    function test_RegisterUser_RevertWhen_AlreadyRegisteredWithDifferentRole() public {
        _registerFreelancer(freelancer);

        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.AlreadyRegistered.selector, freelancer));
        pulse.registerUser("Ada Dev", BountyPulse.Role.Client, AVATAR_CID);
    }

    function test_RegisterUser_RevertWhen_ArbiterTriesToReRegister() public {
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.AlreadyRegistered.selector, arbiter));
        pulse.registerUser("Sneaky", BountyPulse.Role.Client, AVATAR_CID);
    }

    function test_RegisterUser_RevertWhen_ClaimingArbiterRole() public {
        vm.prank(stranger);
        vm.expectRevert(BountyPulse.ArbiterIsFixedAtDeployment.selector);
        pulse.registerUser("Fake Admin", BountyPulse.Role.Arbiter, AVATAR_CID);
    }

    function test_RegisterUser_RevertWhen_RoleIsUnregisteredSentinel() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.InvalidRole.selector, BountyPulse.Role.Unregistered));
        pulse.registerUser("Nobody", BountyPulse.Role.Unregistered, AVATAR_CID);
    }

    function test_RegisterUser_RevertWhen_NameEmpty() public {
        vm.prank(stranger);
        vm.expectRevert(BountyPulse.EmptyName.selector);
        pulse.registerUser("", BountyPulse.Role.Client, AVATAR_CID);
    }

    function test_RegisterUser_RevertWhen_NameTooLong() public {
        string memory long = "0123456789012345678901234567890123456789012345678901234567890123456789";
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.NameTooLong.selector, bytes(long).length, 64));
        pulse.registerUser(long, BountyPulse.Role.Client, AVATAR_CID);
    }

    function test_RegisterUser_RevertWhen_CidTooShort() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.InvalidCid.selector, "Qm123"));
        pulse.registerUser("Ada", BountyPulse.Role.Freelancer, "Qm123");
    }

    function test_RegisterUser_AcceptsCidV0AndCidV1() public {
        assertEq(bytes(AVATAR_CID).length, 46, "CIDv0 is 46 characters");
        assertEq(bytes(CID_V1).length, 59, "CIDv1 base32 is 59 characters");

        _registerClient(client);
        vm.prank(freelancer);
        pulse.registerUser("Ada Dev", BountyPulse.Role.Freelancer, CID_V1);

        assertEq(pulse.getUser(freelancer).ipfsAvatarHash, CID_V1);
    }

    function test_RegisterUser_EnumeratesRegistry() public {
        _registerClient(client);
        _registerFreelancer(freelancer);

        assertEq(pulse.getRegisteredUserCount(), 3, "arbiter + client + freelancer");
        address[] memory users = pulse.getRegisteredUsers();
        assertEq(users[0], arbiter);
        assertEq(users[1], client);
        assertEq(users[2], freelancer);
    }

    function test_UnregisteredAddress_ReadsAsRoleUnregistered() public view {
        assertFalse(pulse.isRegistered(stranger));
        assertEq(uint8(pulse.getRole(stranger)), uint8(BountyPulse.Role.Unregistered));
        assertFalse(pulse.canBid(stranger));
    }

    /*//////////////////////////////////////////////////////////////////////////
                          3. POST BOUNTY (spec 2.2.1)
    //////////////////////////////////////////////////////////////////////////*/

    function test_PostBounty_CreatesOpenBountyWithoutMovingEth() public {
        _registerClient(client);

        vm.expectEmit(true, true, true, true, address(pulse));
        emit BountyPosted(1, client, BUDGET, DETAILS_CID);
        uint256 id = _postBounty(client, BUDGET);

        assertEq(id, 1, "ids are 1-based");
        assertEq(pulse.bountyCount(), 1);

        BountyPulse.Bounty memory bounty = pulse.getBounty(id);
        assertEq(bounty.client, client);
        assertEq(bounty.freelancer, address(0), "no winner yet");
        assertEq(bounty.maxBudget, BUDGET);
        assertEq(bounty.escrowAmount, 0, "posting must not lock funds");
        assertEq(bounty.ipfsDetailsHash, DETAILS_CID);
        assertEq(bounty.ipfsWorkHash, "");
        assertEq(uint8(bounty.status), uint8(BountyPulse.BountyStatus.Open));
        assertEq(address(pulse).balance, 0);
    }

    function test_PostBounty_RevertWhen_CallerIsFreelancer() public {
        _registerFreelancer(freelancer);

        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.CallerIsNotClient.selector, freelancer));
        pulse.postBounty(BUDGET, DETAILS_CID);
    }

    function test_PostBounty_RevertWhen_CallerUnregistered() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.CallerIsNotClient.selector, stranger));
        pulse.postBounty(BUDGET, DETAILS_CID);
    }

    function test_PostBounty_RevertWhen_CallerIsArbiter() public {
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.CallerIsNotClient.selector, arbiter));
        pulse.postBounty(BUDGET, DETAILS_CID);
    }

    function test_PostBounty_RevertWhen_BudgetIsZero() public {
        _registerClient(client);
        vm.prank(client);
        vm.expectRevert(BountyPulse.ZeroBudget.selector);
        pulse.postBounty(0, DETAILS_CID);
    }

    function test_PostBounty_RevertWhen_DetailsCidInvalid() public {
        _registerClient(client);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.InvalidCid.selector, ""));
        pulse.postBounty(BUDGET, "");
    }

    function test_GetBounty_RevertWhen_IdDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.BountyDoesNotExist.selector, 0));
        pulse.getBounty(0);

        vm.expectRevert(abi.encodeWithSelector(BountyPulse.BountyDoesNotExist.selector, 99));
        pulse.getBounty(99);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        4. BIDDER REGISTRY (spec 2.2.2)
    //////////////////////////////////////////////////////////////////////////*/

    function test_PlaceBid_StoresQuote() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);

        vm.expectEmit(true, true, true, true, address(pulse));
        emit BidPlaced(id, freelancer, BID, 0);
        _bid(freelancer, id, BID);

        assertEq(pulse.getBidCount(id), 1);
        assertTrue(pulse.hasBid(id, freelancer));

        BountyPulse.Bid memory bid = pulse.getBid(id, freelancer);
        assertEq(bid.freelancer, freelancer);
        assertEq(bid.amount, BID);
        assertEq(address(pulse).balance, 0, "bidding must never move ETH");
    }

    /// @notice SPEC: "This function must be non-payable."
    /// @dev    Proven at the EVM level: a call carrying value cannot execute a
    ///         non-payable function, so the call fails and nothing is recorded.
    function test_PlaceBid_IsNonPayable() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);

        vm.deal(freelancer, 5 ether);
        vm.prank(freelancer);
        (bool ok,) =
            address(pulse).call{value: 1 ether}(abi.encodeWithSelector(BountyPulse.placeBid.selector, id, BID));

        assertFalse(ok, "placeBid must reject any ETH-carrying call");
        assertEq(pulse.getBidCount(id), 0, "no bid recorded");
        assertEq(address(pulse).balance, 0, "no ETH captured");
    }

    /// @notice SPEC constraint: Budget Ceiling.
    function test_PlaceBid_RevertWhen_BidExceedsMaxBudget() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);

        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.BidExceedsBudget.selector, BUDGET + 1, BUDGET));
        pulse.placeBid(id, BUDGET + 1);
    }

    function test_PlaceBid_AtExactlyMaxBudget_Succeeds() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);

        _bid(freelancer, id, BUDGET); // boundary: <= is allowed
        assertEq(pulse.getBid(id, freelancer).amount, BUDGET);
    }

    function test_PlaceBid_RevertWhen_AmountIsZero() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);

        vm.prank(freelancer);
        vm.expectRevert(BountyPulse.ZeroBidAmount.selector);
        pulse.placeBid(id, 0);
    }

    function test_PlaceBid_RevertWhen_CallerIsClient() public {
        _registerClient(client);
        uint256 id = _postBounty(client, BUDGET);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.CallerIsNotFreelancer.selector, client));
        pulse.placeBid(id, BID);
    }

    function test_PlaceBid_RevertWhen_DuplicateBid() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);

        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.DuplicateBid.selector, id, freelancer));
        pulse.placeBid(id, BID - 1);
    }

    function test_PlaceBid_RevertWhen_BountyNotOpen() public {
        uint256 id = _scenarioSubmitted();
        _registerFreelancer(freelancer2);

        vm.prank(freelancer2);
        vm.expectRevert(
            abi.encodeWithSelector(
                BountyPulse.InvalidBountyStatus.selector,
                id,
                BountyPulse.BountyStatus.Submitted,
                BountyPulse.BountyStatus.Open
            )
        );
        pulse.placeBid(id, 0.5 ether);
    }

    function test_PlaceBid_RevertWhen_BountyDoesNotExist() public {
        _registerFreelancer(freelancer);
        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.BountyDoesNotExist.selector, 42));
        pulse.placeBid(42, BID);
    }

    function test_PlaceBid_MultipleFreelancersCompete() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        _registerFreelancer(freelancer2);
        uint256 id = _postBounty(client, BUDGET);

        _bid(freelancer, id, 1.5 ether);
        _bid(freelancer2, id, 0.8 ether);

        BountyPulse.Bid[] memory bids = pulse.getBids(id);
        assertEq(bids.length, 2);
        assertEq(bids[0].freelancer, freelancer);
        assertEq(bids[0].amount, 1.5 ether);
        assertEq(bids[1].freelancer, freelancer2);
        assertEq(bids[1].amount, 0.8 ether);
    }

    function test_GetBid_RevertWhen_NoBidExists() public {
        _registerClient(client);
        uint256 id = _postBounty(client, BUDGET);

        vm.expectRevert(abi.encodeWithSelector(BountyPulse.BidNotFound.selector, id, freelancer));
        pulse.getBid(id, freelancer);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    5. REPUTATION GATE (spec 2.2.2, "below 40")
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Drives a freelancer's reputation down by losing `losses` disputes.
    ///      100 -> 70 -> 40 -> 10 -> 0 (the last step saturates).
    function _loseDisputes(address who, uint256 losses) internal {
        for (uint256 i = 0; i < losses; ++i) {
            uint256 id = _postBounty(client, BUDGET);
            _bid(who, id, BID);
            _fund(client, id, who, BID);
            vm.prank(client);
            pulse.raiseDispute(id);
            vm.prank(arbiter);
            pulse.resolveDispute(id, BountyPulse.DisputeOutcome.FreelancerFault);
        }
    }

    function test_ReputationGate_AtExactly40_CanStillBid() public {
        _registerClient(client);
        _registerFreelancer(freelancer);

        _loseDisputes(freelancer, 2); // 100 -> 70 -> 40
        assertEq(pulse.getReputation(freelancer), 40);
        assertTrue(pulse.canBid(freelancer), "gate is 'below 40', so 40 passes");

        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID); // must not revert
        assertTrue(pulse.hasBid(id, freelancer));
    }

    function test_ReputationGate_RevertWhen_Below40() public {
        _registerClient(client);
        _registerFreelancer(freelancer);

        _loseDisputes(freelancer, 3); // 100 -> 70 -> 40 -> 10
        assertEq(pulse.getReputation(freelancer), 10);
        assertFalse(pulse.canBid(freelancer));

        uint256 id = _postBounty(client, BUDGET);
        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.ReputationTooLow.selector, 10, 40));
        pulse.placeBid(id, BID);
    }

    /// @notice Documents a subtle but intended property of the state machine: the
    ///         reputation gate is evaluated when a bid is PLACED, not when it is
    ///         funded. A freelancer sitting at exactly 40 can therefore hold
    ///         several concurrent awards and lose them all, which is the only path
    ///         that drives the score past a single penalty step. The subtraction
    ///         must saturate at 0 rather than underflow.
    ///
    ///         (Purely sequential bidding bottoms out at 10: 100 -> 70 -> 40 -> 10,
    ///         after which the gate permanently blocks new bids. See
    ///         test_ReputationGate_RevertWhen_Below40.)
    function test_Reputation_FloorsAtZeroInsteadOfUnderflowing() public {
        _registerClient(client);
        _registerFreelancer(freelancer);

        _loseDisputes(freelancer, 2); // 100 -> 70 -> 40
        assertEq(pulse.getReputation(freelancer), 40);

        // Two bids placed while still at the 40 threshold, then both lost.
        uint256 first = _postBounty(client, BUDGET);
        uint256 second = _postBounty(client, BUDGET);
        _bid(freelancer, first, BID);
        _bid(freelancer, second, BID);
        _fund(client, first, freelancer, BID);
        _fund(client, second, freelancer, BID);

        vm.prank(client);
        pulse.raiseDispute(first);
        vm.prank(arbiter);
        pulse.resolveDispute(first, BountyPulse.DisputeOutcome.FreelancerFault);
        assertEq(pulse.getReputation(freelancer), 10, "40 - 30");

        vm.prank(client);
        pulse.raiseDispute(second);

        // 10 - 30 would underflow a uint32; the contract must clamp to zero.
        vm.expectEmit(true, true, true, true, address(pulse));
        emit ReputationChanged(freelancer, 10, 0, -10, "dispute_lost");
        vm.prank(arbiter);
        pulse.resolveDispute(second, BountyPulse.DisputeOutcome.FreelancerFault);

        assertEq(pulse.getReputation(freelancer), 0, "saturating subtraction, no underflow");
        assertFalse(pulse.canBid(freelancer));
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////////////////
                    6. ESCROW FUNDING & REVERT LOGIC (spec 2.2.3)
    //////////////////////////////////////////////////////////////////////////*/

    function test_FundEscrow_ExactAmount_LocksBountyAndTakesNoExtra() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);

        uint256 clientBefore = client.balance;

        vm.expectEmit(true, true, true, true, address(pulse));
        emit EscrowFunded(id, client, freelancer, BID, 0);
        _fund(client, id, freelancer, BID);

        assertEq(client.balance, clientBefore - BID, "exact payment: no refund, no surcharge");
        assertEq(address(pulse).balance, BID);
        assertEq(pulse.totalEscrowed(), BID);

        BountyPulse.Bounty memory bounty = pulse.getBounty(id);
        assertEq(bounty.escrowAmount, BID);
        assertEq(bounty.freelancer, freelancer);
        assertEq(uint8(bounty.status), uint8(BountyPulse.BountyStatus.Locked));
        _assertSolvent();
    }

    /// @notice SPEC: sending less than the bid "must revert entirely".
    function test_FundEscrow_RevertWhen_UnderpaidByOneWei() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);

        uint256 clientBefore = client.balance;

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.InsufficientEscrowPayment.selector, BID, BID - 1));
        pulse.fundEscrow{value: BID - 1}(id, freelancer);

        // "Entirely": no ETH kept, no state changed.
        assertEq(client.balance, clientBefore, "every wei returned by the revert");
        assertEq(address(pulse).balance, 0);
        assertEq(pulse.totalEscrowed(), 0);
        assertEq(uint8(_status(id)), uint8(BountyPulse.BountyStatus.Open));
        assertEq(pulse.getBounty(id).freelancer, address(0));
    }

    function test_FundEscrow_RevertWhen_ZeroValueSent() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.InsufficientEscrowPayment.selector, BID, 0));
        pulse.fundEscrow{value: 0}(id, freelancer);
    }

    /// @notice SPEC: overpayment keeps the exact bid and refunds the excess in the
    ///         same transaction.
    function test_FundEscrow_Overpayment_RefundsExcessInSameTransaction() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);

        uint256 overpay = BID + 0.35 ether;
        uint256 clientBefore = client.balance;

        vm.expectEmit(true, true, true, true, address(pulse));
        emit EscrowFunded(id, client, freelancer, BID, 0.35 ether);
        _fund(client, id, freelancer, overpay);

        // The client is out exactly the bid, never the overpayment.
        assertEq(client.balance, clientBefore - BID, "excess must come straight back");
        assertEq(address(pulse).balance, BID, "contract holds the exact bid only");
        assertEq(pulse.getBounty(id).escrowAmount, BID);
        assertEq(pulse.totalEscrowed(), BID);
        assertEq(pulse.withdrawableBalance(client), 0, "a plain EOA gets a direct refund");
        _assertSolvent();
    }

    /// @notice A client contract that rejects ETH must not be able to block
    ///         funding: the refund degrades to a claimable balance.
    function test_FundEscrow_Overpayment_FallsBackToClaimableBalance() public {
        EthRejectingClient rejecting = new EthRejectingClient(pulse);
        rejecting.register("Rejecting Corp", AVATAR_CID);
        _registerFreelancer(freelancer);

        uint256 id = rejecting.postBounty(BUDGET, DETAILS_CID);
        _bid(freelancer, id, BID);

        vm.deal(address(rejecting), 5 ether);
        rejecting.fund(id, freelancer, BID + 0.5 ether);

        assertEq(uint8(_status(id)), uint8(BountyPulse.BountyStatus.Locked), "funding still succeeded");
        assertEq(pulse.getBounty(id).escrowAmount, BID);
        assertEq(pulse.withdrawableBalance(address(rejecting)), 0.5 ether, "excess became claimable");
        assertEq(address(pulse).balance, BID + 0.5 ether);
        _assertSolvent();
    }

    function test_FundEscrow_RevertWhen_CallerIsNotBountyOwner() public {
        _registerClient(client);
        _registerClient(client2);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);

        vm.prank(client2);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.NotBountyOwner.selector, id, client2));
        pulse.fundEscrow{value: BID}(id, freelancer);
    }

    function test_FundEscrow_RevertWhen_FreelancerNeverBid() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        _registerFreelancer(freelancer2);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.BidNotFound.selector, id, freelancer2));
        pulse.fundEscrow{value: BID}(id, freelancer2);
    }

    function test_FundEscrow_RevertWhen_AlreadyLocked() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);
        _fund(client, id, freelancer, BID);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                BountyPulse.InvalidBountyStatus.selector,
                id,
                BountyPulse.BountyStatus.Locked,
                BountyPulse.BountyStatus.Open
            )
        );
        pulse.fundEscrow{value: BID}(id, freelancer);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          7. WORK SUBMISSION (spec 2.2.4)
    //////////////////////////////////////////////////////////////////////////*/

    function test_SubmitWork_StoresCidAndAdvancesStatus() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);
        _fund(client, id, freelancer, BID);

        vm.expectEmit(true, true, true, true, address(pulse));
        emit WorkSubmitted(id, freelancer, WORK_CID);
        vm.prank(freelancer);
        pulse.submitWork(id, WORK_CID);

        assertEq(pulse.getBounty(id).ipfsWorkHash, WORK_CID);
        assertEq(uint8(_status(id)), uint8(BountyPulse.BountyStatus.Submitted));
    }

    function test_SubmitWork_RevertWhen_CallerIsNotAwardedFreelancer() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        _registerFreelancer(freelancer2);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);
        _bid(freelancer2, id, BID);
        _fund(client, id, freelancer, BID);

        vm.prank(freelancer2);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.NotAwardedFreelancer.selector, id, freelancer2));
        pulse.submitWork(id, WORK_CID);
    }

    function test_SubmitWork_RevertWhen_BountyStillOpen() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);

        // freelancer is not yet awarded, so the ownership check fires first
        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.NotAwardedFreelancer.selector, id, freelancer));
        pulse.submitWork(id, WORK_CID);
    }

    function test_SubmitWork_RevertWhen_AlreadySubmitted() public {
        uint256 id = _scenarioSubmitted();

        vm.prank(freelancer);
        vm.expectRevert(
            abi.encodeWithSelector(
                BountyPulse.InvalidBountyStatus.selector,
                id,
                BountyPulse.BountyStatus.Submitted,
                BountyPulse.BountyStatus.Locked
            )
        );
        pulse.submitWork(id, WORK_CID);
    }

    function test_SubmitWork_RevertWhen_CidInvalid() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);
        _fund(client, id, freelancer, BID);

        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.InvalidCid.selector, "nope"));
        pulse.submitWork(id, "nope");
    }

    /*//////////////////////////////////////////////////////////////////////////
                8. APPROVAL: 2% FEE MATH + PULL PAYMENT (spec 2.2.4)
    //////////////////////////////////////////////////////////////////////////*/

    function test_ApproveWork_Splits2PercentFeeAndCreditsBalances() public {
        uint256 id = _scenarioSubmitted();

        uint256 expectedFee = BID * 2 / 100; // 0.02 ether
        uint256 expectedPayout = BID - expectedFee; // 0.98 ether
        assertEq(expectedFee, 0.02 ether);
        assertEq(expectedPayout, 0.98 ether);

        uint256 freelancerWalletBefore = freelancer.balance;
        uint256 arbiterWalletBefore = arbiter.balance;

        vm.expectEmit(true, true, true, true, address(pulse));
        emit WorkApproved(id, client, freelancer, expectedPayout, expectedFee);
        vm.prank(client);
        pulse.approveWork(id);

        // Pull payment: ledger credited, wallets untouched.
        assertEq(pulse.withdrawableBalance(freelancer), expectedPayout, "freelancer gets 98%");
        assertEq(pulse.withdrawableBalance(arbiter), expectedFee, "arbiter gets the 2% fee");
        assertEq(freelancer.balance, freelancerWalletBefore, "approve must NOT push ETH");
        assertEq(arbiter.balance, arbiterWalletBefore, "approve must NOT push ETH");

        // Escrow released into liabilities; nothing lost, nothing created.
        assertEq(pulse.totalEscrowed(), 0);
        assertEq(pulse.totalWithdrawable(), BID);
        assertEq(address(pulse).balance, BID, "the ETH is still here, now owed");
        assertEq(expectedFee + expectedPayout, BID, "fee + payout == escrow exactly");

        assertEq(uint8(_status(id)), uint8(BountyPulse.BountyStatus.Resolved));
        _assertSolvent();
    }

    function test_ApproveWork_IncreasesReputationBy15() public {
        uint256 id = _scenarioSubmitted();
        assertEq(pulse.getReputation(freelancer), 100);

        vm.expectEmit(true, true, true, true, address(pulse));
        emit ReputationChanged(freelancer, 100, 115, 15, "work_approved");
        vm.prank(client);
        pulse.approveWork(id);

        assertEq(pulse.getReputation(freelancer), 115, "100 + 15");
    }

    function test_ApproveWork_CreditsAccumulateAcrossBounties() public {
        uint256 first = _scenarioSubmitted();
        vm.prank(client);
        pulse.approveWork(first);

        uint256 second = _postBounty(client, BUDGET);
        _bid(freelancer, second, 0.5 ether);
        _fund(client, second, freelancer, 0.5 ether);
        vm.prank(freelancer);
        pulse.submitWork(second, WORK_CID);
        vm.prank(client);
        pulse.approveWork(second);

        assertEq(pulse.withdrawableBalance(freelancer), 0.98 ether + 0.49 ether);
        assertEq(pulse.withdrawableBalance(arbiter), 0.02 ether + 0.01 ether);
        assertEq(pulse.getReputation(freelancer), 130, "two approvals: 100 + 15 + 15");
        _assertSolvent();
    }

    function test_ApproveWork_RevertWhen_CallerIsNotClient() public {
        uint256 id = _scenarioSubmitted();

        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.NotBountyOwner.selector, id, freelancer));
        pulse.approveWork(id);

        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.NotBountyOwner.selector, id, arbiter));
        pulse.approveWork(id);
    }

    function test_ApproveWork_RevertWhen_WorkNotSubmittedYet() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);
        _fund(client, id, freelancer, BID);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                BountyPulse.InvalidBountyStatus.selector,
                id,
                BountyPulse.BountyStatus.Locked,
                BountyPulse.BountyStatus.Submitted
            )
        );
        pulse.approveWork(id);
    }

    function test_ApproveWork_RevertWhen_AlreadyResolved() public {
        uint256 id = _scenarioSubmitted();
        vm.prank(client);
        pulse.approveWork(id);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                BountyPulse.InvalidBountyStatus.selector,
                id,
                BountyPulse.BountyStatus.Resolved,
                BountyPulse.BountyStatus.Submitted
            )
        );
        pulse.approveWork(id);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          9. CLAIMING FUNDS (spec 2.2.5)
    //////////////////////////////////////////////////////////////////////////*/

    function test_ClaimFunds_FreelancerWithdrawsExactly98Percent() public {
        uint256 id = _scenarioSubmitted();
        vm.prank(client);
        pulse.approveWork(id);

        uint256 walletBefore = freelancer.balance;

        vm.expectEmit(true, true, true, true, address(pulse));
        emit FundsClaimed(freelancer, 0.98 ether);
        vm.prank(freelancer);
        uint256 claimed = pulse.claimFunds();

        assertEq(claimed, 0.98 ether);
        assertEq(freelancer.balance, walletBefore + 0.98 ether);
        assertEq(pulse.withdrawableBalance(freelancer), 0, "ledger zeroed");
        assertEq(pulse.totalWithdrawable(), 0.02 ether, "only the arbiter's fee remains owed");
        assertEq(address(pulse).balance, 0.02 ether);
        _assertSolvent();
    }

    function test_ClaimFunds_ArbiterWithdrawsAccumulatedFees() public {
        uint256 id = _scenarioSubmitted();
        vm.prank(client);
        pulse.approveWork(id);

        uint256 walletBefore = arbiter.balance;
        vm.prank(arbiter);
        pulse.claimFunds();

        assertEq(arbiter.balance, walletBefore + 0.02 ether, "arbiter collects the 2% fee");
        assertEq(pulse.withdrawableBalance(arbiter), 0);
        _assertSolvent();
    }

    function test_ClaimFunds_RevertWhen_NothingToClaim() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.NothingToClaim.selector, stranger));
        pulse.claimFunds();
    }

    function test_ClaimFunds_RevertWhen_ClaimedTwice() public {
        uint256 id = _scenarioSubmitted();
        vm.prank(client);
        pulse.approveWork(id);

        vm.prank(freelancer);
        pulse.claimFunds();

        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.NothingToClaim.selector, freelancer));
        pulse.claimFunds();
    }

    function test_ClaimFunds_RevertWhen_RecipientRejectsEth() public {
        EthRejectingClient rejecting = new EthRejectingClient(pulse);
        rejecting.register("Rejecting Corp", AVATAR_CID);
        _registerFreelancer(freelancer);

        uint256 id = rejecting.postBounty(BUDGET, DETAILS_CID);
        _bid(freelancer, id, BID);
        vm.deal(address(rejecting), 5 ether);
        rejecting.fund(id, freelancer, BID + 0.5 ether); // 0.5 became claimable

        vm.expectRevert(abi.encodeWithSelector(BountyPulse.TransferFailed.selector, address(rejecting), 0.5 ether));
        rejecting.claim();

        // The failed claim reverted, so the balance is still intact and claimable later.
        assertEq(pulse.withdrawableBalance(address(rejecting)), 0.5 ether);
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////////////////
                    10. DISPUTE, REFUND & PENALTY (spec 2.2.6)
    //////////////////////////////////////////////////////////////////////////*/

    function test_RaiseDispute_FromSubmitted() public {
        uint256 id = _scenarioSubmitted();

        vm.expectEmit(true, true, true, true, address(pulse));
        emit DisputeRaised(id, client, BountyPulse.BountyStatus.Submitted);
        vm.prank(client);
        pulse.raiseDispute(id);

        assertEq(uint8(_status(id)), uint8(BountyPulse.BountyStatus.Disputed));
    }

    /// @notice A freelancer who takes the job and vanishes must not be able to
    ///         trap the escrow, so disputing from `Locked` is allowed.
    function test_RaiseDispute_FromLockedWhenFreelancerAbandonsWork() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, BUDGET);
        _bid(freelancer, id, BID);
        _fund(client, id, freelancer, BID);

        vm.prank(client);
        pulse.raiseDispute(id);
        assertEq(uint8(_status(id)), uint8(BountyPulse.BountyStatus.Disputed));
    }

    function test_RaiseDispute_RevertWhen_CallerIsNotClient() public {
        uint256 id = _scenarioSubmitted();

        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.NotBountyOwner.selector, id, freelancer));
        pulse.raiseDispute(id);
    }

    function test_RaiseDispute_RevertWhen_BountyStillOpen() public {
        _registerClient(client);
        uint256 id = _postBounty(client, BUDGET);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                BountyPulse.InvalidBountyStatus.selector,
                id,
                BountyPulse.BountyStatus.Open,
                BountyPulse.BountyStatus.Submitted
            )
        );
        pulse.raiseDispute(id);
    }

    /// @notice SPEC Outcome A: full refund to the client, -30 reputation.
    function test_ResolveDispute_FreelancerFault_RefundsFullEscrowAndPenalises() public {
        uint256 id = _scenarioSubmitted();
        vm.prank(client);
        pulse.raiseDispute(id);

        uint256 clientBefore = client.balance;
        uint256 arbiterBalanceBefore = pulse.withdrawableBalance(arbiter);

        vm.expectEmit(true, true, true, true, address(pulse));
        emit DisputeResolved(id, arbiter, BountyPulse.DisputeOutcome.FreelancerFault, BID, 0, 0);
        vm.prank(arbiter);
        pulse.resolveDispute(id, BountyPulse.DisputeOutcome.FreelancerFault);

        assertEq(client.balance, clientBefore + BID, "100% of escrow returned");
        assertEq(pulse.getReputation(freelancer), 70, "100 - 30");
        assertEq(pulse.withdrawableBalance(freelancer), 0, "freelancer earns nothing");
        assertEq(pulse.withdrawableBalance(arbiter), arbiterBalanceBefore, "no fee on a failed engagement");
        assertEq(pulse.totalEscrowed(), 0);
        assertEq(address(pulse).balance, 0, "contract fully drained back to the client");
        assertEq(uint8(_status(id)), uint8(BountyPulse.BountyStatus.Refunded));
        _assertSolvent();
    }

    /// @notice SPEC Outcome B: freelancer is paid the escrow minus the 2% fee.
    function test_ResolveDispute_ClientFault_PaysFreelancerMinusFee() public {
        uint256 id = _scenarioSubmitted();
        vm.prank(client);
        pulse.raiseDispute(id);

        uint256 clientBefore = client.balance;

        vm.expectEmit(true, true, true, true, address(pulse));
        emit DisputeResolved(id, arbiter, BountyPulse.DisputeOutcome.ClientFault, 0, 0.98 ether, 0.02 ether);
        vm.prank(arbiter);
        pulse.resolveDispute(id, BountyPulse.DisputeOutcome.ClientFault);

        assertEq(pulse.withdrawableBalance(freelancer), 0.98 ether, "98% credited, pull payment");
        assertEq(pulse.withdrawableBalance(arbiter), 0.02 ether, "2% fee still applies");
        assertEq(client.balance, clientBefore, "client gets nothing back");
        assertEq(pulse.getReputation(freelancer), 100, "no reputation change: no fault");
        assertEq(pulse.totalEscrowed(), 0);
        assertEq(uint8(_status(id)), uint8(BountyPulse.BountyStatus.Resolved));
        _assertSolvent();
    }

    function test_ResolveDispute_RevertWhen_CallerIsNotArbiter() public {
        uint256 id = _scenarioSubmitted();
        vm.prank(client);
        pulse.raiseDispute(id);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.CallerIsNotArbiter.selector, client));
        pulse.resolveDispute(id, BountyPulse.DisputeOutcome.ClientFault);

        vm.prank(freelancer);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.CallerIsNotArbiter.selector, freelancer));
        pulse.resolveDispute(id, BountyPulse.DisputeOutcome.FreelancerFault);
    }

    function test_ResolveDispute_RevertWhen_BountyNotDisputed() public {
        uint256 id = _scenarioSubmitted();

        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(
                BountyPulse.InvalidBountyStatus.selector,
                id,
                BountyPulse.BountyStatus.Submitted,
                BountyPulse.BountyStatus.Disputed
            )
        );
        pulse.resolveDispute(id, BountyPulse.DisputeOutcome.ClientFault);
    }

    function test_ResolveDispute_RevertWhen_ResolvedTwice() public {
        uint256 id = _scenarioSubmitted();
        vm.prank(client);
        pulse.raiseDispute(id);
        vm.prank(arbiter);
        pulse.resolveDispute(id, BountyPulse.DisputeOutcome.ClientFault);

        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(
                BountyPulse.InvalidBountyStatus.selector,
                id,
                BountyPulse.BountyStatus.Resolved,
                BountyPulse.BountyStatus.Disputed
            )
        );
        pulse.resolveDispute(id, BountyPulse.DisputeOutcome.ClientFault);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          11. SECURITY: REENTRANCY & FALLBACK
    //////////////////////////////////////////////////////////////////////////*/

    function test_Security_ClaimFundsIsReentrancySafe() public {
        ReentrantFreelancer attacker = new ReentrantFreelancer(pulse);
        attacker.register("Attacker", AVATAR_CID);
        _registerClient(client);

        uint256 id = _postBounty(client, BUDGET);
        attacker.bid(id, BID);
        _fund(client, id, address(attacker), BID);
        attacker.submit(id, WORK_CID);
        vm.prank(client);
        pulse.approveWork(id);

        assertEq(pulse.withdrawableBalance(address(attacker)), 0.98 ether);

        attacker.claim();

        assertEq(attacker.reentryAttempts(), 1, "the attacker did try to re-enter");
        assertTrue(attacker.reentryReverted(), "the guard rejected the re-entrant call");
        assertEq(address(attacker).balance, 0.98 ether, "paid exactly once, not twice");
        assertEq(pulse.withdrawableBalance(address(attacker)), 0);
        assertEq(address(pulse).balance, 0.02 ether, "the arbiter's fee is untouched");
        _assertSolvent();
    }

    function test_Security_DirectEthTransferIsRejected() public {
        vm.prank(stranger);
        (bool ok,) = address(pulse).call{value: 1 ether}("");
        assertFalse(ok, "receive() must reject unattributable ETH");
        assertEq(address(pulse).balance, 0);
    }

    function test_Security_UnknownFunctionSelectorIsRejected() public {
        vm.prank(stranger);
        (bool ok,) = address(pulse).call(abi.encodeWithSignature("thisDoesNotExist()"));
        assertFalse(ok, "fallback() must reject unknown calls");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        12. VIEWS FEEDING THE OFF-CHAIN SORT
    //////////////////////////////////////////////////////////////////////////*/

    function test_Views_ReturnFullFeedForClientSideSorting() public {
        _registerClient(client);
        _registerFreelancer(freelancer);

        uint256 a = _postBounty(client, 3 ether);
        uint256 b = _postBounty(client, 1 ether);
        uint256 c = _postBounty(client, 7 ether);

        BountyPulse.Bounty[] memory all = pulse.getAllBounties();
        assertEq(all.length, 3);
        // Returned in insertion order. Ordering is the DApp's job, not the chain's.
        assertEq(all[0].id, a);
        assertEq(all[0].maxBudget, 3 ether);
        assertEq(all[1].id, b);
        assertEq(all[2].id, c);
        assertEq(all[2].maxBudget, 7 ether);
    }

    function test_Views_PaginationClampsToRange() public {
        _registerClient(client);
        for (uint256 i = 0; i < 5; ++i) {
            _postBounty(client, (i + 1) * 1 ether);
        }

        (BountyPulse.Bounty[] memory page, uint256 total) = pulse.getBountiesPaged(0, 2);
        assertEq(total, 5);
        assertEq(page.length, 2);
        assertEq(page[0].id, 1);
        assertEq(page[1].id, 2);

        (page, total) = pulse.getBountiesPaged(3, 10); // limit exceeds the remainder
        assertEq(page.length, 2, "clamped to what is left");
        assertEq(page[0].id, 4);
        assertEq(page[1].id, 5);

        (page, total) = pulse.getBountiesPaged(50, 10); // offset past the end
        assertEq(page.length, 0);
        assertEq(total, 5);
    }

    function test_Views_TotalLiabilitiesTracksEscrowPlusBalances() public {
        uint256 id = _scenarioSubmitted();
        assertEq(pulse.totalLiabilities(), BID, "all in escrow");

        vm.prank(client);
        pulse.approveWork(id);
        assertEq(pulse.totalLiabilities(), BID, "all owed as claimable balances");

        vm.prank(freelancer);
        pulse.claimFunds();
        assertEq(pulse.totalLiabilities(), 0.02 ether, "only the fee is still owed");
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////////////////
                    13. FULL HAPPY PATH (checkpoint 4 walkthrough)
    //////////////////////////////////////////////////////////////////////////*/

    function test_EndToEnd_PostBidFundSubmitApproveClaim() public {
        _registerClient(client);
        _registerFreelancer(freelancer);
        _registerFreelancer(freelancer2);

        uint256 id = _postBounty(client, 5 ether);
        _bid(freelancer, id, 4 ether);
        _bid(freelancer2, id, 2 ether); // cheaper competing quote

        _fund(client, id, freelancer2, 2 ether); // client picks the cheaper bid

        vm.prank(freelancer2);
        pulse.submitWork(id, WORK_CID);

        vm.prank(client);
        pulse.approveWork(id);

        uint256 fee = 0.04 ether; // 2% of 2 ether
        uint256 payout = 1.96 ether;

        assertEq(pulse.withdrawableBalance(freelancer2), payout);
        assertEq(pulse.withdrawableBalance(arbiter), fee);
        assertEq(pulse.getReputation(freelancer2), 115);
        assertEq(pulse.getReputation(freelancer), 100, "the losing bidder is unaffected");

        vm.prank(freelancer2);
        pulse.claimFunds();
        vm.prank(arbiter);
        pulse.claimFunds();

        assertEq(address(pulse).balance, 0, "contract fully settled");
        assertEq(pulse.totalLiabilities(), 0);
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                14. FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The fee split must never create or destroy wei, for ANY amount.
    function testFuzz_FeeSplit_IsConservative(uint256 amount) public view {
        // Bound to the domain where `amount * 200` cannot overflow. Above this the
        // multiplication reverts, which is correct behaviour but not the property
        // under test (and no such escrow can exist: it exceeds the ETH supply by
        // ~50 orders of magnitude).
        amount = bound(amount, 0, type(uint256).max / pulse.PLATFORM_FEE_BPS());

        (uint256 fee, uint256 payout) = pulse.previewFeeSplit(amount);

        assertEq(fee + payout, amount, "fee + payout must equal the escrow exactly");
        assertEq(fee, amount * 2 / 100, "fee is 2%, floored");
        assertLe(fee * 100, amount * 2, "fee never rounds up above 2%");
        assertGe(payout * 100, amount * 98, "freelancer never receives less than 98%");
    }

    /// @notice End-to-end fee math with fuzzed escrow amounts: the ledger must
    ///         always reconcile to the exact wei.
    function testFuzz_ApproveWork_LedgerReconciles(uint96 bidAmount) public {
        uint256 bidWei = bound(uint256(bidAmount), 1, 1000 ether);

        _registerClient(client);
        _registerFreelancer(freelancer);
        vm.deal(client, bidWei + 1 ether);

        uint256 id = _postBounty(client, bidWei);
        _bid(freelancer, id, bidWei);
        _fund(client, id, freelancer, bidWei);
        vm.prank(freelancer);
        pulse.submitWork(id, WORK_CID);
        vm.prank(client);
        pulse.approveWork(id);

        (uint256 fee, uint256 payout) = pulse.previewFeeSplit(bidWei);

        assertEq(pulse.withdrawableBalance(freelancer), payout);
        assertEq(pulse.withdrawableBalance(arbiter), fee);
        assertEq(pulse.withdrawableBalance(freelancer) + pulse.withdrawableBalance(arbiter), bidWei);
        assertEq(address(pulse).balance, bidWei, "no wei stranded, no wei conjured");
        assertEq(pulse.totalEscrowed(), 0);
        _assertSolvent();
    }

    /// @notice Overpayment refunds must be exact for any excess, and the client
    ///         must never be charged more than the bid.
    function testFuzz_FundEscrow_RefundsExcessExactly(uint96 bidAmount, uint96 excessAmount) public {
        uint256 bidWei = bound(uint256(bidAmount), 1, 100 ether);
        uint256 excessWei = bound(uint256(excessAmount), 0, 100 ether);

        _registerClient(client);
        _registerFreelancer(freelancer);
        vm.deal(client, bidWei + excessWei + 1 ether);

        uint256 id = _postBounty(client, bidWei);
        _bid(freelancer, id, bidWei);

        uint256 before = client.balance;
        _fund(client, id, freelancer, bidWei + excessWei);

        assertEq(before - client.balance, bidWei, "client pays the bid and not one wei more");
        assertEq(address(pulse).balance, bidWei, "contract escrows the bid and nothing else");
        assertEq(pulse.getBounty(id).escrowAmount, bidWei);
        _assertSolvent();
    }

    /// @notice Underpayment by any amount must revert and change nothing.
    function testFuzz_FundEscrow_RevertsOnAnyUnderpayment(uint96 bidAmount, uint256 shortfall) public {
        uint256 bidWei = bound(uint256(bidAmount), 2, 100 ether);
        shortfall = bound(shortfall, 1, bidWei);

        _registerClient(client);
        _registerFreelancer(freelancer);
        vm.deal(client, bidWei + 1 ether);

        uint256 id = _postBounty(client, bidWei);
        _bid(freelancer, id, bidWei);

        uint256 sent = bidWei - shortfall;
        uint256 before = client.balance;

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(BountyPulse.InsufficientEscrowPayment.selector, bidWei, sent));
        pulse.fundEscrow{value: sent}(id, freelancer);

        assertEq(client.balance, before, "revert returns everything");
        assertEq(address(pulse).balance, 0);
        assertEq(uint8(_status(id)), uint8(BountyPulse.BountyStatus.Open));
    }

    /// @notice Any bid strictly above the ceiling is rejected; any bid at or below
    ///         it is accepted.
    function testFuzz_PlaceBid_EnforcesBudgetCeiling(uint96 budget, uint96 quote) public {
        uint256 budgetWei = bound(uint256(budget), 1, 1000 ether);
        uint256 quoteWei = bound(uint256(quote), 1, 2000 ether);

        _registerClient(client);
        _registerFreelancer(freelancer);
        uint256 id = _postBounty(client, budgetWei);

        vm.prank(freelancer);
        if (quoteWei > budgetWei) {
            vm.expectRevert(abi.encodeWithSelector(BountyPulse.BidExceedsBudget.selector, quoteWei, budgetWei));
            pulse.placeBid(id, quoteWei);
            assertEq(pulse.getBidCount(id), 0);
        } else {
            pulse.placeBid(id, quoteWei);
            assertEq(pulse.getBid(id, freelancer).amount, quoteWei);
        }
    }
}
