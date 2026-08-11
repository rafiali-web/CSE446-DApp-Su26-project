/* ==========================================================================
   ipfsHelper.js — the two-step IPFS pipeline (spec 3.3)
   --------------------------------------------------------------------------
   THE PIPELINE
     Step 1  browser  --HTTP POST-->  Pinata  ->  returns a CID
     Step 2  browser  --transaction->  contract  ->  stores only that CID

   Heavy bytes never touch the chain. A 2 MB avatar costs one HTTP request and
   ~46 bytes of on-chain string; storing it on-chain would cost millions of gas
   and is not physically sensible.

   CREDENTIAL SOURCES (see resolveCredential below)
     1. localStorage  a value typed into the IPFS / Pinata panel. Always wins,
                      so a developer can override the machine's .env per browser
                      without editing files.
     2. env           window.BOUNTYPULSE_PINATA, generated from the repository
                      .env by scripts/gen-pinata-config.sh. This is what makes a
                      PINATA_JWT on disk actually reach the browser.
     3. none          the UI asks for one and uploads are refused up front.

   The credential is readable client-side whichever source it comes from. To
   move it server-side, point `PINATA_API` at your own proxy and drop the
   Authorization header; every call site below stays identical.

   FAULT TOLERANCE
   Every request has an explicit timeout (a fetch with no timeout can hang
   forever), retries only idempotent failures, and backs off exponentially with
   jitter so a recovering gateway is not stampeded.
   ========================================================================== */

