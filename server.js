const express = require("express");
const cors = require("cors");
const sqlite3 = require("sqlite3").verbose();

const app = express();
const PORT = 3000;

// ---- DB SETUP ----
// This creates/opens a local file "debug.db"
const db = new sqlite3.Database("./debug.db");

// Simple example table – swap for your real schema / APS export
db.serialize(() => {
  db.run(`
    CREATE TABLE IF NOT EXISTS wip_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      staff_name TEXT,
      client_code TEXT,
      week_ending TEXT,
      hours REAL
    )
  `);

  // Seed a couple rows if table is empty
  db.get("SELECT COUNT(*) as c FROM wip_entries", (err, row) => {
    if (err) return console.error(err);
    if (row.c === 0) {
      const stmt = db.prepare(
        "INSERT INTO wip_entries (staff_name, client_code, week_ending, hours) VALUES (?, ?, ?, ?)"
      );
      stmt.run("Justin", "KO001", "2025-11-21", 6.5);
      stmt.run("Justin", "P2ZOO", "2025-11-21", 3.0);
      stmt.run("Karen", "APS123", "2025-11-14", 7.25);
      stmt.finalize();
    }
  });
});

// ---- MIDDLEWARE ----
app.use(cors());
app.use(express.json());

// ---- SQL ENDPOINT ----
// WARNING: Do NOT expose this to the internet as-is.
// It’s for local sandbox / debugging only.
app.post("/api/sql", (req, res) => {
  const { query } = req.body || {};

  if (!query || typeof query !== "string") {
    return res.status(400).json({ error: "Missing SQL query string." });
  }

  // Decide if it's a SELECT or a write
  const trimmed = query.trim().toLowerCase();
  const isSelect = trimmed.startsWith("select") || trimmed.startsWith("pragma");

  if (isSelect) {
    db.all(query, (err, rows) => {
      if (err) {
        console.error(err);
        return res.status(400).json({ error: err.message });
      }
      return res.json({ rows });
    });
  } else {
    db.run(query, function (err) {
      if (err) {
        console.error(err);
        return res.status(400).json({ error: err.message });
      }
      return res.json({
        rowsAffected: this.changes,
        lastID: this.lastID
      });
    });
  }
});

// ---- START SERVER ----
app.listen(PORT, () => {
  console.log(`SQL debug API listening at http://localhost:${PORT}`);
});
