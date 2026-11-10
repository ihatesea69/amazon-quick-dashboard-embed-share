# -*- coding: utf-8 -*-
"""
Quick / QuickSight dashboard share - a single Lambda behind a Function URL
(HTTPS, password gated). Lets viewers WITHOUT SSO open one dashboard.

Routes:
  GET  /                                    -> the page (password gate)
  GET  /quicksight-embedding-js-sdk.min.js  -> the embedding SDK
  GET  /api/session                         -> is there a valid session cookie
  GET  /api/embed                           -> mint an embed URL (after auth)
  POST /auth                                -> check password, set signed cookie

Design notes:
- Every identifier comes from environment variables. Nothing is hardcoded.
- The embed URL is minted for ONE registered user (QS_USER_ARN). Everyone who
  knows the password views as that one user, so no extra seat / session cost.
- Password never lives in code: only a random SALT + SHA256(SALT+password) HASH
  are stored as env vars. The cookie is a stateless HMAC token.
- AllowedDomains must equal the parent page origin. Behind CloudFront that is the
  CloudFront domain, so deploy pins EMBED_ORIGIN; header fallbacks are backup only.
"""
import base64
import hashlib
import hmac
import json
import os
import time
from pathlib import Path

import boto3

ACCOUNT      = os.environ["QS_ACCOUNT"]
REGION       = os.environ.get("QS_REGION", "us-east-1")
USER_ARN     = os.environ["QS_USER_ARN"]
DASHBOARD_ID = os.environ["QS_DASHBOARD_ID"]
SESSION_MIN  = int(os.environ.get("SESSION_MIN", "120"))
SALT         = os.environ["GATE_SALT"]
PWD_HASH     = os.environ["GATE_HASH"]
SECRET       = os.environ["GATE_SECRET"].encode()

HERE         = Path(__file__).resolve().parent
# Optional: if the dashboard lives in a DIFFERENT account, set MINT_ROLE_ARN to a
# role in that account that this Lambda may assume to mint the embed URL.
MINT_ROLE_ARN = os.environ.get("MINT_ROLE_ARN", "")
MINT_EXT_ID   = os.environ.get("MINT_EXTERNAL_ID", "")
_sts = boto3.client("sts")


def _qs_client():
    if MINT_ROLE_ARN:
        kwargs = {"RoleArn": MINT_ROLE_ARN, "RoleSessionName": "dashboard-embed",
                  "DurationSeconds": 900}
        if MINT_EXT_ID:
            kwargs["ExternalId"] = MINT_EXT_ID
        cr = _sts.assume_role(**kwargs)["Credentials"]
        return boto3.client("quicksight", region_name=REGION,
                            aws_access_key_id=cr["AccessKeyId"],
                            aws_secret_access_key=cr["SecretAccessKey"],
                            aws_session_token=cr["SessionToken"])
    return boto3.client("quicksight", region_name=REGION)


def _json(code, obj, cookies=None):
    r = {
        "statusCode": code,
        "headers": {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
        },
        "body": json.dumps(obj),
    }
    if cookies:
        r["cookies"] = cookies
    return r


def _file(name, ctype):
    data = (HERE / name).read_bytes()
    return {
        "statusCode": 200,
        "headers": {"Content-Type": ctype, "Cache-Control": "no-store"},
        "body": base64.b64encode(data).decode(),
        "isBase64Encoded": True,
    }


def _check_pwd(pwd):
    h = hashlib.sha256((SALT + pwd).encode()).hexdigest()
    return hmac.compare_digest(h, PWD_HASH)


def _make_token():
    exp = str(int(time.time()) + SESSION_MIN * 60)
    sig = hmac.new(SECRET, exp.encode(), hashlib.sha256).hexdigest()
    return exp + "." + sig


def _valid_token(tok):
    if not tok or "." not in tok:
        return False
    exp, sig = tok.split(".", 1)
    good = hmac.new(SECRET, exp.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, good):
        return False
    try:
        return time.time() < int(exp)
    except ValueError:
        return False


def _cookie(event, name):
    for c in event.get("cookies", []) or []:
        if c.startswith(name + "="):
            return c.split("=", 1)[1]
    return None


def _allowed_origin(event, domain):
    # Parent-page origin = what AllowedDomains must contain. Behind CloudFront,
    # requestContext.domainName is the Lambda URL host, not CloudFront, so deploy
    # pins EMBED_ORIGIN = https://<cloudfront-domain>. Fallbacks are backup only.
    pinned = os.environ.get("EMBED_ORIGIN", "")
    if pinned.startswith("https://"):
        return pinned
    h = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    o = h.get("origin")
    if o and o.startswith("https://"):
        return o
    ref = h.get("referer")
    if ref and ref.startswith("https://"):
        parts = ref.split("/")
        return parts[0] + "//" + parts[2]
    xf = h.get("x-forwarded-host")
    if xf:
        return "https://" + xf.split(",")[0].strip()
    return "https://" + domain


def _mint(origin):
    r = _qs_client().generate_embed_url_for_registered_user(
        AwsAccountId=ACCOUNT,
        UserArn=USER_ARN,
        ExperienceConfiguration={"Dashboard": {"InitialDashboardId": DASHBOARD_ID}},
        AllowedDomains=[origin],
        SessionLifetimeInMinutes=SESSION_MIN,
    )
    return r["EmbedUrl"]


def handler(event, context):
    rc     = event.get("requestContext", {})
    http   = rc.get("http", {})
    method = http.get("method", "GET")
    path   = http.get("path", "/")
    domain = rc.get("domainName", "")
    try:
        if method == "GET" and path in ("/", "/index.html"):
            return _file("index.html", "text/html; charset=utf-8")
        if method == "GET" and path.endswith("quicksight-embedding-js-sdk.min.js"):
            return _file("quicksight-embedding-js-sdk.min.js", "application/javascript; charset=utf-8")
        if method == "GET" and path == "/api/session":
            return _json(200, {"authed": _valid_token(_cookie(event, "sid"))})
        if method == "GET" and path == "/api/embed":
            if not _valid_token(_cookie(event, "sid")):
                return _json(401, {"error": "auth required"})
            return _json(200, {"embedUrl": _mint(_allowed_origin(event, domain))})
        if method == "POST" and path == "/auth":
            raw = event.get("body", "") or ""
            if event.get("isBase64Encoded"):
                raw = base64.b64decode(raw).decode()
            try:
                pwd = json.loads(raw or "{}").get("password", "")
            except Exception:
                pwd = ""
            if pwd and _check_pwd(pwd):
                tok = _make_token()
                ck = ("sid=" + tok + "; HttpOnly; SameSite=Lax; Path=/; Secure; Max-Age="
                      + str(SESSION_MIN * 60))
                return _json(200, {"ok": True}, cookies=[ck])
            time.sleep(1.0)
            return _json(401, {"ok": False, "error": "wrong password"})
        return _json(404, {"error": "not found"})
    except Exception as e:
        return _json(500, {"error": str(e)})
