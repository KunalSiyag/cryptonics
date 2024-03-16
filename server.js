const express = require('express');
const bodyParser = require('body-parser');

const app = express();
const PORT = 5500;

// Middleware to parse JSON bodies
app.use(bodyParser.json());

// Route to handle user login
app.post('/login', (req, res) => {
    const { username, password } = req.body;

    // Example authentication logic
    if (username === 'a' && password === 'p') {
        res.status(200).json({ message: "Login successful" });
    } else {
        res.status(401).json({ message: "Incorrect username or password" });
    }
});

// Start the server
app.listen(PORT, () => {
    console.log(`Server is running on http://localhost:${PORT}`);
});