(function (global) {
  "use strict";

  var PINATA_API = "https://api.pinata.cloud";
  var DEFAULT_GATEWAY = "https://gateway.pinata.cloud/ipfs/";

  /* Credential storage keys. Mirrors the names used in .env:
       PINATA_JWT         -> preferred, Bearer token
       PINATA_API_KEY     -> legacy pair, used only when no JWT is present
       PINATA_API_SECRET  */
  var STORAGE_KEY_JWT = "bountypulse.pinataJwt";
  var STORAGE_KEY_API_KEY = "bountypulse.pinataApiKey";
  var STORAGE_KEY_API_SECRET = "bountypulse.pinataApiSecret";

  /** Uploads are large and slow; reads are small and fast. Different budgets. */
  var UPLOAD_TIMEOUT_MS = 60000;
  var REQUEST_TIMEOUT_MS = 15000;

  var MAX_ATTEMPTS = 3;
  var BASE_BACKOFF_MS = 400;

  /** Refuse oversized files in the browser rather than after a 60s upload. */
  var MAX_FILE_BYTES = 25 * 1024 * 1024;

  /** Gateway reads are immutable by definition (content addressing), so cache freely. */
  var contentCache = new Map();

  /* ----------------------------------------------------------------------
     Logging — delegates to the app logger when present so IPFS activity
     appears in the same structured stream as everything else.
     ---------------------------------------------------------------------- */
  function log(level, event, context) {
    if (global.BountyPulseLogger && typeof global.BountyPulseLogger[level] === "function") {
      global.BountyPulseLogger[level](event, context);
      return;
    }
    var fn = console[level] || console.log;
    fn.call(console, "[ipfs] " + event, context || {});
  }

  /* ----------------------------------------------------------------------
     Credential handling
     ----------------------------------------------------------------------
     Pinata accepts two authentication styles and this module supports both,
     behind one interface so no call site has to care which is in use:

       JWT (preferred)  Authorization: Bearer <token>
       Legacy pair      pinata_api_key / pinata_secret_api_key headers

     The JWT always wins when both are stored: it is scopeable and it is one
     secret rather than two.

     Credentials live in localStorage, never in the page source and never in a
     committed file. NOTHING here ever logs a credential value — only its
     presence, length and mode, which is what you actually need when debugging
     a 401 at 2am.
     ---------------------------------------------------------------------- */

  function readStorage(key) {
    try {
      var value = global.localStorage.getItem(key);
      return value && value.trim() ? value.trim() : null;
    } catch (err) {
      return null; // private mode / storage disabled
    }
  }

  function writeStorage(key, value) {
    global.localStorage.setItem(key, value);
  }

  function removeStorage(key) {
    try {
      global.localStorage.removeItem(key);
    } catch (err) {
      /* nothing to do */
    }
  }

  /* ----------------------------------------------------------------------
     Injected configuration (source: "env")
     ----------------------------------------------------------------------
     frontend/js/pinata-config.js is generated from the repository .env by
     scripts/gen-pinata-config.sh and loaded before this file. It is optional:
     the page works without it, it is git-ignored, and it may legitimately be
     absent (nobody ran the script) or present but empty (no credential in
     .env). Every read below tolerates all three shapes.
     ---------------------------------------------------------------------- */

  function injectedConfig() {
    var config = global.BOUNTYPULSE_PINATA;
    return config && typeof config === "object" ? config : null;
  }

  /** Reads one field from the injected config, normalising "" and stray types to null. */
  function readInjected(field) {
    var config = injectedConfig();
    if (!config) return null;
    var value = config[field];
    if (typeof value !== "string") return null;
    value = value.trim();
    return value ? value : null;
  }

  function getJwt() {
    return readStorage(STORAGE_KEY_JWT);
  }

  function setJwt(jwt) {
    var trimmed = (jwt || "").trim();
    if (!trimmed) throw new Error("A Pinata JWT is required.");
    // Cheap sanity check: a JWT is three dot-separated base64url segments.
    if (trimmed.split(".").length !== 3) {
      throw new Error("That does not look like a JWT. Copy the full 'eyJhbGciOi…' token from Pinata.");
    }
    writeStorage(STORAGE_KEY_JWT, trimmed);
    log("info", "pinata_credential_saved", {mode: "jwt", length: trimmed.length});
    return trimmed;
  }

  /** Legacy alternative: the API key / secret pair from .env. */
  function setApiKeyPair(apiKey, apiSecret) {
    var key = (apiKey || "").trim();
    var secret = (apiSecret || "").trim();
    if (!key || !secret) throw new Error("Both the API key and the API secret are required.");

    writeStorage(STORAGE_KEY_API_KEY, key);
    writeStorage(STORAGE_KEY_API_SECRET, secret);
    log("info", "pinata_credential_saved", {mode: "apiKey", keyLength: key.length, secretLength: secret.length});
  }

  /**
   * Resolves the active credential across both sources.
   *
   * PRECEDENCE, highest first:
   *   localStorage JWT  ->  localStorage key+secret  ->  env JWT  ->  env key+secret
   *
   * The whole localStorage layer outranks the whole env layer: typing a value
   * into the panel is an explicit, per-browser override of whatever the machine
   * happens to have in .env, and an override that could be silently beaten by a
   * file is not an override.
   *
   * Within a layer the JWT wins: it is one scopeable secret rather than two.
   *
   * @returns {{mode: "jwt"|"apiKey", source: "localStorage"|"env",
   *            jwt?: string, apiKey?: string, apiSecret?: string}|null}
   */
  function getCredential() {
    var jwt = getJwt();
    if (jwt) return {mode: "jwt", source: "localStorage", jwt: jwt};

    var apiKey = readStorage(STORAGE_KEY_API_KEY);
    var apiSecret = readStorage(STORAGE_KEY_API_SECRET);
    if (apiKey && apiSecret) {
      return {mode: "apiKey", source: "localStorage", apiKey: apiKey, apiSecret: apiSecret};
    }

    var envJwt = readInjected("jwt");
    if (envJwt) return {mode: "jwt", source: "env", jwt: envJwt};

    var envKey = readInjected("apiKey");
    var envSecret = readInjected("apiSecret");
    if (envKey && envSecret) {
      return {mode: "apiKey", source: "env", apiKey: envKey, apiSecret: envSecret};
    }

    return null;
  }

  function requireCredential() {
    var credential = getCredential();
    if (!credential) {
      throw IpfsError(
        "No Pinata credential configured. Set PINATA_JWT in .env and re-run " +
          "./scripts/serve-frontend.sh, or paste a JWT into the IPFS / Pinata panel.",
        "NO_CREDENTIAL"
      );
    }
    return credential;
  }

  /** Builds the auth headers for the active credential. */
  function authHeaders() {
    var credential = requireCredential();
    if (credential.mode === "jwt") {
      return {Authorization: "Bearer " + credential.jwt};
    }
    return {
      pinata_api_key: credential.apiKey,
      pinata_secret_api_key: credential.apiSecret
    };
  }

  function hasCredential() {
    return getCredential() !== null;
  }

  /**
   * Structured, credential-FREE description of what is active.
   *
   * Returns the mode, the source and the character length — never the value.
   * A length is exactly what you need to tell "the JWT is there" from "the JWT
   * got truncated on paste", and it discloses nothing useful to a reader of the
   * page or of the logs.
   *
   * `envAvailable` lets the UI say "clearing this falls back to .env" instead of
   * "uploads will now fail", which is the difference between a helpful panel and
   * a confusing one.
   *
   * @returns {{mode: string, source: string, length: number, label: string,
   *            envAvailable: boolean}|null}
   */
  function getCredentialInfo() {
    var credential = getCredential();
    if (!credential) return null;

    var length =
      credential.mode === "jwt"
        ? credential.jwt.length
        : credential.apiKey.length + credential.apiSecret.length;

    return {
      mode: credential.mode,
      source: credential.source,
      length: length,
      label: credential.mode === "jwt" ? "JWT" : "API key + secret",
      envAvailable: hasEnvCredential()
    };
  }

  /** True when the generated config alone could authenticate. */
  function hasEnvCredential() {
    if (readInjected("jwt")) return true;
    return !!(readInjected("apiKey") && readInjected("apiSecret"));
  }

  /** Human-readable one-liner for the status line. Contains no secret. */
  function describeCredential() {
    var info = getCredentialInfo();
    if (!info) return null;
    return info.label + " from " + info.source + ", " + info.length + " chars";
  }

  /**
   * Clears the localStorage layer only. The injected .env config is a generated
   * FILE — this module has no business trying to delete it, and pretending to
   * would be a lie. After clearing, resolution falls through to `env` if one is
   * present, which the panel reports.
   */
  function clearCredentials() {
    removeStorage(STORAGE_KEY_JWT);
    removeStorage(STORAGE_KEY_API_KEY);
    removeStorage(STORAGE_KEY_API_SECRET);
    log("info", "pinata_credentials_cleared", {scope: "localStorage", envRemains: hasEnvCredential()});
  }

  /* ----------------------------------------------------------------------
     Errors — a typed error carrying enough context to act on, rather than a
     bare string that the UI has to pattern-match.
     ---------------------------------------------------------------------- */
  function IpfsError(message, code, status) {
    var err = new Error(message);
    err.name = "IpfsError";
    err.code = code || "IPFS_ERROR";
    if (status !== undefined) err.status = status;
    return err;
  }

  /* ----------------------------------------------------------------------
     Transport
     ---------------------------------------------------------------------- */

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  /**
   * Full jitter exponential backoff. Without jitter, every client that failed
   * at the same moment retries at the same moment — the thundering herd that
   * keeps a recovering service down.
   */
  function backoffDelay(attempt) {
    var ceiling = BASE_BACKOFF_MS * Math.pow(2, attempt - 1);
    return Math.floor(Math.random() * ceiling);
  }

  /** A 4xx (except 429) means the request itself is wrong; retrying cannot help. */
  function isRetryable(status) {
    if (status === undefined) return true; // network/timeout failure
    if (status === 429) return true; // rate limited
    return status >= 500;
  }

  /**
   * fetch with a hard timeout and bounded retries.
   * @returns {Promise<Response>}
   */
  async function requestWithRetry(url, options, timeoutMs, label) {
    var lastError = null;

    for (var attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      var controller = new AbortController();
      var timer = setTimeout(function () {
        controller.abort();
      }, timeoutMs);

      var startedAt = performance.now();
      try {
        var response = await fetch(url, Object.assign({}, options, {signal: controller.signal}));
        clearTimeout(timer);

        var elapsed = Math.round(performance.now() - startedAt);

        if (response.ok) {
          log("debug", "ipfs_request_ok", {label: label, attempt: attempt, status: response.status, ms: elapsed});
          return response;
        }

        var body = await response.text().catch(function () {
          return "";
        });

        log("warn", "ipfs_request_failed", {
          label: label,
          attempt: attempt,
          status: response.status,
          ms: elapsed,
          body: body.slice(0, 200)
        });

        if (!isRetryable(response.status)) {
          throw IpfsError(describeHttpFailure(response.status, body), "HTTP_" + response.status, response.status);
        }
        lastError = IpfsError(
          describeHttpFailure(response.status, body),
          "HTTP_" + response.status,
          response.status
        );
      } catch (err) {
        clearTimeout(timer);

        if (err && err.name === "IpfsError") throw err; // non-retryable, already classified

        var aborted = err && err.name === "AbortError";
        lastError = IpfsError(
          aborted ? label + " timed out after " + timeoutMs + "ms" : "Network error during " + label + ": " + err.message,
          aborted ? "TIMEOUT" : "NETWORK"
        );
        log("warn", "ipfs_request_error", {label: label, attempt: attempt, code: lastError.code});
      }

      if (attempt < MAX_ATTEMPTS) {
        var delay = backoffDelay(attempt);
        log("debug", "ipfs_retry_scheduled", {label: label, nextAttempt: attempt + 1, delayMs: delay});
        await sleep(delay);
      }
    }

    throw lastError || IpfsError(label + " failed", "UNKNOWN");
  }

  function describeHttpFailure(status, body) {
    if (status === 401 || status === 403) {
      return "Pinata rejected the credential (HTTP " + status + "). The JWT is missing, expired or lacks pinning scope.";
    }
    if (status === 429) {
      return "Pinata rate limit hit (HTTP 429). Wait a moment and try again.";
    }
    if (status >= 500) {
      return "Pinata is having trouble (HTTP " + status + "). Retried and still failing.";
    }
    return "Pinata request failed (HTTP " + status + "): " + String(body || "").slice(0, 160);
  }

  /* ----------------------------------------------------------------------
     Public API — Step 1 of the pipeline (pin, then return a CID)
     ---------------------------------------------------------------------- */

  /**
   * Verifies the stored JWT against Pinata.
   * @returns {Promise<{ok: boolean, message: string}>}
   */
  async function testAuthentication() {
    var mode = requireCredential().mode;
    var response = await requestWithRetry(
      PINATA_API + "/data/testAuthentication",
      {method: "GET", headers: authHeaders()},
      REQUEST_TIMEOUT_MS,
      "auth check"
    );
    var data = await response.json();
    log("info", "pinata_auth_ok", {mode: mode, message: data.message});
    return {ok: true, mode: mode, message: data.message || "Authenticated."};
  }

  /**
   * Pins a File/Blob and returns its CID.
   *
   * @param {File|Blob} file
   * @param {string} [name]  human-readable label stored in Pinata's metadata
   * @returns {Promise<{cid: string, size: number, name: string, url: string}>}
   */
  async function uploadFile(file, name) {
    if (!file) throw IpfsError("No file selected.", "NO_FILE");
    if (file.size === 0) throw IpfsError("That file is empty.", "EMPTY_FILE");
    if (file.size > MAX_FILE_BYTES) {
      throw IpfsError(
        "File is " + formatBytes(file.size) + "; the limit is " + formatBytes(MAX_FILE_BYTES) + ".",
        "FILE_TOO_LARGE"
      );
    }

    var credentialMode = requireCredential().mode;
    var label = name || file.name || "bountypulse-upload";

    var form = new FormData();
    form.append("file", file, label);
    form.append("pinataMetadata", JSON.stringify({name: label, keyvalues: {app: "BountyPulse"}}));
    form.append("pinataOptions", JSON.stringify({cidVersion: 0}));

    log("info", "ipfs_upload_started", {
      name: label,
      bytes: file.size,
      type: file.type || "unknown",
      auth: credentialMode
    });

    var response = await requestWithRetry(
      PINATA_API + "/pinning/pinFileToIPFS",
      {
        method: "POST",
        // NOTE: no Content-Type header. The browser must set it itself so the
        // multipart boundary is generated correctly.
        headers: authHeaders(),
        body: form
      },
      UPLOAD_TIMEOUT_MS,
      "file upload"
    );

    var result = await response.json();
    var cid = result.IpfsHash;
    if (!cid) throw IpfsError("Pinata responded without a CID.", "NO_CID");

    log("info", "ipfs_upload_complete", {name: label, cid: cid, bytes: file.size});
    return {cid: cid, size: file.size, name: label, url: gatewayUrl(cid)};
  }

  /**
   * Pins a JSON document (bounty briefs, work manifests) and returns its CID.
   * @param {object} value
   * @param {string} [name]
   */
  async function uploadJson(value, name) {
    var credentialMode = requireCredential().mode;
    var label = name || "bountypulse-metadata.json";

    log("info", "ipfs_json_upload_started", {name: label, auth: credentialMode});

    var response = await requestWithRetry(
      PINATA_API + "/pinning/pinJSONToIPFS",
      {
        method: "POST",
        headers: Object.assign({"Content-Type": "application/json"}, authHeaders()),
        body: JSON.stringify({
          pinataContent: value,
          pinataMetadata: {name: label, keyvalues: {app: "BountyPulse"}},
          pinataOptions: {cidVersion: 0}
        })
      },
      UPLOAD_TIMEOUT_MS,
      "JSON upload"
    );

    var result = await response.json();
    var cid = result.IpfsHash;
    if (!cid) throw IpfsError("Pinata responded without a CID.", "NO_CID");

    log("info", "ipfs_json_upload_complete", {name: label, cid: cid});
    return {cid: cid, name: label, url: gatewayUrl(cid)};
  }

  /** Convenience wrapper: pins a plain text document. */
  function uploadText(text, filename) {
    var blob = new Blob([text], {type: "text/plain"});
    return uploadFile(blob, filename || "note.txt");
  }

  /* ----------------------------------------------------------------------
     Public API — reads (rendering pinned content in the UI)
     ---------------------------------------------------------------------- */

  /**
   * The read gateway. PINATA_GATEWAY in .env (a dedicated gateway is faster and
   * is not rate-limited like the public one) overrides the default.
   *
   * Normalised rather than trusted: people write it as
   *   https://x.mypinata.cloud
   *   https://x.mypinata.cloud/
   *   https://x.mypinata.cloud/ipfs
   *   https://x.mypinata.cloud/ipfs/
   * and all four must produce the same working base. Anything that is not
   * http(s) is rejected outright — a bad value here would break every image on
   * the page, and silently falling back is far better than rendering nothing.
   */
  function getGatewayBase() {
    var configured = readInjected("gateway");
    if (!configured) return DEFAULT_GATEWAY;

    if (!/^https?:\/\//i.test(configured)) {
      log("warn", "pinata_gateway_ignored", {reason: "not an http(s) URL", length: configured.length});
      return DEFAULT_GATEWAY;
    }

    var base = configured.replace(/\/+$/, "");
    if (!/\/ipfs$/i.test(base)) base += "/ipfs";
    return base + "/";
  }

  /** Builds the public gateway URL used by every <img> and download link. */
  function gatewayUrl(cid) {
    if (!cid) return "";
    return getGatewayBase() + String(cid).replace(/^ipfs:\/\//, "");
  }

  /**
   * Fetches and parses a pinned JSON document.
   * Content addressing makes the result immutable, so it is cached forever.
   * Never throws: a missing brief must degrade to a placeholder card, not break
   * the whole feed.
   *
   * @returns {Promise<object|null>}
   */
  async function fetchJson(cid) {
    if (!cid) return null;
    if (contentCache.has(cid)) return contentCache.get(cid);

    try {
      var response = await requestWithRetry(gatewayUrl(cid), {method: "GET"}, REQUEST_TIMEOUT_MS, "gateway read");
      var data = await response.json();
      contentCache.set(cid, data);
      return data;
    } catch (err) {
      log("warn", "ipfs_fetch_failed", {cid: cid, reason: err.message});
      contentCache.set(cid, null); // negative-cache so a broken CID is not retried on every render
      return null;
    }
  }

  function isLikelyCid(value) {
    if (typeof value !== "string") return false;
    // CIDv0: Qm + 44 base58 chars. CIDv1: base32, starts with 'b'.
    return /^Qm[1-9A-HJ-NP-Za-km-z]{44}$/.test(value) || /^b[a-z2-7]{50,}$/.test(value);
  }

  function formatBytes(bytes) {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
    return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  }

  function shortCid(cid) {
    if (!cid || cid.length < 16) return cid || "";
    return cid.slice(0, 8) + "…" + cid.slice(-6);
  }

  global.IpfsHelper = Object.freeze({
    STORAGE_KEY_JWT: STORAGE_KEY_JWT,
    STORAGE_KEY_API_KEY: STORAGE_KEY_API_KEY,
    STORAGE_KEY_API_SECRET: STORAGE_KEY_API_SECRET,
    MAX_FILE_BYTES: MAX_FILE_BYTES,
    setJwt: setJwt,
    setApiKeyPair: setApiKeyPair,
    clearCredentials: clearCredentials,
    hasCredential: hasCredential,
    hasEnvCredential: hasEnvCredential,
    getCredentialInfo: getCredentialInfo,
    describeCredential: describeCredential,
    testAuthentication: testAuthentication,
    uploadFile: uploadFile,
    uploadJson: uploadJson,
    uploadText: uploadText,
    fetchJson: fetchJson,
    gatewayUrl: gatewayUrl,
    getGatewayBase: getGatewayBase,
    isLikelyCid: isLikelyCid,
    formatBytes: formatBytes,
    shortCid: shortCid
  });
})(window);
