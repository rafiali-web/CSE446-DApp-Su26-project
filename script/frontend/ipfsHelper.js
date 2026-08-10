async function uploadToIPFS(file) {
    if (!file) {
        throw new Error("Please select a file first.");
    }

    const formData = new FormData();
    formData.append("file", file);

    const response = await fetch("http://localhost:3001/upload", {
        method: "POST",
        body: formData
    });

    if (!response.ok) {
        throw new Error("IPFS upload failed.");
    }

    const result = await response.json();

    if (!result.success || !result.cid) {
        throw new Error("No CID returned from Pinata server.");
    }

    return result;
}
