import os
from flask import Flask, jsonify

app = Flask(__name__)


@app.route("/")
def index():
    return jsonify(message="Hello from the payments-api",
                    env=os.getenv("APP_ENV", "local"))


@app.route("/healthz")
def health():
    return jsonify(status="ok")


@app.route("/ready")
def ready():
    if not os.getenv("DATABASE_URL"):
        return jsonify(status="not ready", reason="DATABASE_URL not set"), 503
    return jsonify(status="ready")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
