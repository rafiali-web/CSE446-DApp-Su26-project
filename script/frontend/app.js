let provider;
let signer;

async function connectWallet() {
    if (!window.ethereum) {
        alert("Please install MetaMask.");
        return;
    }

    provider = new ethers.BrowserProvider(window.ethereum);
    await provider.send("eth_requestAccounts", []);
    signer = await provider.getSigner();

    const address = await signer.getAddress();
    document.getElementById("walletAddress").textContent = address;
}

document.getElementById("connectWallet").addEventListener("click", connectWallet);

if (window.ethereum) {
    window.ethereum.on("accountsChanged", async () => {
        if (signer) {
            const address = await signer.getAddress();
            document.getElementById("walletAddress").textContent = address;
        }
    });
}
