// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BountyPulse.sol";

contract BountyPulseTest is Test {
    BountyPulse bountyPulse;

    address client = address(1);
    address freelancer = address(2);
    address freelancer2 = address(3);

    uint256 constant BUDGET = 1 ether;
    uint256 constant BID = 0.8 ether;

    function setUp() public {
        // Deploy the contract.
        // The test contract itself becomes the arbiter.
        bountyPulse = new BountyPulse();

        // Give test accounts some ETH.
        vm.deal(client, 10 ether);
        vm.deal(freelancer, 10 ether);
        vm.deal(freelancer2, 10 ether);

        // Register client.
        vm.prank(client);
        bountyPulse.registerUser(
            "Alice",
            BountyPulse.Role.Client,
            "QmClientAvatar"
        );

        // Register freelancer.
        vm.prank(freelancer);
        bountyPulse.registerUser(
            "Bob",
            BountyPulse.Role.Freelancer,
            "QmFreelancerAvatar"
        );

        // Register second freelancer.
        vm.prank(freelancer2);
        bountyPulse.registerUser(
            "Charlie",
            BountyPulse.Role.Freelancer,
            "QmFreelancer2Avatar"
        );
    }

    // ---------------------------------------------------------
    // USER REGISTRATION TESTS
    // ---------------------------------------------------------

    function testClientRegistration() public {
        (
            string memory name,
            BountyPulse.Role role,
            string memory avatar,
            uint256 reputation,
            bool registered
        ) = bountyPulse.getUser(client);

        assertEq(name, "Alice");
        assertEq(uint256(role), uint256(BountyPulse.Role.Client));
        assertEq(avatar, "QmClientAvatar");
        assertEq(reputation, 0);
        assertTrue(registered);
    }

    function testFreelancerRegistration() public {
        (
            string memory name,
            BountyPulse.Role role,
            string memory avatar,
            uint256 reputation,
            bool registered
        ) = bountyPulse.getUser(freelancer);

        assertEq(name, "Bob");
        assertEq(uint256(role), uint256(BountyPulse.Role.Freelancer));
        assertEq(avatar, "QmFreelancerAvatar");
        assertEq(reputation, 100);
        assertTrue(registered);
    }

    function testCannotRegisterSameWalletTwice() public {
        vm.prank(client);

        vm.expectRevert("Wallet already registered");

        bountyPulse.registerUser(
            "Alice Again",
            BountyPulse.Role.Client,
            "AnotherAvatar"
        );
    }

    function testCannotRegisterWithInvalidRole() public {
        address newUser = address(10);

        vm.prank(newUser);

        vm.expectRevert("Invalid role");

        bountyPulse.registerUser(
            "Invalid User",
            BountyPulse.Role.Arbiter,
            ""
        );
    }

    function testCannotRegisterWithEmptyName() public {
        address newUser = address(11);

        vm.prank(newUser);

        vm.expectRevert("Name required");

        bountyPulse.registerUser(
            "",
            BountyPulse.Role.Client,
            ""
        );
    }

    // ---------------------------------------------------------
    // BOUNTY CREATION TESTS
    // ---------------------------------------------------------

    function testClientCanPostBounty() public {
        vm.prank(client);

        uint256 bountyId = bountyPulse.postBounty(
            BUDGET,
            "QmBountyDetails"
        );

        assertEq(bountyId, 1);
        assertEq(bountyPulse.bountyCounter(), 1);

        BountyPulse.Bounty memory bounty =
            bountyPulse.getBounty(bountyId);

        assertEq(bounty.id, 1);
        assertEq(bounty.client, client);
        assertEq(bounty.maxBudget, BUDGET);
        assertEq(
            bounty.ipfsBountyDetailsHash,
            "QmBountyDetails"
        );
        assertEq(
            uint256(bounty.status),
            uint256(BountyPulse.BountyStatus.Open)
        );
    }

    function testNonClientCannotPostBounty() public {
        vm.prank(freelancer);

        vm.expectRevert("Only client can perform this action");

        bountyPulse.postBounty(
            BUDGET,
            "QmBountyDetails"
        );
    }

    function testCannotPostZeroBudgetBounty() public {
        vm.prank(client);

        vm.expectRevert("Budget must be greater than zero");

        bountyPulse.postBounty(
            0,
            "QmBountyDetails"
        );
    }

    function testCannotPostBountyWithoutDetailsCID() public {
        vm.prank(client);

        vm.expectRevert("Bounty details CID required");

        bountyPulse.postBounty(
            BUDGET,
            ""
        );
    }

    // ---------------------------------------------------------
    // BIDDING TESTS
    // ---------------------------------------------------------

    function createBounty() internal returns (uint256) {
        vm.prank(client);

        return bountyPulse.postBounty(
            BUDGET,
            "QmBountyDetails"
        );
    }

    function testFreelancerCanPlaceBid() public {
        uint256 bountyId = createBounty();

        vm.prank(freelancer);

        bountyPulse.placeBid(
            bountyId,
            BID
        );

        BountyPulse.Bid[] memory bids =
            bountyPulse.getBids(bountyId);

        assertEq(bids.length, 1);
        assertEq(bids[0].freelancer, freelancer);
        assertEq(bids[0].amount, BID);
    }

    function testCannotBidAboveBudget() public {
        uint256 bountyId = createBounty();

        vm.prank(freelancer);

        vm.expectRevert("Bid exceeds maximum budget");

        bountyPulse.placeBid(
            bountyId,
            2 ether
        );
    }

    function testCannotPlaceZeroBid() public {
        uint256 bountyId = createBounty();

        vm.prank(freelancer);

        vm.expectRevert("Bid must be greater than zero");

        bountyPulse.placeBid(
            bountyId,
            0
        );
    }
    

    

    // ---------------------------------------------------------
    // ESCROW / FUNDING TESTS
    // ---------------------------------------------------------

    function prepareFundedBounty() internal returns (uint256) {
        uint256 bountyId = createBounty();

        vm.prank(freelancer);

        bountyPulse.placeBid(
            bountyId,
            BID
        );

        return bountyId;
    }

    function testClientCanFundSelectedBid() public {
        uint256 bountyId = prepareFundedBounty();

        vm.prank(client);

        bountyPulse.fundBounty{value: BID}(
            bountyId,
            freelancer,
            BID
        );

        BountyPulse.Bounty memory bounty =
            bountyPulse.getBounty(bountyId);

        assertEq(
            uint256(bounty.status),
            uint256(BountyPulse.BountyStatus.Locked)
        );

        assertEq(
            bounty.selectedFreelancer,
            freelancer
        );

        assertEq(
            bounty.selectedBid,
            BID
        );

        assertEq(
            bountyPulse.getContractBalance(),
            BID
        );
    }

    function testCannotFundWithoutValidBid() public {
        uint256 bountyId = createBounty();

        vm.prank(client);

        vm.expectRevert("Selected bid does not exist");

        bountyPulse.fundBounty{value: BID}(
            bountyId,
            freelancer,
            BID
        );
    }

    function testCannotFundWithInsufficientETH() public {
        uint256 bountyId = prepareFundedBounty();

        vm.prank(client);

        vm.expectRevert("Insufficient ETH sent");

        bountyPulse.fundBounty{value: 0.5 ether}(
            bountyId,
            freelancer,
            BID
        );
    }

    // ---------------------------------------------------------
    // WORK SUBMISSION TESTS
    // ---------------------------------------------------------

    function testSelectedFreelancerCanSubmitWork() public {
        uint256 bountyId = prepareFundedBounty();

        vm.prank(client);

        bountyPulse.fundBounty{value: BID}(
            bountyId,
            freelancer,
            BID
        );

        vm.prank(freelancer);

        bountyPulse.submitWork(
            bountyId,
            "QmCompletedWork"
        );

        BountyPulse.Bounty memory bounty =
            bountyPulse.getBounty(bountyId);

        assertEq(
            bounty.ipfsWorkFileHash,
            "QmCompletedWork"
        );
    }

    function testWrongFreelancerCannotSubmitWork() public {
        uint256 bountyId = prepareFundedBounty();

        vm.prank(client);

        bountyPulse.fundBounty{value: BID}(
            bountyId,
            freelancer,
            BID
        );

        vm.prank(freelancer2);

        vm.expectRevert(
            "You are not the selected freelancer"
        );

        bountyPulse.submitWork(
            bountyId,
            "QmFakeWork"
        );
    }

    function testCannotSubmitEmptyWorkCID() public {
        uint256 bountyId = prepareFundedBounty();

        vm.prank(client);

        bountyPulse.fundBounty{value: BID}(
            bountyId,
            freelancer,
            BID
        );

        vm.prank(freelancer);

        vm.expectRevert("Work CID required");

        bountyPulse.submitWork(
            bountyId,
            ""
        );
    }

    // ---------------------------------------------------------
    // APPROVAL / PAYMENT TESTS
    // ---------------------------------------------------------

    function prepareCompletedBounty()
        internal
        returns (uint256)
    {
        uint256 bountyId = prepareFundedBounty();

        vm.prank(client);

        bountyPulse.fundBounty{value: BID}(
            bountyId,
            freelancer,
            BID
        );

        vm.prank(freelancer);

        bountyPulse.submitWork(
            bountyId,
            "QmCompletedWork"
        );

        return bountyId;
    }

    function testClientCanApproveWork() public {
        uint256 bountyId = prepareCompletedBounty();

        vm.prank(client);

        bountyPulse.approveWork(bountyId);

        BountyPulse.Bounty memory bounty =
            bountyPulse.getBounty(bountyId);

        assertEq(
            uint256(bounty.status),
            uint256(BountyPulse.BountyStatus.Resolved)
        );

        // 2% platform fee
        uint256 platformFee = (BID * 2) / 100;

        // 98% goes to freelancer
        uint256 freelancerAmount = BID - platformFee;

        assertEq(
            bountyPulse.getWithdrawableBalance(freelancer),
            freelancerAmount
        );

        // Arbiter is the test contract.
        assertEq(
            bountyPulse.getWithdrawableBalance(address(this)),
            platformFee
        );
    }

    function testSuccessfulWorkIncreasesReputationBy15() public {
        uint256 bountyId = prepareCompletedBounty();

        (, , , uint256 reputationBefore, ) =
            bountyPulse.getUser(freelancer);

        vm.prank(client);

        bountyPulse.approveWork(bountyId);

        (, , , uint256 reputationAfter, ) =
            bountyPulse.getUser(freelancer);

        assertEq(
            reputationAfter,
            reputationBefore + 15
        );
    }

    function testCannotApproveBeforeWorkSubmission() public {
        uint256 bountyId = prepareFundedBounty();

        vm.prank(client);

        bountyPulse.fundBounty{value: BID}(
            bountyId,
            freelancer,
            BID
        );

        vm.prank(client);

        vm.expectRevert(
            "Work has not been submitted"
        );

        bountyPulse.approveWork(bountyId);
    }

    // ---------------------------------------------------------
    // DISPUTE TESTS
    // ---------------------------------------------------------

    function testClientCanDisputeSubmittedWork() public {
        uint256 bountyId = prepareCompletedBounty();

        vm.prank(client);

        bountyPulse.disputeBounty(bountyId);

        BountyPulse.Bounty memory bounty =
            bountyPulse.getBounty(bountyId);

        assertEq(
            uint256(bounty.status),
            uint256(BountyPulse.BountyStatus.Disputed)
        );
    }

    function testArbiterCanResolveFreelancerFault() public {
        uint256 bountyId = prepareCompletedBounty();

        vm.prank(client);

        bountyPulse.disputeBounty(bountyId);

        vm.prank(address(this));

        bountyPulse.resolveDispute(
            bountyId,
            true
        );

        BountyPulse.Bounty memory bounty =
            bountyPulse.getBounty(bountyId);

        assertEq(
            uint256(bounty.status),
            uint256(BountyPulse.BountyStatus.Refunded)
        );

        // Client receives full escrow refund.
        assertEq(
            bountyPulse.getWithdrawableBalance(client),
            BID
        );

        // Freelancer loses 30 reputation.
        (, , , uint256 reputation, ) =
            bountyPulse.getUser(freelancer);

        assertEq(
            reputation,
            70
        );
    }

    function testArbiterCanResolveClientFault() public {
        uint256 bountyId = prepareCompletedBounty();

        vm.prank(client);

        bountyPulse.disputeBounty(bountyId);

        vm.prank(address(this));

        bountyPulse.resolveDispute(
            bountyId,
            false
        );

        BountyPulse.Bounty memory bounty =
            bountyPulse.getBounty(bountyId);

        assertEq(
            uint256(bounty.status),
            uint256(BountyPulse.BountyStatus.Resolved)
        );

        uint256 platformFee = (BID * 2) / 100;
        uint256 freelancerAmount = BID - platformFee;

        assertEq(
            bountyPulse.getWithdrawableBalance(freelancer),
            freelancerAmount
        );

        assertEq(
            bountyPulse.getWithdrawableBalance(address(this)),
            platformFee
        );
    }

    function testNonArbiterCannotResolveDispute() public {
        uint256 bountyId = prepareCompletedBounty();

        vm.prank(client);

        bountyPulse.disputeBounty(bountyId);

        vm.prank(freelancer);

        vm.expectRevert("Only arbiter can perform this action");

        bountyPulse.resolveDispute(
            bountyId,
            true
        );
    }

    // ---------------------------------------------------------
    // PULL PAYMENT TESTS
    // ---------------------------------------------------------

    function testFreelancerCanClaimFunds() public {
        uint256 bountyId = prepareCompletedBounty();

        vm.prank(client);

        bountyPulse.approveWork(bountyId);

        uint256 expectedPayment =
            BID - ((BID * 2) / 100);

        uint256 balanceBefore =
            freelancer.balance;

        vm.prank(freelancer);

        bountyPulse.claimFunds();

        uint256 balanceAfter =
            freelancer.balance;

        assertEq(
            balanceAfter - balanceBefore,
            expectedPayment
        );

        assertEq(
            bountyPulse.getWithdrawableBalance(freelancer),
            0
        );
    }

    function testCannotClaimWithoutFunds() public {
        vm.prank(freelancer);

        vm.expectRevert("No funds available");

        bountyPulse.claimFunds();
    }

    // ---------------------------------------------------------
    // MULTIPLE BIDS TEST
    // ---------------------------------------------------------

    function testMultipleFreelancersCanBid() public {
        uint256 bountyId = createBounty();

        vm.prank(freelancer);

        bountyPulse.placeBid(
            bountyId,
            0.7 ether
        );

        vm.prank(freelancer2);

        bountyPulse.placeBid(
            bountyId,
            0.6 ether
        );

        BountyPulse.Bid[] memory bids =
            bountyPulse.getBids(bountyId);

        assertEq(bids.length, 2);

        assertEq(
            bids[0].freelancer,
            freelancer
        );

        assertEq(
            bids[0].amount,
            0.7 ether
        );

        assertEq(
            bids[1].freelancer,
            freelancer2
        );

        assertEq(
            bids[1].amount,
            0.6 ether
        );
    }
}