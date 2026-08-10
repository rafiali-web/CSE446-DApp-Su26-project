let provider;
let signer;
let contract;

const CONTRACT_ADDRESS = "0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519";

async function connectWallet() {
    try {
        console.log("Connect button clicked");

        if (!window.ethereum) {
            alert("MetaMask is not installed.");
            return;
        }

        console.log("MetaMask detected");

        provider = new ethers.BrowserProvider(window.ethereum);

        await provider.send("eth_requestAccounts", []);

        signer = await provider.getSigner();

        const address = await signer.getAddress();

        console.log("Connected wallet:", address);

        const network = await provider.getNetwork();

        console.log(
            "Network chain ID:",
            network.chainId.toString()
        );

        if (network.chainId !== 31337n) {
            alert(
                "Please switch MetaMask to BountyPulse Local (Chain ID 31337)."
            );
            return;
        }

        console.log("Correct network detected");

        const response = await fetch("BountyPulse.json");

        if (!response.ok) {
            throw new Error("Could not load BountyPulse.json");
        }

        const abi = await response.json();

        console.log("ABI loaded");

        contract = new ethers.Contract(
            CONTRACT_ADDRESS,
            abi,
            signer
        );

        console.log(
            "BountyPulse contract connected:",
            contract
        );

        document.getElementById("walletAddress").textContent =
            address;

        document.getElementById("networkStatus").textContent =
            "Network: BountyPulse Local (Chain ID 31337)";

        alert("Wallet connected successfully!");

    } catch (error) {
        console.error("Connection error:", error);

        alert(
            "Connection failed. Open the browser Console (F12) and check the error."
        );
    }
}


// ================================
// IPFS UPLOAD
// ================================

async function handleIPFSUpload() {
    try {
        const fileInput = document.getElementById("fileInput");
        const uploadStatus = document.getElementById("uploadStatus");
        const ipfsCid = document.getElementById("ipfsCid");
        const bountyDetailsCid =
            document.getElementById("bountyDetailsCid");

        const file = fileInput.files[0];

        if (!file) {
            alert("Please select a file first.");
            return;
        }

        uploadStatus.textContent = "Uploading to IPFS...";
        ipfsCid.textContent = "-";

        console.log("Uploading file:", file.name);

        const result = await uploadToIPFS(file);

        console.log("IPFS upload result:", result);

        ipfsCid.textContent = result.cid;

        bountyDetailsCid.value = result.cid;

        uploadStatus.textContent =
            "Upload successful! CID received from Pinata.";

        console.log("IPFS CID:", result.cid);

    } catch (error) {
        console.error("IPFS upload error:", error);

        document.getElementById("uploadStatus").textContent =
            "Upload failed: " + error.message;
    }
}


// ================================
// BUTTON LISTENERS
// ================================

document
    .getElementById("connectWallet")
    .addEventListener("click", connectWallet);

document
    .getElementById("uploadFile")
    .addEventListener("click", handleIPFSUpload);


// ================================
// METAMASK EVENTS
// ================================

if (window.ethereum) {

    window.ethereum.on("accountsChanged", async () => {

        if (signer) {

            try {
                const accounts =
                    await provider.send("eth_accounts", []);

                if (accounts.length === 0) {
                    document.getElementById("walletAddress").textContent =
                        "Wallet not connected";

                    return;
                }

                const address = accounts[0];

                document.getElementById("walletAddress").textContent =
                    address;

                console.log("Account changed:", address);

            } catch (error) {
                console.error(
                    "Account change error:",
                    error
                );
            }
        }
    });


    window.ethereum.on("chainChanged", () => {
        window.location.reload();
    });
}
EOFcat > app.js <<'EOF'
let provider;
let signer;
let contract;

const CONTRACT_ADDRESS = "0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519";

async function connectWallet() {
    try {
        console.log("Connect button clicked");

        if (!window.ethereum) {
            alert("MetaMask is not installed.");
            return;
        }

        console.log("MetaMask detected");

        provider = new ethers.BrowserProvider(window.ethereum);

        await provider.send("eth_requestAccounts", []);

        signer = await provider.getSigner();

        const address = await signer.getAddress();

        console.log("Connected wallet:", address);

        const network = await provider.getNetwork();

        console.log(
            "Network chain ID:",
            network.chainId.toString()
        );

        if (network.chainId !== 31337n) {
            alert(
                "Please switch MetaMask to BountyPulse Local (Chain ID 31337)."
            );
            return;
        }

        console.log("Correct network detected");

        const response = await fetch("BountyPulse.json");

        if (!response.ok) {
            throw new Error("Could not load BountyPulse.json");
        }

        const abi = await response.json();

        console.log("ABI loaded");

        contract = new ethers.Contract(
            CONTRACT_ADDRESS,
            abi,
            signer
        );

        console.log(
            "BountyPulse contract connected:",
            contract
        );

        document.getElementById("walletAddress").textContent =
            address;

        document.getElementById("networkStatus").textContent =
            "Network: BountyPulse Local (Chain ID 31337)";

        alert("Wallet connected successfully!");

    } catch (error) {
        console.error("Connection error:", error);

        alert(
            "Connection failed. Open the browser Console (F12) and check the error."
        );
    }
}


// ================================
// IPFS UPLOAD
// ================================

