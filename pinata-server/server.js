require("dotenv").config();

const express = require("express");
const multer = require("multer");
const cors = require("cors");

const app = express();

const upload = multer({
    storage: multer.memoryStorage()
});

app.use(cors());

app.get("/", (req, res) => {
    res.json({
        message: "BountyPulse Pinata server is running"
    });
});

app.post("/upload", upload.single("file"), async (req, res) => {
    try {
        if (!req.file) {
            return res.status(400).json({
                error: "No file uploaded"
            });
        }

        const formData = new FormData();

        const blob = new Blob(
            [req.file.buffer],
            { type: req.file.mimetype }
        );

        formData.append(
            "file",
            blob,
            req.file.originalname
        );

        const response = await fetch(
            "https://uploads.pinata.cloud/v3/files",
            {
                method: "POST",
                headers: {
                    Authorization: `Bearer ${process.env.PINATA_JWT}`
                },
                body: formData
            }
        );

        const data = await response.json();

        if (!response.ok) {
            console.error("Pinata error:", data);

            return res.status(response.status).json({
                error: "Pinata upload failed",
                details: data
            });
        }

        console.log("Pinata upload successful:", data);

        res.json({
            success: true,
            cid: data.data.cid,
            name: data.data.name
        });

    } catch (error) {

        console.error("Upload error:", error);

        res.status(500).json({
            error: "Server upload error",
            details: error.message
        });
    }
});

app.listen(process.env.PORT || 3001, () => {
    console.log(
        `Pinata server running on port ${process.env.PORT || 3001}`
    );
});