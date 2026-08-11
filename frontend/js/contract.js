/* ==========================================================================
   contract.js — the contract's shape, as the DApp sees it
   --------------------------------------------------------------------------
   Single responsibility: know WHAT the contract is (ABI, enums, address) and
   nothing about HOW the UI uses it. No DOM access, no network calls, no ethers
   dependency — this file is pure data plus small pure functions, which makes it
   trivially testable and impossible to break by editing the UI.

   Address resolution order (first hit wins):
     1. window.BOUNTYPULSE_DEPLOYMENT  — written by scripts/deploy-local.sh
     2. localStorage override          — pasted into the "no contract" banner
     3. null                           — the UI then asks the user

   The ABI below is the exact artifact ABI (out/BountyPulse.sol/BountyPulse.json)
   committed as a fallback so the page works before the first deploy. When a
   deployment file is present, ITS abi wins — that copy is guaranteed to match
   the bytecode actually running on the chain.
   ========================================================================== */

(function (global) {
  "use strict";

  /** Local Anvil chain. MetaMask must be on this network. */
  var EXPECTED_CHAIN_ID = 31337;

  var STORAGE_KEY_ADDRESS = "bountypulse.contractAddress";

  /* ----------------------------------------------------------------------
     Enums — must mirror src/BountyPulse.sol exactly. Solidity enums are
     uint8 on the wire, and ethers v6 returns them as BigInt, so every
     comparison in the app goes through Number() first.
     ---------------------------------------------------------------------- */

  var Role = Object.freeze({
    Unregistered: 0,
    Client: 1,
    Freelancer: 2,
    Arbiter: 3
  });

  var BountyStatus = Object.freeze({
    None: 0,
    Open: 1,
    Locked: 2,
    Submitted: 3,
    Disputed: 4,
    Resolved: 5,
    Refunded: 6
  });

  var DisputeOutcome = Object.freeze({
    FreelancerFault: 0,
    ClientFault: 1
  });

  var ROLE_LABELS = ["Unregistered", "Client", "Freelancer", "Arbiter"];

  var STATUS_LABELS = ["None", "Open", "Locked", "Submitted", "Disputed", "Resolved", "Refunded"];

  /** Maps a status to a badge modifier class so colour always means the same thing. */
  var STATUS_TONES = {
    0: "muted",
    1: "info",
    2: "warn",
    3: "info",
    4: "danger",
    5: "ok",
    6: "muted"
  };

  /** Plain-English explanation of each terminal/intermediate state, for tooltips. */
  var STATUS_HINTS = {
    1: "Accepting bids. No ETH is locked yet.",
    2: "A bid was accepted and the exact amount is held in escrow.",
    3: "Work was delivered and is awaiting the client's review.",
    4: "The client rejected the delivery. The Arbiter decides.",
    5: "Settled: the freelancer was paid (minus the 2% fee).",
    6: "Settled: the escrow was returned to the client."
  };

  /* ----------------------------------------------------------------------
     Human-readable messages for the contract's custom errors. Showing
     "ReputationTooLow" to a user is a failure of care; showing "your
     reputation is 10, you need 40" is support they can act on.
     ---------------------------------------------------------------------- */
  var ERROR_MESSAGES = {
    AlreadyRegistered: function () {
      return "This wallet is already registered. One address gets one account, permanently.";
    },
    NotRegistered: function () {
      return "This wallet is not in the registry yet.";
    },
    InvalidRole: function () {
      return "That role cannot be selected.";
    },
    ArbiterIsFixedAtDeployment: function () {
      return "The Arbiter is the contract deployer and cannot be claimed.";
    },
    EmptyName: function () {
      return "A display name is required.";
    },
    NameTooLong: function (a) {
      return "Name is " + a[0] + " characters; the maximum is " + a[1] + ".";
    },
    InvalidCid: function () {
      return "That IPFS CID does not look valid. Re-upload the file.";
    },
    CallerIsNotClient: function () {
      return "Only a registered Client can do that.";
    },
    CallerIsNotFreelancer: function () {
      return "Only a registered Freelancer can do that.";
    },
    CallerIsNotArbiter: function () {
      return "Only the Arbiter can do that.";
    },
    NotBountyOwner: function () {
      return "Only the client who posted this bounty can do that.";
    },
    NotAwardedFreelancer: function () {
      return "Only the freelancer awarded this bounty can do that.";
    },
    BountyDoesNotExist: function (a) {
      return "Bounty #" + a[0] + " does not exist.";
    },
    InvalidBountyStatus: function (a) {
      return (
        "Bounty #" + a[0] + " is " + labelForStatus(a[1]) +
        ", but this action requires it to be " + labelForStatus(a[2]) + "."
      );
    },
    ZeroBudget: function () {
      return "The maximum budget must be greater than zero.";
    },
    ZeroBidAmount: function () {
      return "A bid must be greater than zero.";
    },
    BidExceedsBudget: function () {
      return "That quote is above the client's maximum budget.";
    },
    ReputationTooLow: function (a) {
      return "Reputation gate: your score is " + a[0] + " and bidding requires at least " + a[1] + ".";
    },
    DuplicateBid: function () {
      return "You have already quoted on this bounty. Quotes are final.";
    },
    BidNotFound: function () {
      return "No bid from that freelancer exists on this bounty.";
    },
    InsufficientEscrowPayment: function () {
      return "Underpayment: the full bid amount must be sent. The transaction was reverted.";
    },
    NothingToClaim: function () {
      return "There is nothing to claim right now.";
    },
    TransferFailed: function () {
      return "The ETH transfer failed — your wallet rejected the incoming payment.";
    },
    ReentrantCall: function () {
      return "Re-entrant call blocked.";
    },
    DirectPaymentsNotAccepted: function () {
      return "This contract only accepts ETH through the escrow funding function.";
    }
  };

  /* ----------------------------------------------------------------------
     Pure helpers
     ---------------------------------------------------------------------- */

  function labelForRole(role) {
    return ROLE_LABELS[Number(role)] || "Unknown";
  }

  function labelForStatus(status) {
    return STATUS_LABELS[Number(status)] || "Unknown";
  }

  function toneForStatus(status) {
    return STATUS_TONES[Number(status)] || "muted";
  }

  function hintForStatus(status) {
    return STATUS_HINTS[Number(status)] || "";
  }

  function isAddress(value) {
    return typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value);
  }

  /** Returns the generated deployment record, or null before the first deploy. */
  function getDeployment() {
    var d = global.BOUNTYPULSE_DEPLOYMENT;
    return d && isAddress(d.address) ? d : null;
  }

  function getAbi() {
    var deployment = getDeployment();
    // Prefer the deployed ABI: it provably matches the running bytecode.
    if (deployment && Array.isArray(deployment.abi) && deployment.abi.length > 0) {
      return deployment.abi;
    }
    return FALLBACK_ABI;
  }

  function getStoredAddress() {
    try {
      var stored = global.localStorage.getItem(STORAGE_KEY_ADDRESS);
      return isAddress(stored) ? stored : null;
    } catch (err) {
      // localStorage throws in private mode / when storage is disabled. Not fatal.
      return null;
    }
  }

  function getAddress() {
    var deployment = getDeployment();
    if (deployment) return deployment.address;
    return getStoredAddress();
  }

  function setAddressOverride(address) {
    if (!isAddress(address)) throw new Error("Not a valid 0x address: " + address);
    try {
      global.localStorage.setItem(STORAGE_KEY_ADDRESS, address);
    } catch (err) {
      /* storage unavailable — the address still applies for this session */
    }
    return address;
  }

  function clearAddressOverride() {
    try {
      global.localStorage.removeItem(STORAGE_KEY_ADDRESS);
    } catch (err) {
      /* nothing to do */
    }
  }

  /**
   * Turns any thrown object from an ethers call into something worth showing a
   * user. Handles, in order: user rejection, decoded custom errors, plain
   * revert strings, and finally a trimmed generic message.
   *
   * @param {unknown} error   the thrown value
   * @returns {{title: string, detail: string, code: string}}
   */
  function explainError(error) {
    if (!error) return {title: "Unknown error", detail: "", code: "UNKNOWN"};

    var code = error.code || (error.info && error.info.error && error.info.error.code);

    // MetaMask: user clicked Reject. Not an error worth alarming anyone about.
    if (code === "ACTION_REJECTED" || code === 4001) {
      return {title: "Transaction rejected", detail: "You dismissed the wallet prompt.", code: "ACTION_REJECTED"};
    }

    // ethers v6 decodes custom errors into `error.revert` when the ABI has them.
    var revert = error.revert;
    if (revert && revert.name) {
      var formatter = ERROR_MESSAGES[revert.name];
      var args = (revert.args || []).map(function (a) {
        return typeof a === "bigint" ? a.toString() : a;
      });
      return {
        title: revert.name,
        detail: formatter ? formatter(args) : "Reverted: " + revert.name + "(" + args.join(", ") + ")",
        code: "REVERT"
      };
    }

    if (error.reason) {
      return {title: "Transaction reverted", detail: String(error.reason), code: "REVERT"};
    }

    if (code === "INSUFFICIENT_FUNDS") {
      return {
        title: "Insufficient funds",
        detail: "This account does not hold enough ETH for the value plus gas.",
        code: "INSUFFICIENT_FUNDS"
      };
    }

    if (code === "CALL_EXCEPTION") {
      return {
        title: "Call failed",
        detail: "The contract rejected the call. Check that the address and chain are correct.",
        code: "CALL_EXCEPTION"
      };
    }

    var message = error.shortMessage || error.message || String(error);
    return {title: "Error", detail: message.slice(0, 240), code: String(code || "ERROR")};
  }

  /* ----------------------------------------------------------------------
     ABI — generated from the Solidity compiler artifact.
     Regenerate with:
       jq -c '.abi' out/BountyPulse.sol/BountyPulse.json
     ---------------------------------------------------------------------- */
  var FALLBACK_ABI = [
    {
      "type": "constructor",
      "inputs": [
        {
          "name": "arbiterName",
          "type": "string",
          "internalType": "string"
        },
        {
          "name": "arbiterAvatarCid",
          "type": "string",
          "internalType": "string"
        }
      ],
      "stateMutability": "nonpayable"
    },
    {
      "type": "fallback",
      "stateMutability": "payable"
    },
    {
      "type": "receive",
      "stateMutability": "payable"
    },
    {
      "type": "function",
      "name": "BPS_DENOMINATOR",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "INITIAL_REPUTATION",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint32",
          "internalType": "uint32"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "MIN_BID_REPUTATION",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint32",
          "internalType": "uint32"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "PLATFORM_FEE_BPS",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "REPUTATION_PENALTY",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint32",
          "internalType": "uint32"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "REPUTATION_REWARD",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint32",
          "internalType": "uint32"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "approveWork",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "outputs": [],
      "stateMutability": "nonpayable"
    },
    {
      "type": "function",
      "name": "arbiter",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "address",
          "internalType": "address"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "bountyCount",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "canBid",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "internalType": "address"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "bool",
          "internalType": "bool"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "claimFunds",
      "inputs": [],
      "outputs": [
        {
          "name": "amount",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "nonpayable"
    },
    {
      "type": "function",
      "name": "fundEscrow",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "freelancer",
          "type": "address",
          "internalType": "address"
        }
      ],
      "outputs": [],
      "stateMutability": "payable"
    },
    {
      "type": "function",
      "name": "getAllBounties",
      "inputs": [],
      "outputs": [
        {
          "name": "bounties",
          "type": "tuple[]",
          "internalType": "struct BountyPulse.Bounty[]",
          "components": [
            {
              "name": "id",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "client",
              "type": "address",
              "internalType": "address"
            },
            {
              "name": "freelancer",
              "type": "address",
              "internalType": "address"
            },
            {
              "name": "maxBudget",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "escrowAmount",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "ipfsDetailsHash",
              "type": "string",
              "internalType": "string"
            },
            {
              "name": "ipfsWorkHash",
              "type": "string",
              "internalType": "string"
            },
            {
              "name": "status",
              "type": "uint8",
              "internalType": "enum BountyPulse.BountyStatus"
            },
            {
              "name": "createdAt",
              "type": "uint64",
              "internalType": "uint64"
            },
            {
              "name": "updatedAt",
              "type": "uint64",
              "internalType": "uint64"
            }
          ]
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getBid",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "freelancer",
          "type": "address",
          "internalType": "address"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "tuple",
          "internalType": "struct BountyPulse.Bid",
          "components": [
            {
              "name": "freelancer",
              "type": "address",
              "internalType": "address"
            },
            {
              "name": "amount",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "placedAt",
              "type": "uint64",
              "internalType": "uint64"
            }
          ]
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getBidCount",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getBids",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "tuple[]",
          "internalType": "struct BountyPulse.Bid[]",
          "components": [
            {
              "name": "freelancer",
              "type": "address",
              "internalType": "address"
            },
            {
              "name": "amount",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "placedAt",
              "type": "uint64",
              "internalType": "uint64"
            }
          ]
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getBountiesPaged",
      "inputs": [
        {
          "name": "offset",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "limit",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "outputs": [
        {
          "name": "bounties",
          "type": "tuple[]",
          "internalType": "struct BountyPulse.Bounty[]",
          "components": [
            {
              "name": "id",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "client",
              "type": "address",
              "internalType": "address"
            },
            {
              "name": "freelancer",
              "type": "address",
              "internalType": "address"
            },
            {
              "name": "maxBudget",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "escrowAmount",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "ipfsDetailsHash",
              "type": "string",
              "internalType": "string"
            },
            {
              "name": "ipfsWorkHash",
              "type": "string",
              "internalType": "string"
            },
            {
              "name": "status",
              "type": "uint8",
              "internalType": "enum BountyPulse.BountyStatus"
            },
            {
              "name": "createdAt",
              "type": "uint64",
              "internalType": "uint64"
            },
            {
              "name": "updatedAt",
              "type": "uint64",
              "internalType": "uint64"
            }
          ]
        },
        {
          "name": "total",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getBounty",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "tuple",
          "internalType": "struct BountyPulse.Bounty",
          "components": [
            {
              "name": "id",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "client",
              "type": "address",
              "internalType": "address"
            },
            {
              "name": "freelancer",
              "type": "address",
              "internalType": "address"
            },
            {
              "name": "maxBudget",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "escrowAmount",
              "type": "uint256",
              "internalType": "uint256"
            },
            {
              "name": "ipfsDetailsHash",
              "type": "string",
              "internalType": "string"
            },
            {
              "name": "ipfsWorkHash",
              "type": "string",
              "internalType": "string"
            },
            {
              "name": "status",
              "type": "uint8",
              "internalType": "enum BountyPulse.BountyStatus"
            },
            {
              "name": "createdAt",
              "type": "uint64",
              "internalType": "uint64"
            },
            {
              "name": "updatedAt",
              "type": "uint64",
              "internalType": "uint64"
            }
          ]
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getRegisteredUserCount",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getRegisteredUsers",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "address[]",
          "internalType": "address[]"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getReputation",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "internalType": "address"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "uint32",
          "internalType": "uint32"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getRole",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "internalType": "address"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "uint8",
          "internalType": "enum BountyPulse.Role"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getUser",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "internalType": "address"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "tuple",
          "internalType": "struct BountyPulse.User",
          "components": [
            {
              "name": "name",
              "type": "string",
              "internalType": "string"
            },
            {
              "name": "ipfsAvatarHash",
              "type": "string",
              "internalType": "string"
            },
            {
              "name": "role",
              "type": "uint8",
              "internalType": "enum BountyPulse.Role"
            },
            {
              "name": "reputation",
              "type": "uint32",
              "internalType": "uint32"
            },
            {
              "name": "registeredAt",
              "type": "uint64",
              "internalType": "uint64"
            },
            {
              "name": "isRegistered",
              "type": "bool",
              "internalType": "bool"
            }
          ]
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "getWithdrawableBalance",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "internalType": "address"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "hasBid",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "freelancer",
          "type": "address",
          "internalType": "address"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "bool",
          "internalType": "bool"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "isRegistered",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "internalType": "address"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "bool",
          "internalType": "bool"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "placeBid",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "amount",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "outputs": [],
      "stateMutability": "nonpayable"
    },
    {
      "type": "function",
      "name": "postBounty",
      "inputs": [
        {
          "name": "maxBudget",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "detailsCid",
          "type": "string",
          "internalType": "string"
        }
      ],
      "outputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "nonpayable"
    },
    {
      "type": "function",
      "name": "previewFeeSplit",
      "inputs": [
        {
          "name": "amount",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "outputs": [
        {
          "name": "fee",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "payout",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "pure"
    },
    {
      "type": "function",
      "name": "raiseDispute",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "outputs": [],
      "stateMutability": "nonpayable"
    },
    {
      "type": "function",
      "name": "registerUser",
      "inputs": [
        {
          "name": "name",
          "type": "string",
          "internalType": "string"
        },
        {
          "name": "role",
          "type": "uint8",
          "internalType": "enum BountyPulse.Role"
        },
        {
          "name": "avatarCid",
          "type": "string",
          "internalType": "string"
        }
      ],
      "outputs": [],
      "stateMutability": "nonpayable"
    },
    {
      "type": "function",
      "name": "resolveDispute",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "outcome",
          "type": "uint8",
          "internalType": "enum BountyPulse.DisputeOutcome"
        }
      ],
      "outputs": [],
      "stateMutability": "nonpayable"
    },
    {
      "type": "function",
      "name": "submitWork",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "workFileCid",
          "type": "string",
          "internalType": "string"
        }
      ],
      "outputs": [],
      "stateMutability": "nonpayable"
    },
    {
      "type": "function",
      "name": "totalEscrowed",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "totalLiabilities",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "totalWithdrawable",
      "inputs": [],
      "outputs": [
        {
          "name": "",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "function",
      "name": "withdrawableBalance",
      "inputs": [
        {
          "name": "",
          "type": "address",
          "internalType": "address"
        }
      ],
      "outputs": [
        {
          "name": "",
          "type": "uint256",
          "internalType": "uint256"
        }
      ],
      "stateMutability": "view"
    },
    {
      "type": "event",
      "name": "BalanceCredited",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "amount",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        },
        {
          "name": "newBalance",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "BidPlaced",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "indexed": true,
          "internalType": "uint256"
        },
        {
          "name": "freelancer",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "amount",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        },
        {
          "name": "bidIndex",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "BountyPosted",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "indexed": true,
          "internalType": "uint256"
        },
        {
          "name": "client",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "maxBudget",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        },
        {
          "name": "ipfsDetailsHash",
          "type": "string",
          "indexed": false,
          "internalType": "string"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "BountyStatusChanged",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "indexed": true,
          "internalType": "uint256"
        },
        {
          "name": "previousStatus",
          "type": "uint8",
          "indexed": false,
          "internalType": "enum BountyPulse.BountyStatus"
        },
        {
          "name": "newStatus",
          "type": "uint8",
          "indexed": false,
          "internalType": "enum BountyPulse.BountyStatus"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "DirectRefund",
      "inputs": [
        {
          "name": "to",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "amount",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "DisputeRaised",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "indexed": true,
          "internalType": "uint256"
        },
        {
          "name": "client",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "previousStatus",
          "type": "uint8",
          "indexed": false,
          "internalType": "enum BountyPulse.BountyStatus"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "DisputeResolved",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "indexed": true,
          "internalType": "uint256"
        },
        {
          "name": "resolvedBy",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "outcome",
          "type": "uint8",
          "indexed": false,
          "internalType": "enum BountyPulse.DisputeOutcome"
        },
        {
          "name": "clientRefund",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        },
        {
          "name": "freelancerPayout",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        },
        {
          "name": "platformFee",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "EscrowFunded",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "indexed": true,
          "internalType": "uint256"
        },
        {
          "name": "client",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "freelancer",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "escrowAmount",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        },
        {
          "name": "refundedExcess",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "FundsClaimed",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "amount",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "RefundDeferred",
      "inputs": [
        {
          "name": "to",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "amount",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "ReputationChanged",
      "inputs": [
        {
          "name": "freelancer",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "previousScore",
          "type": "uint32",
          "indexed": false,
          "internalType": "uint32"
        },
        {
          "name": "newScore",
          "type": "uint32",
          "indexed": false,
          "internalType": "uint32"
        },
        {
          "name": "delta",
          "type": "int256",
          "indexed": false,
          "internalType": "int256"
        },
        {
          "name": "reason",
          "type": "string",
          "indexed": false,
          "internalType": "string"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "UserRegistered",
      "inputs": [
        {
          "name": "user",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "role",
          "type": "uint8",
          "indexed": true,
          "internalType": "enum BountyPulse.Role"
        },
        {
          "name": "name",
          "type": "string",
          "indexed": false,
          "internalType": "string"
        },
        {
          "name": "ipfsAvatarHash",
          "type": "string",
          "indexed": false,
          "internalType": "string"
        },
        {
          "name": "reputation",
          "type": "uint32",
          "indexed": false,
          "internalType": "uint32"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "WorkApproved",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "indexed": true,
          "internalType": "uint256"
        },
        {
          "name": "client",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "freelancer",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "freelancerPayout",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        },
        {
          "name": "platformFee",
          "type": "uint256",
          "indexed": false,
          "internalType": "uint256"
        }
      ],
      "anonymous": false
    },
    {
      "type": "event",
      "name": "WorkSubmitted",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "indexed": true,
          "internalType": "uint256"
        },
        {
          "name": "freelancer",
          "type": "address",
          "indexed": true,
          "internalType": "address"
        },
        {
          "name": "ipfsWorkFileHash",
          "type": "string",
          "indexed": false,
          "internalType": "string"
        }
      ],
      "anonymous": false
    },
    {
      "type": "error",
      "name": "AlreadyRegistered",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "internalType": "address"
        }
      ]
    },
    {
      "type": "error",
      "name": "ArbiterIsFixedAtDeployment",
      "inputs": []
    },
    {
      "type": "error",
      "name": "BidExceedsBudget",
      "inputs": [
        {
          "name": "bidAmount",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "maxBudget",
          "type": "uint256",
          "internalType": "uint256"
        }
      ]
    },
    {
      "type": "error",
      "name": "BidNotFound",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "freelancer",
          "type": "address",
          "internalType": "address"
        }
      ]
    },
    {
      "type": "error",
      "name": "BountyDoesNotExist",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        }
      ]
    },
    {
      "type": "error",
      "name": "CallerIsNotArbiter",
      "inputs": [
        {
          "name": "caller",
          "type": "address",
          "internalType": "address"
        }
      ]
    },
    {
      "type": "error",
      "name": "CallerIsNotClient",
      "inputs": [
        {
          "name": "caller",
          "type": "address",
          "internalType": "address"
        }
      ]
    },
    {
      "type": "error",
      "name": "CallerIsNotFreelancer",
      "inputs": [
        {
          "name": "caller",
          "type": "address",
          "internalType": "address"
        }
      ]
    },
    {
      "type": "error",
      "name": "DirectPaymentsNotAccepted",
      "inputs": []
    },
    {
      "type": "error",
      "name": "DuplicateBid",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "freelancer",
          "type": "address",
          "internalType": "address"
        }
      ]
    },
    {
      "type": "error",
      "name": "EmptyName",
      "inputs": []
    },
    {
      "type": "error",
      "name": "InsufficientEscrowPayment",
      "inputs": [
        {
          "name": "required",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "sent",
          "type": "uint256",
          "internalType": "uint256"
        }
      ]
    },
    {
      "type": "error",
      "name": "InvalidBountyStatus",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "current",
          "type": "uint8",
          "internalType": "enum BountyPulse.BountyStatus"
        },
        {
          "name": "required",
          "type": "uint8",
          "internalType": "enum BountyPulse.BountyStatus"
        }
      ]
    },
    {
      "type": "error",
      "name": "InvalidCid",
      "inputs": [
        {
          "name": "cid",
          "type": "string",
          "internalType": "string"
        }
      ]
    },
    {
      "type": "error",
      "name": "InvalidRole",
      "inputs": [
        {
          "name": "provided",
          "type": "uint8",
          "internalType": "enum BountyPulse.Role"
        }
      ]
    },
    {
      "type": "error",
      "name": "NameTooLong",
      "inputs": [
        {
          "name": "length",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "maxLength",
          "type": "uint256",
          "internalType": "uint256"
        }
      ]
    },
    {
      "type": "error",
      "name": "NotAwardedFreelancer",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "caller",
          "type": "address",
          "internalType": "address"
        }
      ]
    },
    {
      "type": "error",
      "name": "NotBountyOwner",
      "inputs": [
        {
          "name": "bountyId",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "caller",
          "type": "address",
          "internalType": "address"
        }
      ]
    },
    {
      "type": "error",
      "name": "NotRegistered",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "internalType": "address"
        }
      ]
    },
    {
      "type": "error",
      "name": "NothingToClaim",
      "inputs": [
        {
          "name": "account",
          "type": "address",
          "internalType": "address"
        }
      ]
    },
    {
      "type": "error",
      "name": "ReentrantCall",
      "inputs": []
    },
    {
      "type": "error",
      "name": "ReputationTooLow",
      "inputs": [
        {
          "name": "reputation",
          "type": "uint256",
          "internalType": "uint256"
        },
        {
          "name": "required",
          "type": "uint256",
          "internalType": "uint256"
        }
      ]
    },
    {
      "type": "error",
      "name": "TransferFailed",
      "inputs": [
        {
          "name": "to",
          "type": "address",
          "internalType": "address"
        },
        {
          "name": "amount",
          "type": "uint256",
          "internalType": "uint256"
        }
      ]
    },
    {
      "type": "error",
      "name": "ZeroBidAmount",
      "inputs": []
    },
    {
      "type": "error",
      "name": "ZeroBudget",
      "inputs": []
    }
  ];

  global.BountyPulseContract = Object.freeze({
    EXPECTED_CHAIN_ID: EXPECTED_CHAIN_ID,
    STORAGE_KEY_ADDRESS: STORAGE_KEY_ADDRESS,
    Role: Role,
    BountyStatus: BountyStatus,
    DisputeOutcome: DisputeOutcome,
    ROLE_LABELS: ROLE_LABELS,
    STATUS_LABELS: STATUS_LABELS,
    labelForRole: labelForRole,
    labelForStatus: labelForStatus,
    toneForStatus: toneForStatus,
    hintForStatus: hintForStatus,
    isAddress: isAddress,
    getAbi: getAbi,
    getAddress: getAddress,
    getDeployment: getDeployment,
    setAddressOverride: setAddressOverride,
    clearAddressOverride: clearAddressOverride,
    explainError: explainError
  });
})(window);
