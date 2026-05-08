import os
import socket
from flask import Flask
from redis import Redis, RedisError

app = Flask(__name__)
redis = Redis(host=os.getenv("REDIS_HOST", "redis"), db=0, socket_connect_timeout=2, socket_timeout=2)


@app.route("/")
def hello():
    try:
        visits = redis.incr("counter")
    except RedisError:
        visits = "<i>cannot connect to Redis, counter disabled</i>"

    return (
        f"<h3>Hello {os.getenv('NAME', 'World')}!</h3>"
        f"<b>Hostname:</b> {socket.gethostname()}<br/>"
        f"<b>Visits:</b> {visits}"
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
