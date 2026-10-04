import os

import pymysql
from flask import Flask, jsonify, request

app = Flask(__name__)


def db():
    return pymysql.connect(host=os.environ["DB_HOST"], user=os.environ["DB_USER"],
                           password=os.environ["DB_PASSWORD"], database=os.environ["DB_NAME"], autocommit=True)


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/api/notes")
def notes():
    with db() as c, c.cursor() as cur:
        cur.execute("CREATE TABLE IF NOT EXISTS notes (id INT AUTO_INCREMENT PRIMARY KEY, body TEXT)")
        cur.execute("SELECT id, body FROM notes ORDER BY id DESC LIMIT 50")
        return jsonify([{"id": i, "body": b} for i, b in cur.fetchall()])


@app.post("/api/notes")
def add_note():
    with db() as c, c.cursor() as cur:
        cur.execute("INSERT INTO notes (body) VALUES (%s)", (request.json.get("body", ""),))
    return {"ok": True}, 201
