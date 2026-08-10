// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BountyPulse {
    enum Role { None, Client, Freelancer, Arbiter }
    enum BountyStatus { Open, Locked, Resolved, Disputed, Refunded }

    struct User {
        string name;
        Role role;
        string ipfsAvatarHash;
        uint256 reputation;
        bool registered;
    }

    struct Bounty {
        uint256 id;
        address client;
        uint256 maxBudget;
        string ipfsBountyDetailsHash;
        BountyStatus status;
        address selectedFreelancer;
        uint256 selectedBid;
        string ipfsWorkFileHash;
    }

    struct Bid {
        address freelancer;
        uint256 amount;
    }

    address public arbiter;
    uint256 public bountyCounter;

    mapping(address => User) public users;
    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => Bid[]) public bountyBids;
    mapping(address => uint256) public withdrawableBalance;

    event UserRegistered(address indexed user, string name, Role role);
    event BountyPosted(uint256 indexed bountyId, address indexed client, uint256 maxBudget, string ipfsBountyDetailsHash);
    event BidPlaced(uint256 indexed bountyId, address indexed freelancer, uint256 amount);
    event BountyFunded(uint256 indexed bountyId, address indexed freelancer, uint256 amount);
    event WorkSubmitted(uint256 indexed bountyId, address indexed freelancer, string ipfsWorkFileHash);
    event WorkApproved(uint256 indexed bountyId, address indexed freelancer, uint256 freelancerAmount, uint256 platformFee);
    event BountyDisputed(uint256 indexed bountyId, address indexed client);
    event DisputeResolved(uint256 indexed bountyId, bool freelancerAtFault);
    event FundsClaimed(address indexed user, uint256 amount);

    constructor() {
        arbiter = msg.sender;
        users[msg.sender] = User({
            name: "Arbiter",
            role: Role.Arbiter,
            ipfsAvatarHash: "",
            reputation: 100,
            registered: true
        });
        emit UserRegistered(msg.sender, "Arbiter", Role.Arbiter);
    }

    modifier onlyRegistered() {
        require(users[msg.sender].registered, "User is not registered");
        _;
    }

    modifier onlyClient() {
        require(users[msg.sender].registered, "User is not registered");
        require(users[msg.sender].role == Role.Client, "Only client can perform this action");
        _;
    }

    modifier onlyFreelancer() {
        require(users[msg.sender].registered, "User is not registered");
        require(users[msg.sender].role == Role.Freelancer, "Only freelancer can perform this action");
        _;
    }

    modifier onlyArbiter() {
        require(msg.sender == arbiter, "Only arbiter can perform this action");
        _;
    }

    function registerUser(
        string calldata _name,
        Role _role,
        string calldata _ipfsAvatarHash
    ) external {
        require(!users[msg.sender].registered, "Wallet already registered");
        require(_role == Role.Client || _role == Role.Freelancer, "Invalid role");
        require(bytes(_name).length > 0, "Name required");

        uint256 startingReputation = _role == Role.Freelancer ? 100 : 0;

        users[msg.sender] = User({
            name: _name,
            role: _role,
            ipfsAvatarHash: _ipfsAvatarHash,
            reputation: startingReputation,
            registered: true
        });

        emit UserRegistered(msg.sender, _name, _role);
    }

    function postBounty(
        uint256 _maxBudget,
        string calldata _ipfsBountyDetailsHash
    ) external onlyClient returns (uint256) {
        require(_maxBudget > 0, "Budget must be greater than zero");
        require(bytes(_ipfsBountyDetailsHash).length > 0, "Bounty details CID required");

        bountyCounter++;

        bounties[bountyCounter] = Bounty({
            id: bountyCounter,
            client: msg.sender,
            maxBudget: _maxBudget,
            ipfsBountyDetailsHash: _ipfsBountyDetailsHash,
            status: BountyStatus.Open,
            selectedFreelancer: address(0),
            selectedBid: 0,
            ipfsWorkFileHash: ""
        });

        emit BountyPosted(
            bountyCounter,
            msg.sender,
            _maxBudget,
            _ipfsBountyDetailsHash
        );

        return bountyCounter;
    }

    function placeBid(uint256 _bountyId, uint256 _amount) external onlyFreelancer {
        Bounty storage bounty = bounties[_bountyId];

        require(bounty.id != 0, "Bounty does not exist");
        require(bounty.status == BountyStatus.Open, "Bounty is not open");
        require(users[msg.sender].reputation >= 40, "Reputation too low to bid");
        require(_amount > 0, "Bid must be greater than zero");
        require(_amount <= bounty.maxBudget, "Bid exceeds maximum budget");

        bountyBids[_bountyId].push(Bid({
            freelancer: msg.sender,
            amount: _amount
        }));

        emit BidPlaced(_bountyId, msg.sender, _amount);
    }

    function fundBounty(
        uint256 _bountyId,
        address _freelancer,
        uint256 _bidAmount
    ) external payable onlyClient {
        Bounty storage bounty = bounties[_bountyId];

        require(bounty.id != 0, "Bounty does not exist");
        require(bounty.client == msg.sender, "Not bounty owner");
        require(bounty.status == BountyStatus.Open, "Bounty is not open");
        require(_freelancer != address(0), "Invalid freelancer");
        require(_bidAmount > 0, "Invalid bid amount");
        require(_bidAmount <= bounty.maxBudget, "Bid exceeds budget");

        bool validBid = false;
        Bid[] storage bids = bountyBids[_bountyId];

        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].freelancer == _freelancer && bids[i].amount == _bidAmount) {
                validBid = true;
                break;
            }
        }

        require(validBid, "Selected bid does not exist");
        require(msg.value >= _bidAmount, "Insufficient ETH sent");

        bounty.selectedFreelancer = _freelancer;
        bounty.selectedBid = _bidAmount;
        bounty.status = BountyStatus.Locked;

        uint256 excess = msg.value - _bidAmount;

        if (excess > 0) {
            (bool refunded, ) = payable(msg.sender).call{value: excess}("");
            require(refunded, "Excess refund failed");
        }

        emit BountyFunded(_bountyId, _freelancer, _bidAmount);
    }

    function submitWork(
        uint256 _bountyId,
        string calldata _ipfsWorkFileHash
    ) external onlyFreelancer {
        Bounty storage bounty = bounties[_bountyId];

        require(bounty.id != 0, "Bounty does not exist");
        require(bounty.status == BountyStatus.Locked, "Bounty is not locked");
        require(bounty.selectedFreelancer == msg.sender, "You are not the selected freelancer");
        require(bytes(_ipfsWorkFileHash).length > 0, "Work CID required");

        bounty.ipfsWorkFileHash = _ipfsWorkFileHash;

        emit WorkSubmitted(_bountyId, msg.sender, _ipfsWorkFileHash);
    }

    function approveWork(uint256 _bountyId) external onlyClient {
        Bounty storage bounty = bounties[_bountyId];

        require(bounty.id != 0, "Bounty does not exist");
        require(bounty.client == msg.sender, "Not bounty owner");
        require(bounty.status == BountyStatus.Locked, "Bounty is not locked");
        require(bytes(bounty.ipfsWorkFileHash).length > 0, "Work has not been submitted");

        uint256 escrowAmount = bounty.selectedBid;
        uint256 platformFee = (escrowAmount * 2) / 100;
        uint256 freelancerAmount = escrowAmount - platformFee;

        withdrawableBalance[bounty.selectedFreelancer] += freelancerAmount;
        withdrawableBalance[arbiter] += platformFee;
        users[bounty.selectedFreelancer].reputation += 15;
        bounty.status = BountyStatus.Resolved;

        emit WorkApproved(
            _bountyId,
            bounty.selectedFreelancer,
            freelancerAmount,
            platformFee
        );
    }

    function disputeBounty(uint256 _bountyId) external onlyClient {
        Bounty storage bounty = bounties[_bountyId];

        require(bounty.id != 0, "Bounty does not exist");
        require(bounty.client == msg.sender, "Not bounty owner");
        require(bounty.status == BountyStatus.Locked, "Bounty is not locked");
        require(bytes(bounty.ipfsWorkFileHash).length > 0, "Work has not been submitted");

        bounty.status = BountyStatus.Disputed;
        emit BountyDisputed(_bountyId, msg.sender);
    }

    function resolveDispute(
        uint256 _bountyId,
        bool _freelancerAtFault
    ) external onlyArbiter {
        Bounty storage bounty = bounties[_bountyId];

        require(bounty.id != 0, "Bounty does not exist");
        require(bounty.status == BountyStatus.Disputed, "Bounty is not disputed");

        uint256 escrowAmount = bounty.selectedBid;

        if (_freelancerAtFault) {
            withdrawableBalance[bounty.client] += escrowAmount;

            uint256 currentReputation = users[bounty.selectedFreelancer].reputation;
            if (currentReputation >= 30) {
                users[bounty.selectedFreelancer].reputation = currentReputation - 30;
            } else {
                users[bounty.selectedFreelancer].reputation = 0;
            }

            bounty.status = BountyStatus.Refunded;
        } else {
            uint256 platformFee = (escrowAmount * 2) / 100;
            uint256 freelancerAmount = escrowAmount - platformFee;

            withdrawableBalance[bounty.selectedFreelancer] += freelancerAmount;
            withdrawableBalance[arbiter] += platformFee;

            bounty.status = BountyStatus.Resolved;
        }

        emit DisputeResolved(_bountyId, _freelancerAtFault);
    }

    function claimFunds() external onlyRegistered {
        uint256 amount = withdrawableBalance[msg.sender];
        require(amount > 0, "No funds available");

        withdrawableBalance[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");

        emit FundsClaimed(msg.sender, amount);
    }

    function getBids(uint256 _bountyId) external view returns (Bid[] memory) {
        return bountyBids[_bountyId];
    }

    function getWithdrawableBalance(address _user) external view returns (uint256) {
        return withdrawableBalance[_user];
    }

    function getUser(address _user)
        external
        view
        returns (
            string memory name,
            Role role,
            string memory ipfsAvatarHash,
            uint256 reputation,
            bool registered
        )
    {
        User memory user = users[_user];
        return (
            user.name,
            user.role,
            user.ipfsAvatarHash,
            user.reputation,
            user.registered
        );
    }

    function getBounty(uint256 _bountyId)
        external
        view
        returns (Bounty memory)
    {
        return bounties[_bountyId];
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