async function handleIPFSUpload() {
    try {
        const fileInput = document.getElementById("fileInput");
        const uploadStatus = document.getElementById("uploadStatus");
        const ipfsCid = document.getElementById("ipfsCid");
        const bountyDetailsCid =
            document.getElementById("bountyDetailsCid");

        const file = fileInput.files[0];

        if (!file) {
            alert("Please select a file first.");
            return;
        }

        uploadStatus.textContent = "Uploading to IPFS...";
        ipfsCid.textContent = "-";

        console.log("Uploading file:", file.name);

        const result = await uploadToIPFS(file);

        console.log("IPFS upload result:", result);

        ipfsCid.textContent = result.cid;

        bountyDetailsCid.value = result.cid;

        uploadStatus.textContent =
            "Upload successful! CID received from Pinata.";

        console.log("IPFS CID:", result.cid);

    } catch (error) {
        console.error("IPFS upload error:", error);

        document.getElementById("uploadStatus").textContent =
            "Upload failed: " + error.message;
    }
}


// ================================
// BUTTON LISTENERS
// ================================

document
    .getElementById("connectWallet")
    .addEventListener("click", connectWallet);

document
    .getElementById("uploadFile")
    .addEventListener("click", handleIPFSUpload);


// ================================
// METAMASK EVENTS
// ================================

if (window.ethereum) {

    window.ethereum.on("accountsChanged", async () => {

        if (signer) {

            try {
                const accounts =
                    await provider.send("eth_accounts", []);

                if (accounts.length === 0) {
                    document.getElementById("walletAddress").textContent =
                        "Wallet not connected";

                    return;
                }

                const address = accounts[0];

                document.getElementById("walletAddress").textContent =
                    address;

                console.log("Account changed:", address);

            } catch (error) {
                console.error(
                    "Account change error:",
                    error
                );
            }
        }
    });


    window.ethereum.on("chainChanged", () => {
        window.location.reload();
    });
}
EOFcat > app.js <<'EOF'
let provider;
let signer;
let contract;

const CONTRACT_ADDRESS = "0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519";

async function connectWallet() {
    try {
        console.log("Connect button clicked");

        if (!window.ethereum) {
            alert("MetaMask is not installed.");
            return;
        }

        console.log("MetaMask detected");

        provider = new ethers.BrowserProvider(window.ethereum);

        await provider.send("eth_requestAccounts", []);

        signer = await provider.getSigner();

        const address = await signer.getAddress();

        console.log("Connected wallet:", address);

        const network = await provider.getNetwork();

        console.log(
            "Network chain ID:",
            network.chainId.toString()
        );

        if (network.chainId !== 31337n) {
            alert(
                "Please switch MetaMask to BountyPulse Local (Chain ID 31337)."
            );
            return;
        }

        console.log("Correct network detected");

        const response = await fetch("BountyPulse.json");

        if (!response.ok) {
            throw new Error("Could not load BountyPulse.json");
        }

        const abi = await response.json();

        console.log("ABI loaded");

        contract = new ethers.Contract(
            CONTRACT_ADDRESS,
            abi,
            signer
        );

        console.log(
            "BountyPulse contract connected:",
            contract
        );

        document.getElementById("walletAddress").textContent =
            address;

        document.getElementById("networkStatus").textContent =
            "Network: BountyPulse Local (Chain ID 31337)";

        alert("Wallet connected successfully!");

    } catch (error) {
        console.error("Connection error:", error);

        alert(
            "Connection failed. Open the browser Console (F12) and check the error."
        );
    }
}


// ================================
// IPFS UPLOAD
// ================================

async function handleIPFSUpload() {
    try {
        const fileInput = document.getElementById("fileInput");
        const uploadStatus = document.getElementById("uploadStatus");
        const ipfsCid = document.getElementById("ipfsCid");
        const bountyDetailsCid =
            document.getElementById("bountyDetailsCid");

        const file = fileInput.files[0];

        if (!file) {
            alert("Please select a file first.");
            return;
        }

        uploadStatus.textContent = "Uploading to IPFS...";
        ipfsCid.textContent = "-";

        console.log("Uploading file:", file.name);

        const result = await uploadToIPFS(file);

        console.log("IPFS upload result:", result);

        ipfsCid.textContent = result.cid;

        bountyDetailsCid.value = result.cid;

        uploadStatus.textContent =
            "Upload successful! CID received from Pinata.";

        console.log("IPFS CID:", result.cid);

    } catch (error) {
        console.error("IPFS upload error:", error);

        document.getElementById("uploadStatus").textContent =
            "Upload failed: " + error.message;
    }
}


// ================================
// BUTTON LISTENERS
// ================================

document
    .getElementById("connectWallet")
    .addEventListener("click", connectWallet);

document
    .getElementById("uploadFile")
    .addEventListener("click", handleIPFSUpload);


// ================================
// METAMASK EVENTS
// ================================

if (window.ethereum) {

    window.ethereum.on("accountsChanged", async () => {

        if (signer) {

            try {
                const accounts =
                    await provider.send("eth_accounts", []);

                if (accounts.length === 0) {
                    document.getElementById("walletAddress").textContent =
                        "Wallet not connected";

                    return;
                }

                const address = accounts[0];

                document.getElementById("walletAddress").textContent =
                    address;

                console.log("Account changed:", address);

            } catch (error) {
                console.error(
                    "Account change error:",
                    error
                );
            }
        }
    });


    window.ethereum.on("chainChanged", () => {
        window.location.reload();
    });
}
