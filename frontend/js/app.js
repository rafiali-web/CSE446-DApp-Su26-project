/* ==========================================================================
   app.js — BountyPulse DApp
   --------------------------------------------------------------------------
   Responsibilities are separated into small modules inside one IIFE:

     Logger      structured, level-based logging with a correlation id per action
     Dom / Fmt   DOM and formatting helpers (pure)
     Toast/Busy  user feedback
     Wallet      MetaMask detection, accounts, chain, signer
     Chain       contract instances (read vs write) and data loading
     Feed        OFF-CHAIN sorting and filtering  <- gas-optimization demo
     Render      turns state into DOM, per role
     Actions     one function per user intent
     EventSync   contract.on(...) subscriptions and their teardown

   HARD RULE: this file never calls window.location.reload(). Every update is
   applied to the live DOM. Checkpoint 5 (two windows, instant sync) depends on
   it, and a reload would destroy in-flight form state anyway.
   ========================================================================== */

(function (global) {
  "use strict";

  var C = global.BountyPulseContract;
  var Ipfs = global.IpfsHelper;
  var Icons = global.Icons;

  /* ======================================================================
     Design-system vocabulary
     ----------------------------------------------------------------------
     The contract layer speaks in semantic tones (ok, info, warn, danger,
     muted). The design system speaks in tag variants. These two functions are
     the ONLY place the two vocabularies meet, so contract.js stays free of
     presentation and the stylesheet stays free of domain concepts.

     The scheme is mono - one accent - so a status cannot be told apart by hue.
     Distinction is carried by the VARIANT instead: a tinted fill for settled and
     active states, an outline for open ones, and the italic accent-2 tint for
     anything that wants attention.
     ====================================================================== */

  var TAG_FOR_TONE = {
    muted: "tag-neutral",
    info: "tag-outline",
    ok: "tag-accent",
    warn: "tag-accent-2",
    danger: "tag-accent-2"
  };

  function tagClass(tone) {
    return "tag " + (TAG_FOR_TONE[tone] || "tag-neutral");
  }

  /**
   * Edge-rule emphasis for toasts and activity rows. Colour is applied as
   * stroke, so the tone shows up as a 2px rule down one side, never as a fill.
   */
  function ruleModifier(base, tone) {
    if (tone === "ok") return base + "-accent";
    if (tone === "warn" || tone === "danger") return base + "-attention";
    return "";
  }

  var ETHERS_LOCAL = "vendor/ethers.umd.min.js";
  var ETHERS_CDN = "https://cdn.jsdelivr.net/npm/ethers@6.13.4/dist/ethers.umd.min.js";

  /** How often the read provider polls for new logs. Low, because this is a
   *  local chain and checkpoint 5 is judged on how instant the sync feels. */
  var POLL_INTERVAL_MS = 1000;

  /** Collapse bursts of events into a single refresh + re-render. */
  var REFRESH_DEBOUNCE_MS = 250;

  var MAX_ACTIVITY_ITEMS = 60;

  /* ======================================================================
     Logger
     ====================================================================== */

  var Logger = (function () {
    var LEVELS = {debug: 10, info: 20, warn: 30, error: 40};
    var threshold = LEVELS.debug;
    var correlationId = null;

    function emit(level, event, context) {
      if (LEVELS[level] < threshold) return;
      var entry = {
        ts: new Date().toISOString(),
        level: level.toUpperCase(),
        component: "bountypulse-dapp",
        correlationId: correlationId,
        event: event
      };
      if (context) entry.context = context;

      var fn = level === "debug" ? console.debug : console[level] || console.log;
      fn.call(console, "%c" + entry.level + "%c " + event, "font-weight:700", "", entry);
    }

    return {
      setLevel: function (name) {
        if (LEVELS[name] !== undefined) threshold = LEVELS[name];
      },
      /** Starts a traced action; every log until the next call carries this id. */
      startAction: function (name) {
        correlationId = name + "-" + Math.random().toString(36).slice(2, 9);
        emit("info", "action_started", {action: name});
        return correlationId;
      },
      endAction: function (name, outcome) {
        emit("info", "action_finished", {action: name, outcome: outcome});
        correlationId = null;
      },
      debug: function (e, c) { emit("debug", e, c); },
      info: function (e, c) { emit("info", e, c); },
      warn: function (e, c) { emit("warn", e, c); },
      error: function (e, c) { emit("error", e, c); }
    };
  })();

  global.BountyPulseLogger = Logger;

  /* ======================================================================
     DOM + formatting helpers (pure)
     ====================================================================== */

  function $(id) {
    return document.getElementById(id);
  }

  function show(node, visible) {
    if (!node) return;
    node.classList.toggle("hidden", !visible);
  }

  function setText(node, value) {
    if (node) node.textContent = value;
  }

  /**
   * HTML-escape. Bounty titles and descriptions come from IPFS, which is
   * attacker-controllable: anyone can pin `<img onerror=…>` and post it as a
   * brief. Every interpolation into innerHTML goes through this.
   */
  function esc(value) {
    if (value === null || value === undefined) return "";
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function shortAddress(address) {
    if (!address) return "0x0000…0000";
    return address.slice(0, 6) + "…" + address.slice(-4);
  }

  function sameAddress(a, b) {
    return !!a && !!b && a.toLowerCase() === b.toLowerCase();
  }

  /** Wei -> a compact ETH string. Never shows scientific notation. */
  function formatEth(wei) {
    if (wei === null || wei === undefined) return "0";
    var text = state.ethers.formatEther(wei);
    if (text.indexOf(".") === -1) return text;
    // Trim trailing zeros but keep at least one decimal for readability.
    text = text.replace(/(\.\d*?)0+$/, "$1").replace(/\.$/, ".0");
    return text;
  }

  function formatEthLabel(wei) {
    return formatEth(wei) + " ETH";
  }

  function timeAgo(unixSeconds) {
    var seconds = Math.floor(Date.now() / 1000) - Number(unixSeconds);
    if (!isFinite(seconds) || seconds < 0) return "just now";
    if (seconds < 60) return seconds + "s ago";
    if (seconds < 3600) return Math.floor(seconds / 60) + "m ago";
    if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago";
    return Math.floor(seconds / 86400) + "d ago";
  }

  function clockTime() {
    return new Date().toLocaleTimeString([], {hour12: false});
  }

  /* ======================================================================
     Toasts / busy overlay
     ====================================================================== */

  var Toast = {
    show: function (tone, title, text, timeoutMs) {
      var host = $("toasts");
      if (!host) return;

      // Reuses .card and the elevation utility rather than inventing a parallel
      // surface; .toast only positions, animates and carries the edge rule.
      var node = document.createElement("div");
      node.className = "card elev-lg toast " + ruleModifier("toast", tone);
      node.innerHTML =
        '<div class="toast-body">' +
        '<span class="toast-title">' + esc(title) + "</span>" +
        (text ? '<span class="toast-text">' + esc(text) + "</span>" : "") +
        "</div>" +
        '<button class="btn btn-ghost btn-icon btn-sm js-toast-close" aria-label="Dismiss">' +
        Icons.svg("x") +
        "</button>";

      function dismiss() {
        if (node.parentNode) node.parentNode.removeChild(node);
      }
      node.querySelector(".js-toast-close").addEventListener("click", dismiss);
      host.appendChild(node);

      var ttl = timeoutMs === undefined ? (tone === "error" ? 9000 : 5000) : timeoutMs;
      if (ttl > 0) setTimeout(dismiss, ttl);
    },
    ok: function (t, d) { this.show("ok", t, d); },
    info: function (t, d) { this.show("info", t, d); },
    warn: function (t, d) { this.show("warn", t, d); },
    error: function (t, d) { this.show("error", t, d); }
  };

  var Busy = {
    depth: 0,
    start: function (message) {
      this.depth += 1;
      setText($("busy-text"), message || "Working…");
      show($("busy"), true);
    },
    stop: function () {
      this.depth = Math.max(0, this.depth - 1);
      if (this.depth === 0) show($("busy"), false);
    }
  };

  /* ======================================================================
     Application state
     ====================================================================== */

  var state = {
    ethers: null,
    browserProvider: null,
    readProvider: null,
    signer: null,
    account: null,
    chainId: null,
    contractAddress: null,
    readContract: null,
    writeContract: null,
    arbiterAddress: null,
    profile: null,
    bounties: [],
    bidsByBounty: {},
    withdrawable: 0n,
    feed: {sort: "budget-desc", status: "open", search: ""},
    metadata: {},
    flashIds: {},
    listeners: [],
    refreshTimer: null
  };

  /* ======================================================================
     Ethers bootstrap
     ====================================================================== */

  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var tag = document.createElement("script");
      tag.src = src;
      tag.async = false;
      tag.onload = resolve;
      tag.onerror = function () {
        reject(new Error("Failed to load " + src));
      };
      document.head.appendChild(tag);
    });
  }

  /** Local vendored copy first (works offline), CDN as a fallback. */
  async function ensureEthers() {
    if (global.ethers) return global.ethers;

    try {
      await loadScript(ETHERS_LOCAL);
      Logger.info("ethers_loaded", {source: "vendor"});
    } catch (err) {
      Logger.warn("ethers_vendor_missing", {reason: err.message});
      await loadScript(ETHERS_CDN);
      Logger.info("ethers_loaded", {source: "cdn"});
    }

    if (!global.ethers) throw new Error("ethers.js failed to load from both the vendor path and the CDN.");
    return global.ethers;
  }

  /* ======================================================================
     Wallet
     ====================================================================== */

  var Wallet = {
    isAvailable: function () {
      return typeof global.ethereum !== "undefined";
    },

    /** Silent detection — never prompts. Used on page load (spec 3.1). */
    detectAccount: async function () {
      if (!this.isAvailable()) return null;
      var accounts = await global.ethereum.request({method: "eth_accounts"});
      return accounts && accounts.length ? accounts[0] : null;
    },

    /** Explicit connect — opens MetaMask. */
    requestAccount: async function () {
      var accounts = await global.ethereum.request({method: "eth_requestAccounts"});
      if (!accounts || !accounts.length) throw new Error("No account was authorised.");
      return accounts[0];
    },

    getChainId: async function () {
      var hex = await global.ethereum.request({method: "eth_chainId"});
      return parseInt(hex, 16);
    },

    /** Asks MetaMask to switch to Anvil, adding the network if it is unknown. */
    switchToLocalChain: async function () {
      var hexChainId = "0x" + C.EXPECTED_CHAIN_ID.toString(16);
      try {
        await global.ethereum.request({
          method: "wallet_switchEthereumChain",
          params: [{chainId: hexChainId}]
        });
      } catch (err) {
        // 4902 = chain not added to the wallet yet.
        if (err && (err.code === 4902 || (err.data && err.data.originalError && err.data.originalError.code === 4902))) {
          await global.ethereum.request({
            method: "wallet_addEthereumChain",
            params: [
              {
                chainId: hexChainId,
                chainName: "Anvil Local (BountyPulse)",
                nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
                rpcUrls: [rpcUrl()],
                blockExplorerUrls: []
              }
            ]
          });
        } else {
          throw err;
        }
      }
    }
  };

  function rpcUrl() {
    var deployment = C.getDeployment();
    return (deployment && deployment.rpcUrl) || "http://127.0.0.1:8545";
  }

  /* ======================================================================
     Chain: contract instances and data loading
     ====================================================================== */

  var Chain = {
    /**
     * Two providers, deliberately:
     *
     *   writeContract — bound to the MetaMask signer. Sends transactions.
     *   readContract  — bound to a direct JsonRpcProvider on the node. Serves
     *                   every `view` call and every event subscription.
     *
     * Splitting them means log polling does not depend on wallet-specific
     * filter support and keeps working while a wallet prompt is open. If the
     * node is not directly reachable from the browser we fall back to the
     * wallet's provider for reads too.
     */
    connectContracts: async function () {
      var address = C.getAddress();
      state.contractAddress = address;
      if (!address) return false;

      var abi = C.getAbi();

      var readProvider;
      try {
        readProvider = new state.ethers.JsonRpcProvider(rpcUrl(), undefined, {staticNetwork: true});
        await readProvider.getBlockNumber(); // prove it actually answers
        readProvider.pollingInterval = POLL_INTERVAL_MS;
        Logger.info("read_provider_ready", {transport: "direct-rpc", url: rpcUrl()});
      } catch (err) {
        Logger.warn("read_provider_fallback", {reason: err.message});
        readProvider = state.browserProvider;
        if (readProvider) readProvider.pollingInterval = POLL_INTERVAL_MS;
      }

      if (!readProvider) {
        Logger.warn("no_read_provider", {rpcUrl: rpcUrl()});
        Toast.warn("Cannot reach the chain", "Start anvil, then connect your wallet.");
        return false;
      }

      state.readProvider = readProvider;
      state.readContract = new state.ethers.Contract(address, abi, readProvider);
      state.writeContract = state.signer ? new state.ethers.Contract(address, abi, state.signer) : null;

      // Confirm there is actually a contract at this address before trusting it.
      var code = await readProvider.getCode(address);
      if (!code || code === "0x") {
        Logger.error("no_contract_code", {address: address});
        Toast.error("No contract at that address", "Re-run ./scripts/deploy-local.sh — anvil forgets state on restart.");
        state.readContract = null;
        state.writeContract = null;
        return false;
      }

      state.arbiterAddress = await state.readContract.arbiter();
      Logger.info("contracts_ready", {address: address, arbiter: state.arbiterAddress});
      return true;
    },

    loadProfile: async function () {
      if (!state.readContract || !state.account) {
        state.profile = null;
        return;
      }
      var user = await state.readContract.getUser(state.account);
      state.profile = {
        isRegistered: user.isRegistered,
        role: Number(user.role),
        name: user.name,
        avatarCid: user.ipfsAvatarHash,
        reputation: Number(user.reputation)
      };
      Logger.debug("profile_loaded", state.profile);
    },

    loadBounties: async function () {
      if (!state.readContract) {
        state.bounties = [];
        return;
      }

      var raw = await state.readContract.getAllBounties();

      state.bounties = raw.map(function (b) {
        return {
          id: Number(b.id),
          client: b.client,
          freelancer: b.freelancer,
          maxBudget: b.maxBudget,
          escrowAmount: b.escrowAmount,
          detailsCid: b.ipfsDetailsHash,
          workCid: b.ipfsWorkHash,
          status: Number(b.status),
          createdAt: Number(b.createdAt),
          updatedAt: Number(b.updatedAt)
        };
      });

      // One round-trip per bounty for its bids, all in flight at once. On a
      // local chain this is a handful of milliseconds; a public deployment
      // would want a subgraph or a batched multicall instead.
      var bidResults = await Promise.all(
        state.bounties.map(function (b) {
          return state.readContract.getBids(b.id).catch(function () {
            return [];
          });
        })
      );

      var map = {};
      state.bounties.forEach(function (b, index) {
        map[b.id] = bidResults[index].map(function (bid) {
          return {freelancer: bid.freelancer, amount: bid.amount, placedAt: Number(bid.placedAt)};
        });
      });
      state.bidsByBounty = map;

      Logger.debug("bounties_loaded", {count: state.bounties.length});
    },

    loadBalance: async function () {
      if (!state.readContract || !state.account) {
        state.withdrawable = 0n;
        return;
      }
      state.withdrawable = await state.readContract.withdrawableBalance(state.account);
    },

    refreshAll: async function () {
      if (!state.readContract) return;
      await Promise.all([this.loadProfile(), this.loadBounties(), this.loadBalance()]);
    }
  };

  /* ======================================================================
     Feed — OFF-CHAIN filtering and sorting
     ----------------------------------------------------------------------
     GAS-OPTIMIZATION DEMONSTRATION (spec 3.2)

     Everything below runs in the browser on data already fetched by a single
     `view` call. Nothing here costs gas, because nothing here is a transaction.

     The on-chain alternative would be a function like
     `getBountiesSortedByBudget()` that sorts storage before returning. That is
     the wrong place to do it:

       * A sort is O(n log n) comparisons, each one an SLOAD (~2100 gas cold).
         200 bounties is roughly 1,500 comparisons — hundreds of thousands of
         gas for a READ.
       * Sort order is a presentation concern. Two users wanting different
         orders would each pay for their own on-chain sort of identical data.
       * `view` calls executed through eth_call are free. Moving the work here
         takes the cost from "hundreds of thousands of gas" to "zero".

     Rule of thumb this illustrates: the chain stores and verifies; the client
     presents.
     ====================================================================== */

  var Feed = {
    apply: function (bounties) {
      var filtered = this.filter(bounties);
      return this.sort(filtered, state.feed.sort);
    },

    filter: function (bounties) {
      var mode = state.feed.status;
      var needle = state.feed.search.trim().toLowerCase();

      return bounties.filter(function (b) {
        if (mode === "open" && b.status !== C.BountyStatus.Open) return false;
        if (mode === "mine") {
          var bids = state.bidsByBounty[b.id] || [];
          var hasMine = bids.some(function (bid) {
            return sameAddress(bid.freelancer, state.account);
          });
          if (!hasMine) return false;
        }
        if (!needle) return true;

        var meta = state.metadata[b.detailsCid] || {};
        var haystack = [meta.title, meta.description, b.client, b.detailsCid, "#" + b.id]
          .filter(Boolean)
          .join(" ")
          .toLowerCase();
        return haystack.indexOf(needle) !== -1;
      });
    },

    /**
     * Pure comparator dispatch. Copies the array first: sorting in place would
     * mutate the canonical state array and quietly change every other view.
     */
    sort: function (bounties, mode) {
      var copy = bounties.slice();

      var comparators = {
        "budget-desc": function (a, b) {
          return compareBigInt(b.maxBudget, a.maxBudget);
        },
        "budget-asc": function (a, b) {
          return compareBigInt(a.maxBudget, b.maxBudget);
        },
        newest: function (a, b) {
          return b.createdAt - a.createdAt || b.id - a.id;
        },
        oldest: function (a, b) {
          return a.createdAt - b.createdAt || a.id - b.id;
        },
        "bids-desc": function (a, b) {
          return (state.bidsByBounty[b.id] || []).length - (state.bidsByBounty[a.id] || []).length;
        }
      };

      return copy.sort(comparators[mode] || comparators["budget-desc"]);
    }
  };

  /**
   * BigInt comparator. `a - b` cannot be returned directly: Array.prototype.sort
   * needs a Number, and wei differences overflow the safe integer range.
   */
  function compareBigInt(a, b) {
    if (a === b) return 0;
    return a > b ? 1 : -1;
  }

  /* ======================================================================
     Render
     ====================================================================== */

  var Render = {
    all: function () {
      this.header();
      this.banners();
      this.deploymentInfo();
      this.earnings();

      var connected = !!state.account;
      var registered = !!(state.profile && state.profile.isRegistered);
      var ready = connected && !!state.readContract && isCorrectChain();

      show($("view-disconnected"), !connected);
      show($("view-register"), ready && !registered);
      show($("view-dashboard"), ready && registered);

      if (!ready || !registered) return;

      var role = state.profile.role;
      show($("panel-client"), role === C.Role.Client);
      show($("panel-freelancer"), role === C.Role.Freelancer);
      show($("panel-arbiter"), role === C.Role.Arbiter);

      if (role === C.Role.Client) this.clientPanel();
      if (role === C.Role.Freelancer) this.freelancerPanel();
      if (role === C.Role.Arbiter) this.arbiterPanel();
    },

    header: function () {
      var connectBtn = $("btn-connect");
      var chip = $("account-chip");

      if (!state.account) {
        show(chip, false);
        show(connectBtn, true);
        connectBtn.innerHTML = Icons.svg("wallet") + "Connect Wallet";
        var idleBadge = $("network-badge");
        setText(idleBadge, "Not connected");
        idleBadge.className = tagClass("muted");
        return;
      }

      show(connectBtn, false);
      show(chip, true);

      setText($("account-address"), shortAddress(state.account));

      var profile = state.profile;
      var registered = profile && profile.isRegistered;

      setText($("account-name"), registered ? profile.name : "Unregistered");
      setText($("account-role"), registered ? C.labelForRole(profile.role) : "No role");

      var repBadge = $("account-reputation");
      var isFreelancer = registered && profile.role === C.Role.Freelancer;
      show(repBadge, isFreelancer);
      if (isFreelancer) {
        var blocked = profile.reputation < 40;
        // A Lucide star, not a glyph. There are no emoji in this application.
        repBadge.innerHTML = Icons.svg("star") + esc(String(profile.reputation));
        repBadge.title = blocked
          ? "Below the bidding threshold of 40. You cannot place new bids."
          : "Reputation " + profile.reputation + ". Bidding requires at least 40.";
        repBadge.className = tagClass(blocked ? "danger" : "ok");
      }

      var avatar = $("account-avatar");
      if (registered && profile.avatarCid) {
        avatar.src = Ipfs.gatewayUrl(profile.avatarCid);
        avatar.alt = profile.name + " avatar";
      } else {
        avatar.removeAttribute("src");
        avatar.alt = "";
      }

      var badge = $("network-badge");
      if (isCorrectChain()) {
        badge.innerHTML = Icons.svg("network") + "Anvil 31337";
        badge.className = tagClass("ok");
      } else {
        badge.innerHTML = Icons.svg("triangle-alert") + "Chain " + esc(String(state.chainId));
        badge.className = tagClass("danger");
      }
    },

    banners: function () {
      show($("banner-no-wallet"), !Wallet.isAvailable());
      var wrongChain = !!state.account && !isCorrectChain();
      show($("banner-wrong-network"), wrongChain);
      if (wrongChain) setText($("current-chain-id"), String(state.chainId));
      show($("banner-no-contract"), !state.contractAddress);
    },

    deploymentInfo: function () {
      setText($("info-address"), state.contractAddress ? shortAddress(state.contractAddress) : "—");
      var addressNode = $("info-address");
      if (addressNode) addressNode.title = state.contractAddress || "";
      setText($("info-chain"), state.chainId ? String(state.chainId) : "—");
      setText($("info-arbiter"), state.arbiterAddress ? shortAddress(state.arbiterAddress) : "—");
    },

    /** Unclaimed earnings tracker (spec 3.4). */
    earnings: function () {
      var card = $("earnings-card");
      var registered = state.profile && state.profile.isRegistered;
      var hasBalance = state.withdrawable > 0n;

      // Freelancers and the Arbiter always see the tracker. Clients see it only
      // when they are actually owed something (a deferred escrow refund).
      var relevant =
        registered &&
        (state.profile.role === C.Role.Freelancer || state.profile.role === C.Role.Arbiter || hasBalance);

      show(card, !!relevant);
      if (!relevant) return;

      setText($("earnings-amount"), formatEthLabel(state.withdrawable));

      var note = $("earnings-note");
      if (state.profile.role === C.Role.Arbiter) {
        setText(note, "Protocol fees collected from resolved bounties (2% of each escrow).");
      } else if (state.profile.role === C.Role.Client) {
        setText(note, "A refund could not be pushed to your wallet, so it is waiting here.");
      } else {
        setText(note, "Approved work is credited here. Withdraw whenever you like (pull payment).");
      }

      var button = $("btn-claim");
      button.disabled = !hasBalance;
      button.innerHTML =
        Icons.svg("hand-coins") +
        (hasBalance ? "Claim " + esc(formatEthLabel(state.withdrawable)) : "Nothing to claim");
    },

    clientPanel: function () {
      var mine = state.bounties.filter(function (b) {
        return sameAddress(b.client, state.account);
      });
      var ordered = Feed.sort(mine, "newest");

      setText($("client-bounty-count"), String(mine.length));
      renderList($("client-bounties"), ordered, "You have not posted any bounties yet.", function (b) {
        return bountyCard(b, "client");
      });
    },

    freelancerPanel: function () {
      var awarded = state.bounties.filter(function (b) {
        return sameAddress(b.freelancer, state.account);
      });
      setText($("freelancer-awarded-count"), String(awarded.length));
      renderList($("freelancer-awarded"), Feed.sort(awarded, "newest"), "No awarded work yet. Bid on something below.", function (b) {
        return bountyCard(b, "freelancer-awarded");
      });

      var feed = Feed.apply(state.bounties);
      setText($("feed-count"), String(feed.length));
      renderList($("feed"), feed, "No bounties match these filters.", function (b) {
        return bountyCard(b, "freelancer-feed");
      });
    },

    arbiterPanel: function () {
      var disputed = state.bounties.filter(function (b) {
        return b.status === C.BountyStatus.Disputed;
      });
      setText($("dispute-count"), String(disputed.length));
      renderList($("arbiter-disputes"), disputed, "No open disputes. Nothing needs your verdict.", function (b) {
        return bountyCard(b, "arbiter");
      });

      var all = Feed.sort(state.bounties, "newest");
      setText($("arbiter-bounty-count"), String(all.length));
      renderList($("arbiter-bounties"), all, "No bounties have been posted yet.", function (b) {
        return bountyCard(b, "observer");
      });

      this.arbiterStats();
    },

    arbiterStats: function () {
      var escrowed = 0n;
      var settled = 0;
      var open = 0;

      state.bounties.forEach(function (b) {
        if (b.status === C.BountyStatus.Locked || b.status === C.BountyStatus.Submitted || b.status === C.BountyStatus.Disputed) {
          escrowed += b.escrowAmount;
        }
        if (b.status === C.BountyStatus.Resolved || b.status === C.BountyStatus.Refunded) settled += 1;
        if (b.status === C.BountyStatus.Open) open += 1;
      });

      var host = $("arbiter-stats");
      if (!host) return;

      // A table, not a grid of tiles: these are five figures in one column and
      // that is exactly what a table is for. Figures set tabular so the decimal
      // points line up down the column.
      host.innerHTML =
        '<table class="table"><caption>Platform totals</caption><tbody>' +
        [
          statRow("Bounties", String(state.bounties.length)),
          statRow("Open", String(open)),
          statRow("In escrow", formatEthLabel(escrowed)),
          statRow("Settled", String(settled)),
          statRow("Unclaimed fees", formatEthLabel(state.withdrawable))
        ].join("") +
        "</tbody></table>";
    }
  };

  function statRow(label, value) {
    return "<tr><th scope=\"row\">" + esc(label) + '</th><td class="num">' + esc(value) + "</td></tr>";
  }

  function renderList(host, items, emptyMessage, renderer) {
    if (!host) return;
    if (!items.length) {
      host.innerHTML = '<div class="empty">' + esc(emptyMessage) + "</div>";
      return;
    }
    host.innerHTML = items.map(renderer).join("");
  }

  function isCorrectChain() {
    return state.chainId === C.EXPECTED_CHAIN_ID;
  }

  /* ----------------------------------------------------------------------
     Bounty card
     ---------------------------------------------------------------------- */

  function bountyCard(bounty, mode) {
    var meta = state.metadata[bounty.detailsCid] || {};
    var title = meta.title || "Bounty #" + bounty.id;
    var description = meta.description || "Loading brief from IPFS...";
    var tone = C.toneForStatus(bounty.status);
    var flash = state.flashIds[bounty.id] ? " is-flashing" : "";

    // The card kicker carries the reference number and the date, set tabular,
    // the way a running head carries a folio.
    return (
      '<article class="card' + flash + '" data-bounty-id="' + bounty.id + '">' +
      '<div class="card-head">' +
      "<div>" +
      '<p class="card-kicker">#' + bounty.id + " &middot; posted " + esc(timeAgo(bounty.createdAt)) + "</p>" +
      '<h3 class="card-title js-title">' + esc(title) + "</h3>" +
      "</div>" +
      '<span class="' + tagClass(tone) + '" title="' + esc(C.hintForStatus(bounty.status)) + '">' +
      esc(C.labelForStatus(bounty.status)) +
      "</span>" +
      "</div>" +
      '<p class="card-body js-desc">' + esc(description) + "</p>" +
      bountyMeta(bounty) +
      bountyLinks(bounty) +
      bidsSection(bounty, mode) +
      actionsFor(bounty, mode) +
      "</article>"
    );
  }

  function bountyMeta(bounty) {
    var bids = state.bidsByBounty[bounty.id] || [];
    var cells = [
      metaCell("Max budget", formatEthLabel(bounty.maxBudget)),
      metaCell("Bids", String(bids.length)),
      metaCell("Client", shortAddress(bounty.client))
    ];
    if (bounty.escrowAmount > 0n) cells.push(metaCell("In escrow", formatEthLabel(bounty.escrowAmount)));
    if (bounty.freelancer && !/^0x0{40}$/i.test(bounty.freelancer)) {
      cells.push(metaCell("Awarded to", shortAddress(bounty.freelancer)));
    }
    if (bounty.status === C.BountyStatus.Resolved || bounty.status === C.BountyStatus.Refunded) {
      cells.push(metaCell("Settled", timeAgo(bounty.updatedAt)));
    }
    return '<div class="card-meta">' + cells.join("") + "</div>";
  }

  function metaCell(key, value) {
    return '<div><span class="k">' + esc(key) + '</span><span class="v">' + esc(value) + "</span></div>";
  }

  function bountyLinks(bounty) {
    var links = [];
    if (bounty.detailsCid) {
      links.push(gatewayLink("file-text", "Brief", bounty.detailsCid));
    }
    if (bounty.workCid) {
      links.push(gatewayLink("hard-drive-upload", "Delivered work", bounty.workCid));
    }
    if (!links.length) return "";
    return '<div class="card-actions">' + links.join("") + "</div>";
  }

  function gatewayLink(icon, label, cid) {
    return (
      '<a class="btn btn-ghost btn-sm" target="_blank" rel="noopener noreferrer" href="' +
      esc(Ipfs.gatewayUrl(cid)) +
      '">' +
      Icons.svg(icon) +
      esc(label) +
      " &middot; " +
      esc(Ipfs.shortCid(cid)) +
      Icons.svg("external-link") +
      "</a>"
    );
  }

  function bidsSection(bounty, mode) {
    var bids = state.bidsByBounty[bounty.id] || [];
    if (!bids.length) return "";
    if (mode === "freelancer-feed" && bounty.status !== C.BountyStatus.Open) return "";

    // Cheapest first: that is the order a client actually reads them in.
    // Another off-chain sort that would be pointless to pay gas for.
    var ordered = bids.slice().sort(function (a, b) {
      return compareBigInt(a.amount, b.amount);
    });

    var isOwner = sameAddress(bounty.client, state.account);
    var canFund = isOwner && bounty.status === C.BountyStatus.Open;

    var rows = ordered.map(function (bid) {
      var winner = sameAddress(bid.freelancer, bounty.freelancer);
      var mine = sameAddress(bid.freelancer, state.account);

      var fundControl = canFund
        ? '<form class="inline-form js-fund" data-bounty-id="' + bounty.id +
          '" data-freelancer="' + esc(bid.freelancer) +
          '" data-amount="' + bid.amount.toString() + '">' +
          '<input class="input" type="text" inputmode="decimal" value="' + esc(formatEth(bid.amount)) +
          '" aria-label="ETH to send" title="Exact bid is pre-filled. Send more and the excess is refunded in the same transaction; send less and it reverts." />' +
          '<button class="btn btn-primary btn-sm" type="submit">' + Icons.svg("lock") + "Fund escrow</button>" +
          "</form>"
        : "";

      return (
        "<tr" + (winner ? ' class="row-marked"' : "") + ">" +
        "<td>" +
        '<span class="address">' + esc(shortAddress(bid.freelancer)) + "</span>" +
        (mine ? ' <span class="tag tag-neutral">you</span>' : "") +
        (winner ? ' <span class="tag tag-accent">awarded</span>' : "") +
        "</td>" +
        '<td class="num">' + esc(formatEthLabel(bid.amount)) + "</td>" +
        (canFund ? "<td>" + fundControl + "</td>" : "") +
        "</tr>"
      );
    });

    return (
      '<table class="table">' +
      "<caption>Quotes (" + bids.length + ")</caption>" +
      "<thead><tr><th scope=\"col\">Freelancer</th><th scope=\"col\" class=\"num\">Quote</th>" +
      (canFund ? '<th scope="col">Accept</th>' : "") +
      "</tr></thead>" +
      "<tbody>" + rows.join("") + "</tbody></table>"
    );
  }

  function actionsFor(bounty, mode) {
    var buttons = [];
    var isOwner = sameAddress(bounty.client, state.account);
    var isAwarded = sameAddress(bounty.freelancer, state.account);
    var isArbiter = sameAddress(state.account, state.arbiterAddress);

    if (mode === "client" && isOwner) {
      if (bounty.status === C.BountyStatus.Submitted) {
        buttons.push(button("js-approve", "btn-primary", "circle-check", "Approve and release 98%", bounty.id));
        buttons.push(button("js-dispute", "btn-secondary", "gavel", "Dispute", bounty.id));
      } else if (bounty.status === C.BountyStatus.Locked) {
        buttons.push(button("js-dispute", "btn-secondary", "gavel", "Raise dispute", bounty.id));
      }
    }

    if (mode === "freelancer-awarded" && isAwarded && bounty.status === C.BountyStatus.Locked) {
      buttons.push(
        '<form class="inline-form js-submit-work" data-bounty-id="' + bounty.id + '">' +
          '<input class="input" type="file" required aria-label="Deliverable file" />' +
          '<button class="btn btn-primary btn-sm" type="submit">' +
          Icons.svg("upload") +
          "Pin and submit work</button>" +
          "</form>"
      );
    }

    if (mode === "freelancer-feed" && bounty.status === C.BountyStatus.Open) {
      var bids = state.bidsByBounty[bounty.id] || [];
      var alreadyBid = bids.some(function (bid) {
        return sameAddress(bid.freelancer, state.account);
      });
      var blocked = state.profile && state.profile.reputation < 40;

      if (alreadyBid) {
        buttons.push('<span class="' + tagClass("info") + '">Your quote is in</span>');
      } else if (blocked) {
        buttons.push('<span class="' + tagClass("danger") + '">Reputation below 40, bidding locked</span>');
      } else {
        buttons.push(
          '<form class="inline-form js-bid" data-bounty-id="' + bounty.id + '" data-max="' + bounty.maxBudget.toString() + '">' +
            '<input class="input" type="text" inputmode="decimal" required placeholder="Your quote in ETH" aria-label="Quote in ETH" />' +
            '<button class="btn btn-primary btn-sm" type="submit">' +
            Icons.svg("send") +
            "Submit quote</button>" +
            "</form>"
        );
      }
    }

    if (mode === "arbiter" && isArbiter && bounty.status === C.BountyStatus.Disputed) {
      buttons.push(
        button("js-resolve-freelancer-fault", "btn-secondary", "scale", "Freelancer at fault, refund client", bounty.id)
      );
      buttons.push(
        button("js-resolve-client-fault", "btn-primary", "scale", "Client at fault, pay freelancer", bounty.id)
      );
    }

    if (!buttons.length) return "";
    return '<div class="card-actions">' + buttons.join("") + "</div>";
  }

  function button(hookClass, variant, icon, label, bountyId) {
    return (
      '<button class="btn btn-sm ' + variant + " " + hookClass + '" data-bounty-id="' + bountyId + '">' +
      Icons.svg(icon) +
      esc(label) +
      "</button>"
    );
  }

  /* ----------------------------------------------------------------------
     Progressive IPFS hydration
     ----------------------------------------------------------------------
     Cards render instantly from chain data; briefs arrive from the gateway
     afterwards and are patched into the existing DOM. A slow or unreachable
     gateway therefore degrades to "no title", never to "no feed".
     ---------------------------------------------------------------------- */

  async function hydrateMetadata() {
    var cids = [];
    state.bounties.forEach(function (b) {
      if (b.detailsCid && state.metadata[b.detailsCid] === undefined && cids.indexOf(b.detailsCid) === -1) {
        cids.push(b.detailsCid);
      }
    });
    if (!cids.length) return;

    var documents = await Promise.all(
      cids.map(function (cid) {
        return Ipfs.fetchJson(cid);
      })
    );

    var changed = false;
    cids.forEach(function (cid, index) {
      var doc = documents[index];
      state.metadata[cid] = doc && typeof doc === "object" ? doc : {};
      if (doc) changed = true;
    });

    if (changed) patchCardText();
  }

  /** Patches titles/descriptions in place — no re-render, no lost focus. */
  function patchCardText() {
    var byId = {};
    state.bounties.forEach(function (b) {
      byId[b.id] = b;
    });

    document.querySelectorAll(".card[data-bounty-id]").forEach(function (card) {
      var bounty = byId[Number(card.getAttribute("data-bounty-id"))];
      if (!bounty) return;
      var meta = state.metadata[bounty.detailsCid];
      if (!meta) return;

      var titleNode = card.querySelector(".js-title");
      var descNode = card.querySelector(".js-desc");
      if (titleNode && meta.title) titleNode.textContent = meta.title;
      if (descNode && meta.description) descNode.textContent = meta.description;
    });
  }

  /* ======================================================================
     Activity log (spec 3.5 — visible proof that events drive the UI)
     ====================================================================== */

  function logActivity(tone, what, detail) {
    var host = $("activity-log");
    if (!host) return;

    var item = document.createElement("li");
    item.className = ruleModifier("activity", tone);
    item.innerHTML =
      '<span class="activity-what">' + esc(what) + "</span>" +
      '<time class="activity-when">' + esc(clockTime()) + "</time>" +
      (detail ? '<span class="activity-detail">' + esc(detail) + "</span>" : "");

    host.insertBefore(item, host.firstChild);
    while (host.children.length > MAX_ACTIVITY_ITEMS) {
      host.removeChild(host.lastChild);
    }
  }

  function flashBounty(bountyId) {
    state.flashIds[bountyId] = true;
    setTimeout(function () {
      delete state.flashIds[bountyId];
    }, 1500);
  }

  /* ======================================================================
     Actions
     ====================================================================== */

  /**
   * Wraps every user intent: correlation id, busy overlay, error translation.
   * Keeping this in one place is why no individual handler needs a try/catch.
   */
  async function runAction(name, busyMessage, fn) {
    Logger.startAction(name);
    Busy.start(busyMessage);
    try {
      var result = await fn();
      Logger.endAction(name, "success");
      return result;
    } catch (error) {
      var explained = C.explainError(error);
      Logger.error("action_failed", {action: name, code: explained.code, detail: explained.detail});
      Logger.endAction(name, "failure");

      if (explained.code === "ACTION_REJECTED") {
        Toast.warn(explained.title, explained.detail);
      } else {
        Toast.error(explained.title, explained.detail);
      }
      return null;
    } finally {
      Busy.stop();
    }
  }

  function requireWriteContract() {
    if (!state.writeContract) {
      throw new Error("Wallet is not connected to the contract yet.");
    }
    if (!isCorrectChain()) {
      throw new Error("Switch MetaMask to chain 31337 first.");
    }
    return state.writeContract;
  }

  /** Sends a transaction and waits for it to be mined, with progress feedback. */
  async function send(label, promise) {
    var tx = await promise;
    Logger.info("tx_sent", {label: label, hash: tx.hash});
    Busy.start("Waiting for confirmation… (" + label + ")");
    try {
      var receipt = await tx.wait();
      Logger.info("tx_mined", {
        label: label,
        hash: tx.hash,
        block: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString()
      });
      return receipt;
    } finally {
      Busy.stop();
    }
  }

  function parseEthOrThrow(value, fieldName) {
    var trimmed = String(value === undefined || value === null ? "" : value).trim();
    if (!trimmed) throw new Error(fieldName + " is required.");
    if (!/^\d*\.?\d+$/.test(trimmed)) throw new Error(fieldName + " must be a plain decimal number of ETH.");
    var wei = state.ethers.parseEther(trimmed);
    if (wei <= 0n) throw new Error(fieldName + " must be greater than zero.");
    return wei;
  }

  var Actions = {
    connect: function () {
      return runAction("connect_wallet", "Opening MetaMask…", async function () {
        if (!Wallet.isAvailable()) {
          Toast.error("No wallet found", "Install MetaMask to use BountyPulse.");
          return;
        }
        var account = await Wallet.requestAccount();
        await onAccountChanged(account);
        Toast.ok("Wallet connected", shortAddress(account));
      });
    },

    switchNetwork: function () {
      return runAction("switch_network", "Switching network…", async function () {
        await Wallet.switchToLocalChain();
        // chainChanged fires and re-initialises; nothing else to do here.
      });
    },

    register: function (form) {
      return runAction("register_user", "Pinning avatar to IPFS…", async function () {
        var name = $("reg-name").value.trim();
        var role = Number(form.querySelector('input[name="reg-role"]:checked').value);
        var file = $("reg-avatar").files[0];

        if (!name) throw new Error("A display name is required.");
        if (!file) throw new Error("Choose an avatar image.");

        // ---- Step 1: pin to IPFS, receive the CID -------------------------
        var upload = await Ipfs.uploadFile(file, "avatar-" + name);
        Toast.info("Avatar pinned", upload.cid);
        showAvatarPreview(upload);

        // ---- Step 2: write only the CID on-chain --------------------------
        Busy.start("Confirm the registration in MetaMask…");
        try {
          await send("registerUser", requireWriteContract().registerUser(name, role, upload.cid));
        } finally {
          Busy.stop();
        }

        Toast.ok("Registered", name + " · " + C.labelForRole(role));
        form.reset();
        show($("reg-avatar-preview"), false);
        await refreshAndRender();
      });
    },

    postBounty: function (form) {
      return runAction("post_bounty", "Pinning the brief to IPFS…", async function () {
        var title = $("bounty-title").value.trim();
        var description = $("bounty-description").value.trim();
        var budgetWei = parseEthOrThrow($("bounty-budget").value, "Max budget");
        var attachment = $("bounty-attachment").files[0];

        if (!title) throw new Error("A title is required.");
        if (!description) throw new Error("A description is required.");

        var attachmentCid = null;
        if (attachment) {
          var uploaded = await Ipfs.uploadFile(attachment, "attachment-" + title);
          attachmentCid = uploaded.cid;
        }

        // Step 1: the whole brief becomes one JSON document on IPFS.
        var pinned = await Ipfs.uploadJson(
          {
            schema: "bountypulse/bounty@1",
            title: title,
            description: description,
            attachmentCid: attachmentCid,
            maxBudgetWei: budgetWei.toString(),
            createdAt: new Date().toISOString()
          },
          "bounty-" + title
        );
        Toast.info("Brief pinned", pinned.cid);

        // Step 2: only the CID and the budget go on-chain.
        Busy.start("Confirm the bounty in MetaMask…");
        try {
          await send("postBounty", requireWriteContract().postBounty(budgetWei, pinned.cid));
        } finally {
          Busy.stop();
        }

        Toast.ok("Bounty posted", title);
        form.reset();
        await refreshAndRender();
      });
    },

    placeBid: function (form) {
      return runAction("place_bid", "Submitting your quote…", async function () {
        var bountyId = Number(form.getAttribute("data-bounty-id"));
        var maxBudget = BigInt(form.getAttribute("data-max"));
        var amountWei = parseEthOrThrow(form.querySelector("input").value, "Quote");

        // Fail fast in the browser rather than paying gas to be told no. The
        // contract enforces this too — this check is UX, not security.
        if (amountWei > maxBudget) {
          throw new Error("Your quote exceeds the client's maximum budget of " + formatEthLabel(maxBudget) + ".");
        }

        await send("placeBid", requireWriteContract().placeBid(bountyId, amountWei));
        Toast.ok("Quote submitted", formatEthLabel(amountWei) + " on bounty #" + bountyId);
        await refreshAndRender();
      });
    },

    fundEscrow: function (form) {
      return runAction("fund_escrow", "Locking ETH into escrow…", async function () {
        var bountyId = Number(form.getAttribute("data-bounty-id"));
        var freelancer = form.getAttribute("data-freelancer");
        var bidWei = BigInt(form.getAttribute("data-amount"));
        var sendWei = parseEthOrThrow(form.querySelector("input").value, "Amount to send");

        if (sendWei < bidWei) {
          // The contract reverts on underpayment; warn before spending gas.
          throw new Error(
            "Underpayment: the bid is " + formatEthLabel(bidWei) + ". Sending less reverts the whole transaction."
          );
        }
        if (sendWei > bidWei) {
          Toast.info(
            "Overpaying by " + formatEthLabel(sendWei - bidWei),
            "The contract keeps the exact bid and refunds the excess in the same transaction."
          );
        }

        await send("fundEscrow", requireWriteContract().fundEscrow(bountyId, freelancer, {value: sendWei}));
        Toast.ok("Escrow funded", formatEthLabel(bidWei) + " locked on bounty #" + bountyId);
        await refreshAndRender();
      });
    },

    submitWork: function (form) {
      return runAction("submit_work", "Pinning the deliverable to IPFS…", async function () {
        var bountyId = Number(form.getAttribute("data-bounty-id"));
        var file = form.querySelector('input[type="file"]').files[0];
        if (!file) throw new Error("Choose the file you are delivering.");

        var upload = await Ipfs.uploadFile(file, "work-bounty-" + bountyId);
        Toast.info("Work pinned", upload.cid);

        Busy.start("Confirm the submission in MetaMask…");
        try {
          await send("submitWork", requireWriteContract().submitWork(bountyId, upload.cid));
        } finally {
          Busy.stop();
        }

        Toast.ok("Work submitted", "Bounty #" + bountyId + " is now awaiting review.");
        await refreshAndRender();
      });
    },

    approveWork: function (bountyId) {
      return runAction("approve_work", "Releasing escrow…", async function () {
        await send("approveWork", requireWriteContract().approveWork(bountyId));
        Toast.ok("Work approved", "98% credited to the freelancer, 2% to the Arbiter.");
        await refreshAndRender();
      });
    },

    raiseDispute: function (bountyId) {
      return runAction("raise_dispute", "Escalating to the Arbiter…", async function () {
        await send("raiseDispute", requireWriteContract().raiseDispute(bountyId));
        Toast.warn("Dispute raised", "The Arbiter will decide the outcome of bounty #" + bountyId + ".");
        await refreshAndRender();
      });
    },

    resolveDispute: function (bountyId, outcome) {
      var label =
        outcome === C.DisputeOutcome.FreelancerFault
          ? "Refunding the client…"
          : "Paying the freelancer…";

      return runAction("resolve_dispute", label, async function () {
        await send("resolveDispute", requireWriteContract().resolveDispute(bountyId, outcome));
        Toast.ok(
          "Dispute resolved",
          outcome === C.DisputeOutcome.FreelancerFault
            ? "Escrow returned to the client; freelancer reputation -30."
            : "Freelancer credited the escrow minus the 2% fee."
        );
        await refreshAndRender();
      });
    },

    claimFunds: function () {
      return runAction("claim_funds", "Withdrawing your balance…", async function () {
        var amount = state.withdrawable;
        if (amount <= 0n) {
          Toast.info("Nothing to claim", "Your withdrawable balance is zero.");
          return;
        }
        await send("claimFunds", requireWriteContract().claimFunds());
        Toast.ok("Funds claimed", formatEthLabel(amount) + " sent to " + shortAddress(state.account));
        await refreshAndRender();
      });
    },

    /**
     * Accepts either credential style. A JWT alone, or an API key + secret
     * pair. Inputs are cleared immediately after saving so the secret is not
     * left sitting in the DOM.
     */
    savePinataCredential: function () {
      var jwtInput = $("pinata-jwt");
      var keyInput = $("pinata-api-key");
      var secretInput = $("pinata-api-secret");

      var jwt = jwtInput.value.trim();
      var apiKey = keyInput ? keyInput.value.trim() : "";
      var apiSecret = secretInput ? secretInput.value.trim() : "";

      try {
        if (jwt) {
          Ipfs.setJwt(jwt);
        } else if (apiKey || apiSecret) {
          Ipfs.setApiKeyPair(apiKey, apiSecret);
        } else {
          throw new Error("Enter a JWT, or both an API key and its secret.");
        }

        jwtInput.value = "";
        if (keyInput) keyInput.value = "";
        if (secretInput) secretInput.value = "";

        renderPinataStatus();
        Toast.ok("Pinata credential saved", "Stored in this browser only. It now overrides .env.");
      } catch (error) {
        renderPinataMessage("attention", error.message);
        Toast.error("Could not save credential", error.message);
      }
    },

    testPinata: function () {
      return runAction("pinata_test", "Checking the Pinata credential…", async function () {
        var result = await Ipfs.testAuthentication();
        renderPinataStatus();
        Toast.ok("Pinata reachable", result.message);
      });
    },

    clearPinataCredential: function () {
      var hadEnv = Ipfs.hasEnvCredential();
      Ipfs.clearCredentials();
      renderPinataStatus();
      Toast.info(
        "Browser credential cleared",
        hadEnv ? "Falling back to the credential from .env." : "Uploads will fail until one is configured."
      );
    }
  };

  /**
   * Renders the credential panel from the CURRENT resolution result rather than
   * from whatever the last action happened to be. One source of truth: after a
   * save, a clear, or a boot, the panel always describes what uploadFile() would
   * genuinely use.
   *
   * Discloses the SOURCE and the character LENGTH only. Never the value — not in
   * the DOM, not in a title attribute, not in a log line.
   */
  function renderPinataStatus() {
    var node = $("pinata-status");
    if (!node) return;

    var info = Ipfs.getCredentialInfo();

    if (!info) {
      node.className = "status status-none";
      node.innerHTML =
        '<span class="tag tag-outline">source: none</span> ' +
        "No credential resolved. Put <code>PINATA_JWT</code> in <code>.env</code> and re-run " +
        "<code>./scripts/serve-frontend.sh</code>, or paste one above. Uploads will fail.";
      Logger.info("pinata_credential_resolved", {source: "none"});
      return;
    }

    var fromEnv = info.source === "env";

    node.className = "status status-ok";
    node.innerHTML =
      '<span class="tag ' + (fromEnv ? "tag-accent" : "tag-accent-2") + '">source: ' + esc(info.source) + "</span> " +
      esc(info.label) + " active, " + info.length + " characters. " +
      (fromEnv
        ? "Bridged from <code>.env</code> by <code>scripts/gen-pinata-config.sh</code>."
        : "Saved in this browser, which overrides <code>.env</code>." +
          (info.envAvailable ? " Clearing it falls back to the <code>.env</code> credential." : ""));

    Logger.info("pinata_credential_resolved", {source: info.source, mode: info.mode, length: info.length});
  }

  /** Transient one-off message (a save error, say) that is not the resolved state. */
  function renderPinataMessage(tone, message) {
    var node = $("pinata-status");
    if (!node) return;
    node.className = "status status-" + tone;
    node.textContent = message;
  }

  function showAvatarPreview(upload) {
    var box = $("reg-avatar-preview");
    if (!box) return;
    box.querySelector("img").src = upload.url;
    box.querySelector("code").textContent = upload.cid;
    show(box, true);
  }

  /* ======================================================================
     EventSync — the contract drives the UI (spec 3.5)
     ====================================================================== */

  var EventSync = {
    /**
     * Every state-changing function on the contract emits an event, so a single
     * table maps event name -> how it should surface. `refresh: true` means the
     * DApp pulls fresh state; the re-render then happens once, debounced.
     */
    HANDLERS: {
      UserRegistered: function (args) {
        return {tone: "info", what: "User registered", detail: args[2] + " · " + C.labelForRole(args[1])};
      },
      BountyPosted: function (args) {
        return {
          tone: "info",
          what: "Bounty #" + args[0] + " posted",
          detail: "budget " + formatEthLabel(args[2]),
          bountyId: Number(args[0])
        };
      },
      BidPlaced: function (args) {
        return {
          tone: "info",
          what: "New quote on #" + args[0],
          detail: shortAddress(args[1]) + " · " + formatEthLabel(args[2]),
          bountyId: Number(args[0])
        };
      },
      EscrowFunded: function (args) {
        return {
          tone: "ok",
          what: "Escrow funded on #" + args[0],
          detail:
            formatEthLabel(args[3]) +
            " locked" +
            (args[4] > 0n ? " · " + formatEthLabel(args[4]) + " refunded to the client" : ""),
          bountyId: Number(args[0])
        };
      },
      WorkSubmitted: function (args) {
        return {
          tone: "info",
          what: "Work delivered on #" + args[0],
          detail: Ipfs.shortCid(args[2]),
          bountyId: Number(args[0])
        };
      },
      WorkApproved: function (args) {
        return {
          tone: "ok",
          what: "Work approved on #" + args[0],
          detail: formatEthLabel(args[3]) + " to the freelancer · " + formatEthLabel(args[4]) + " fee",
          bountyId: Number(args[0])
        };
      },
      DisputeRaised: function (args) {
        return {tone: "warn", what: "Dispute raised on #" + args[0], detail: "awaiting the Arbiter", bountyId: Number(args[0])};
      },
      DisputeResolved: function (args) {
        var freelancerFault = Number(args[2]) === C.DisputeOutcome.FreelancerFault;
        return {
          tone: freelancerFault ? "danger" : "ok",
          what: "Dispute resolved on #" + args[0],
          detail: freelancerFault
            ? formatEthLabel(args[3]) + " refunded to the client"
            : formatEthLabel(args[4]) + " credited to the freelancer",
          bountyId: Number(args[0])
        };
      },
      BountyStatusChanged: function (args) {
        return {
          tone: "info",
          what: "Bounty #" + args[0] + " → " + C.labelForStatus(args[2]),
          detail: C.labelForStatus(args[1]) + " → " + C.labelForStatus(args[2]),
          bountyId: Number(args[0]),
          quiet: true
        };
      },
      ReputationChanged: function (args) {
        var delta = Number(args[3]);
        return {
          tone: delta >= 0 ? "ok" : "danger",
          what: "Reputation " + (delta >= 0 ? "+" : "") + delta,
          detail: shortAddress(args[0]) + " · " + args[1] + " → " + args[2]
        };
      },
      BalanceCredited: function (args) {
        return {
          tone: "ok",
          what: "Balance credited",
          detail: shortAddress(args[0]) + " · +" + formatEthLabel(args[1]),
          highlightAccount: args[0]
        };
      },
      FundsClaimed: function (args) {
        return {tone: "ok", what: "Funds claimed", detail: shortAddress(args[0]) + " · " + formatEthLabel(args[1])};
      },
      DirectRefund: function (args) {
        return {tone: "ok", what: "Refund sent", detail: shortAddress(args[0]) + " · " + formatEthLabel(args[1])};
      },
      RefundDeferred: function (args) {
        return {
          tone: "warn",
          what: "Refund deferred to a claimable balance",
          detail: shortAddress(args[0]) + " · " + formatEthLabel(args[1])
        };
      }
    },

    attach: function () {
      this.detach();
      if (!state.readContract) return;

      var self = this;
      Object.keys(this.HANDLERS).forEach(function (eventName) {
        var listener = function () {
          // ethers v6 passes the ContractEventPayload as the final argument.
          var args = Array.prototype.slice.call(arguments, 0, arguments.length - 1);
          self.onEvent(eventName, args);
        };
        // `on` is async in ethers v6: an unhandled rejection here would be
        // invisible, so the failure is logged rather than swallowed.
        Promise.resolve(state.readContract.on(eventName, listener)).catch(function (err) {
          Logger.error("listener_attach_failed", {event: eventName, reason: err.message});
        });
        state.listeners.push({target: state.readContract, event: eventName, listener: listener});
      });

      if (state.readProvider) {
        var blockListener = function (blockNumber) {
          var badge = $("block-badge");
          if (badge) {
            setText(badge, "#" + blockNumber);
            show(badge, true);
          }
        };
        state.readProvider.on("block", blockListener);
        state.listeners.push({target: state.readProvider, event: "block", listener: blockListener});
      }

      var indicator = $("event-indicator");
      if (indicator) indicator.className = "pulse pulse-live";

      Logger.info("event_listeners_attached", {count: state.listeners.length});
      logActivity("info", "Live sync active", "Listening for contract events");
    },

    /**
     * Teardown matters. Every re-connect (account switch, network switch,
     * redeploy) builds new contract objects; without removing the old
     * listeners they keep polling forever and every event fires N times.
     */
    detach: function () {
      state.listeners.forEach(function (entry) {
        try {
          Promise.resolve(entry.target.off(entry.event, entry.listener)).catch(function (err) {
            Logger.warn("listener_detach_failed", {event: entry.event, reason: err.message});
          });
        } catch (err) {
          Logger.warn("listener_detach_failed", {event: entry.event, reason: err.message});
        }
      });
      state.listeners = [];

      var indicator = $("event-indicator");
      if (indicator) indicator.className = "pulse";
    },

    onEvent: function (eventName, args) {
      var describe = this.HANDLERS[eventName];
      if (!describe) return;

      var info;
      try {
        info = describe(args);
      } catch (err) {
        Logger.warn("event_describe_failed", {event: eventName, reason: err.message});
        return;
      }

      Logger.info("contract_event", {event: eventName, detail: info.detail});

      if (!info.quiet) logActivity(info.tone, info.what, info.detail);
      if (info.bountyId) flashBounty(info.bountyId);

      // The headline moment for checkpoint 5: window 1 approves, window 2's
      // "Unclaimed Earnings" moves without anyone touching window 2.
      if (info.highlightAccount && sameAddress(info.highlightAccount, state.account)) {
        Toast.ok("Earnings updated", "Your unclaimed balance just changed.");
      }

      scheduleRefresh();
    }
  };

  /** Debounced refresh: one transaction emits several events; render once. */
  function scheduleRefresh() {
    if (state.refreshTimer) clearTimeout(state.refreshTimer);
    state.refreshTimer = setTimeout(function () {
      state.refreshTimer = null;
      refreshAndRender().catch(function (err) {
        Logger.error("refresh_failed", {reason: err.message});
      });
    }, REFRESH_DEBOUNCE_MS);
  }

  async function refreshAndRender() {
    await Chain.refreshAll();
    Render.all();
    hydrateMetadata().catch(function (err) {
      Logger.warn("metadata_hydration_failed", {reason: err.message});
    });
  }

  /* ======================================================================
     Lifecycle
     ====================================================================== */

  async function onAccountChanged(account) {
    Logger.info("account_changed", {account: account});
    EventSync.detach();

    state.account = account || null;
    state.profile = null;
    state.withdrawable = 0n;

    if (!state.account) {
      state.signer = null;
      state.writeContract = null;
      Render.all();
      logActivity("warn", "Wallet disconnected", "Connect an account to continue");
      return;
    }

    state.chainId = await Wallet.getChainId();
    state.browserProvider = new state.ethers.BrowserProvider(global.ethereum);
    state.signer = await state.browserProvider.getSigner();

    var ready = await Chain.connectContracts();
    if (ready) {
      await refreshAndRender();
      EventSync.attach();
    } else {
      Render.all();
    }
  }

  async function onChainChanged() {
    // MetaMask's own guidance is to reload here. The specification forbids it,
    // and a reload is unnecessary: rebuilding the provider, signer, contracts
    // and listeners achieves the same thing without losing form state.
    Logger.info("chain_changed", {});
    var account = await Wallet.detectAccount();
    await onAccountChanged(account);
    if (isCorrectChain()) {
      Toast.ok("Network switched", "Connected to Anvil (31337).");
    } else {
      Toast.warn("Wrong network", "BountyPulse needs chain 31337.");
    }
  }

  /* ======================================================================
     Wiring
     ====================================================================== */

  function bindStaticHandlers() {
    on($("btn-connect"), "click", function () {
      Actions.connect();
    });
    on($("btn-connect-hero"), "click", function () {
      Actions.connect();
    });
    on($("btn-switch-network"), "click", function () {
      Actions.switchNetwork();
    });
    on($("btn-claim"), "click", function () {
      Actions.claimFunds();
    });

    onSubmit($("form-register"), function (form) {
      Actions.register(form);
    });
    onSubmit($("form-post-bounty"), function (form) {
      Actions.postBounty(form);
    });

    onSubmit($("form-pinata"), function () {
      Actions.savePinataCredential();
    });
    on($("btn-test-pinata"), "click", function () {
      Actions.testPinata();
    });
    on($("btn-clear-pinata"), "click", function () {
      Actions.clearPinataCredential();
    });

    onSubmit($("form-address"), function () {
      var value = $("input-contract-address").value.trim();
      try {
        C.setAddressOverride(value);
        Toast.ok("Address saved", shortAddress(value));
        reconnectContracts();
      } catch (error) {
        Toast.error("Invalid address", error.message);
      }
    });

    // Off-chain feed controls. Each one re-renders from memory; no RPC, no gas.
    ["feed-sort", "feed-status"].forEach(function (id) {
      on($(id), "change", function (event) {
        state.feed[id === "feed-sort" ? "sort" : "status"] = event.target.value;
        Logger.debug("feed_control_changed", {control: id, value: event.target.value});
        Render.all();
        patchCardText();
      });
    });

    var search = $("feed-search");
    if (search) {
      var debounce = null;
      search.addEventListener("input", function (event) {
        var value = event.target.value;
        if (debounce) clearTimeout(debounce);
        debounce = setTimeout(function () {
          state.feed.search = value;
          Render.all();
          patchCardText();
        }, 180);
      });
    }

    var avatarInput = $("reg-avatar");
    if (avatarInput) {
      avatarInput.addEventListener("change", function (event) {
        var file = event.target.files[0];
        var box = $("reg-avatar-preview");
        if (!file || !box) return show(box, false);
        box.querySelector("img").src = URL.createObjectURL(file);
        box.querySelector("code").textContent = file.name + " · " + Ipfs.formatBytes(file.size) + " (not pinned yet)";
        show(box, true);
      });
    }

    // Delegated handlers: bounty cards are re-rendered constantly, so binding
    // per-card listeners would leak. One listener on document covers them all.
    document.addEventListener("click", function (event) {
      // event.target can be a non-Element (document, text node) for synthetic
      // clicks; `closest` only exists on Element.
      if (!(event.target instanceof Element)) return;
      var target = event.target.closest("button");
      if (!target) return;
      var bountyId = Number(target.getAttribute("data-bounty-id"));

      if (target.classList.contains("js-approve")) Actions.approveWork(bountyId);
      else if (target.classList.contains("js-dispute")) Actions.raiseDispute(bountyId);
      else if (target.classList.contains("js-resolve-freelancer-fault")) {
        Actions.resolveDispute(bountyId, C.DisputeOutcome.FreelancerFault);
      } else if (target.classList.contains("js-resolve-client-fault")) {
        Actions.resolveDispute(bountyId, C.DisputeOutcome.ClientFault);
      }
    });

    document.addEventListener("submit", function (event) {
      var form = event.target;
      if (form.classList.contains("js-bid")) {
        event.preventDefault();
        Actions.placeBid(form);
      } else if (form.classList.contains("js-fund")) {
        event.preventDefault();
        Actions.fundEscrow(form);
      } else if (form.classList.contains("js-submit-work")) {
        event.preventDefault();
        Actions.submitWork(form);
      }
    });
  }

  /**
   * Injects the icons that belong to static markup rather than to a render pass.
   *
   * Kept in JS rather than pasted into index.html so that every icon NAME in the
   * application is chosen in exactly one file. Runs before anything else in boot
   * so the page is never briefly iconless, and tolerates a missing node so a
   * trimmed-down page cannot break startup.
   */
  function decorateStaticIcons() {
    var STATIC_ICONS = {
      "brand-mark": "activity",
      "btn-connect-hero": "wallet",
      "btn-switch-network": "network",
      "btn-test-pinata": "shield-check"
    };

    Object.keys(STATIC_ICONS).forEach(function (id) {
      var node = $(id);
      if (node) node.insertAdjacentHTML("afterbegin", Icons.svg(STATIC_ICONS[id]));
    });
  }

  function on(node, type, handler) {
    if (node) node.addEventListener(type, handler);
  }

  function onSubmit(form, handler) {
    if (!form) return;
    form.addEventListener("submit", function (event) {
      event.preventDefault();
      handler(form);
    });
  }

  async function reconnectContracts() {
    EventSync.detach();
    var ready = await Chain.connectContracts();
    if (ready) {
      await refreshAndRender();
      EventSync.attach();
    } else {
      Render.all();
    }
  }

  function bindWalletEvents() {
    if (!Wallet.isAvailable()) return;

    // Spec 3.1: the UI must follow the wallet instantly, with no reload.
    global.ethereum.on("accountsChanged", function (accounts) {
      onAccountChanged(accounts && accounts.length ? accounts[0] : null).catch(function (err) {
        Logger.error("account_change_failed", {reason: err.message});
        Toast.error("Could not switch account", err.message);
      });
    });

    global.ethereum.on("chainChanged", function () {
      onChainChanged().catch(function (err) {
        Logger.error("chain_change_failed", {reason: err.message});
      });
    });
  }

  /* ======================================================================
     Boot
     ====================================================================== */

  async function boot() {
    Logger.info("boot_started", {
      href: location.href,
      hasDeploymentFile: !!C.getDeployment()
    });

    decorateStaticIcons();
    bindStaticHandlers();
    renderPinataStatus();

    if (!Wallet.isAvailable()) {
      show($("banner-no-wallet"), true);
      Logger.warn("no_wallet_detected", {});
      return;
    }

    try {
      state.ethers = await ensureEthers();
    } catch (error) {
      Logger.error("ethers_load_failed", {reason: error.message});
      Toast.error("Could not load ethers.js", "Run 'npm install' for an offline copy, or check your connection.");
      return;
    }

    bindWalletEvents();

    if (!C.getAddress()) {
      Logger.warn("no_contract_address", {});
      show($("banner-no-contract"), true);
    }

    // Auto-detect the active account WITHOUT prompting (spec 3.1).
    var account = await Wallet.detectAccount();
    if (account) {
      Logger.info("account_auto_detected", {account: account});
      await onAccountChanged(account);
    } else {
      state.chainId = await Wallet.getChainId();
      Render.all();
      Logger.info("no_authorised_account", {});
    }

    Logger.info("boot_complete", {
      account: state.account,
      chainId: state.chainId,
      contract: state.contractAddress
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      boot().catch(function (err) {
        Logger.error("boot_failed", {reason: err.message, stack: err.stack});
        Toast.error("Startup failed", err.message);
      });
    });
  } else {
    boot().catch(function (err) {
      Logger.error("boot_failed", {reason: err.message, stack: err.stack});
      Toast.error("Startup failed", err.message);
    });
  }
})(window);
