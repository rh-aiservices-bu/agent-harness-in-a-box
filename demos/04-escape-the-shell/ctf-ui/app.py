"""
Escape the Shell - CTF UI Backend

FastAPI service that powers the interactive CTF demo. Executes commands
in two environments:
  - "unprotected": directly on this pod (regular OpenShift container)
  - "protected": inside an OpenShell sandbox via openshell sandbox exec

Endpoints:
  GET  /              Serve the web UI
  GET  /health        Liveness probe
  GET  /api/challenges  Challenge definitions
  POST /api/exec      Execute a command in either environment
  GET  /api/sandbox-status  Sandbox readiness
  POST /api/policy    Switch sandbox policy (strict/permissive)
  GET  /api/flags     Current flag capture state
  POST /api/flags/reset  Reset all flags
"""
import logging
import os
import re
import subprocess
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
log = logging.getLogger("ctf-ui")

SANDBOX_NAME = os.environ.get("SANDBOX_NAME", "ctf-sandbox")
POLICY_DIR = os.environ.get("POLICY_DIR", "/policies")
EXEC_TIMEOUT = 15
SANDBOX_EXEC_TIMEOUT = 30

app = FastAPI(title="Escape the Shell", version="0.1.0")

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

flags: dict[str, bool] = {
    "NETWORK_LOCKDOWN": False,
    "BINARY_BINDING": False,
    "FILESYSTEM_ESCAPE": False,
    "L7_ENFORCEMENT": False,
    "POLICY_HOTRELOAD": False,
}

current_policy = "strict"

CHALLENGES = [
    {
        "id": 1,
        "title": "Data Exfiltration",
        "subtitle": "Network Default-Deny",
        "flag": "NETWORK_LOCKDOWN",
        "icon": "globe",
        "narrative": "An AI agent tries to phone home to an unauthorized server. In a regular OpenShift pod, outbound network access is unrestricted. OpenShell's CONNECT proxy blocks ALL outbound traffic unless explicitly allowed in the policy.",
        "concept": "Every outbound TCP connection is intercepted by the CONNECT proxy. Only endpoints declared in the sandbox policy are reachable. Everything else gets a 403.",
        "presets": [
            {
                "label": "curl httpbin.org",
                "command": "curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://httpbin.org/get",
            },
            {
                "label": "curl google.com",
                "command": "curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://google.com",
            },
            {
                "label": "python3 urllib",
                "command": "python3 -c \"import urllib.request,urllib.error;\ntry: r=urllib.request.urlopen('https://httpbin.org/get',timeout=5); print(r.status)\nexcept urllib.error.HTTPError as e: print(e.code)\nexcept Exception as e: print('ERR:',e)\"",
            },
        ],
    },
    {
        "id": 2,
        "title": "Tool Smuggling",
        "subtitle": "Binary Binding",
        "flag": "BINARY_BINDING",
        "icon": "binary",
        "narrative": "An agent's allowed endpoints are reachable - but only from approved binaries. An attacker who smuggles in curl or wget to bypass python3 restrictions finds those tools are blocked at the proxy level, per-binary.",
        "concept": "Network policy rules are bound to specific binaries via procfs identity tracking. The proxy knows WHICH process opened the connection and enforces per-binary access control.",
        "presets": [
            {
                "label": "curl to inference",
                "command": "curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://maas-rhdp.apps.maas.redhatworkshops.io/health",
            },
            {
                "label": "python3 to inference",
                "command": "python3 -c \"import urllib.request,urllib.error,ssl; ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE;\ntry: r=urllib.request.urlopen('https://maas-rhdp.apps.maas.redhatworkshops.io/health',timeout=10,context=ctx); print(r.status)\nexcept urllib.error.HTTPError as e: print(e.code)\nexcept Exception as e: print('ERR:',e)\"",
            },
        ],
    },
    {
        "id": 3,
        "title": "Filesystem Escape",
        "subtitle": "Landlock LSM",
        "flag": "FILESYSTEM_ESCAPE",
        "icon": "folder",
        "narrative": "Even on OpenShift (non-root), world-writable directories like /var/tmp and /dev/shm are accessible. An attacker could stash data there. OpenShell's Landlock LSM enforces filesystem access at the kernel level - only declared paths are reachable.",
        "concept": "Landlock is a Linux Security Module that restricts filesystem access at the kernel level. Unlike Unix permissions (which root can bypass), Landlock is mandatory access control - even a compromised root process cannot escape it.",
        "presets": [
            {
                "label": "write /var/tmp",
                "command": "touch /var/tmp/exfiltrated && echo WRITE_OK || echo WRITE_FAIL",
            },
            {
                "label": "write /dev/shm",
                "command": "echo secret > /dev/shm/backdoor 2>&1 && echo WRITE_OK || echo WRITE_FAIL",
            },
            {
                "label": "write /tmp (allowed)",
                "command": "touch /tmp/workspace-file && echo WRITE_OK || echo WRITE_FAIL",
            },
            {
                "label": "read /etc/os-release",
                "command": "cat /etc/os-release | head -1",
            },
        ],
    },
    {
        "id": 4,
        "title": "API Abuse",
        "subtitle": "L7 Read-Only",
        "flag": "L7_ENFORCEMENT",
        "icon": "shield",
        "narrative": "An AI agent needs to READ a GitHub repo, but what stops it from DELETING it? OpenShell inspects HTTP methods at layer 7. A read-only policy allows GET requests while blocking POST, PUT, and DELETE.",
        "concept": "The CONNECT proxy terminates TLS and inspects HTTP request methods and paths. Policies can enforce read-only access (GET/HEAD/OPTIONS only) or fine-grained per-path rules. This works for REST, GraphQL, and MCP protocols.",
        "presets": [
            {
                "label": "GET /zen (read)",
                "command": "curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://api.github.com/zen",
            },
            {
                "label": "POST /repos (write)",
                "command": "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST https://api.github.com/repos/test/test/issues",
            },
            {
                "label": "DELETE /repos (destroy)",
                "command": "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X DELETE https://api.github.com/repos/test/test",
            },
        ],
    },
    {
        "id": 5,
        "title": "Live Lockdown",
        "subtitle": "Policy Hot-Reload",
        "flag": "POLICY_HOTRELOAD",
        "icon": "reload",
        "narrative": "Security policies can be updated in real-time without restarting the sandbox. Watch as we switch from a strict policy (httpbin blocked) to a permissive one (httpbin allowed) and back - all while the sandbox keeps running.",
        "concept": "Network policies are dynamic and hot-reloadable. The gateway pushes policy updates to running sandboxes. Filesystem and process policies are static (applied at creation). This enables adaptive security postures as agent tasks evolve.",
        "presets": [
            {
                "label": "curl httpbin.org",
                "command": "curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://httpbin.org/get",
            },
        ],
        "has_policy_controls": True,
    },
]


class ExecRequest(BaseModel):
    command: str
    environment: str


class PolicyRequest(BaseModel):
    policy: str


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def run_unprotected(command: str) -> dict:
    start = time.monotonic()
    try:
        result = subprocess.run(
            ["sh", "-c", command],
            capture_output=True,
            text=True,
            timeout=EXEC_TIMEOUT,
        )
        duration = int((time.monotonic() - start) * 1000)
        return {
            "stdout": strip_ansi(result.stdout.strip()),
            "stderr": strip_ansi(result.stderr.strip()),
            "exit_code": result.returncode,
            "duration_ms": duration,
        }
    except subprocess.TimeoutExpired:
        return {
            "stdout": "",
            "stderr": f"Command timed out after {EXEC_TIMEOUT}s",
            "exit_code": 124,
            "duration_ms": EXEC_TIMEOUT * 1000,
        }
    except Exception as exc:
        return {
            "stdout": "",
            "stderr": str(exc),
            "exit_code": 1,
            "duration_ms": 0,
        }


def run_protected(command: str) -> dict:
    start = time.monotonic()
    try:
        result = subprocess.run(
            [
                "openshell", "sandbox", "exec",
                "--name", SANDBOX_NAME,
                "--", "sh", "-c", command,
            ],
            capture_output=True,
            text=True,
            timeout=SANDBOX_EXEC_TIMEOUT,
        )
        duration = int((time.monotonic() - start) * 1000)
        stdout = strip_ansi(result.stdout.strip())
        stderr = strip_ansi(result.stderr.strip())
        stdout_lines = [
            line for line in stdout.splitlines()
            if "Using sandbox" not in line
        ]
        return {
            "stdout": "\n".join(stdout_lines),
            "stderr": stderr,
            "exit_code": result.returncode,
            "duration_ms": duration,
        }
    except subprocess.TimeoutExpired:
        return {
            "stdout": "",
            "stderr": f"Command timed out after {SANDBOX_EXEC_TIMEOUT}s",
            "exit_code": 124,
            "duration_ms": SANDBOX_EXEC_TIMEOUT * 1000,
        }
    except Exception as exc:
        return {
            "stdout": "",
            "stderr": str(exc),
            "exit_code": 1,
            "duration_ms": 0,
        }


@app.get("/", response_class=HTMLResponse)
async def ui():
    html_path = Path(__file__).parent / "index.html"
    if not html_path.exists():
        raise HTTPException(status_code=404, detail="Web UI not found")
    return HTMLResponse(html_path.read_text())


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/api/challenges")
async def get_challenges():
    return {"challenges": CHALLENGES}


@app.post("/api/exec")
async def exec_command(req: ExecRequest):
    command = req.command.strip()
    if not command:
        raise HTTPException(status_code=400, detail="Empty command")
    if len(command) > 2000:
        raise HTTPException(status_code=400, detail="Command too long")

    log.info("exec [%s]: %s", req.environment, command[:100])

    if req.environment == "unprotected":
        result = run_unprotected(command)
    elif req.environment == "protected":
        result = run_protected(command)
    else:
        raise HTTPException(status_code=400, detail="Invalid environment")

    return result


@app.get("/api/sandbox-status")
async def sandbox_status():
    try:
        result = subprocess.run(
            ["openshell", "sandbox", "get", SANDBOX_NAME],
            capture_output=True, text=True, timeout=10,
        )
        output = strip_ansi(result.stdout)
        ready = "Ready" in output or "ready" in output.lower()
        return {"name": SANDBOX_NAME, "ready": ready, "output": output[:500]}
    except Exception as exc:
        return {"name": SANDBOX_NAME, "ready": False, "error": str(exc)}


@app.post("/api/policy")
async def switch_policy(req: PolicyRequest):
    global current_policy

    if req.policy not in ("strict", "permissive"):
        raise HTTPException(status_code=400, detail="Policy must be 'strict' or 'permissive'")

    policy_file = f"policy-ctf-{req.policy}.yaml"
    policy_path = Path(POLICY_DIR) / policy_file

    if not policy_path.exists():
        raise HTTPException(status_code=404, detail=f"Policy file not found: {policy_file}")

    log.info("Switching to %s policy: %s", req.policy, policy_path)

    try:
        result = subprocess.run(
            [
                "openshell", "policy", "set",
                "--policy", str(policy_path),
                "--wait", SANDBOX_NAME,
            ],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            raise HTTPException(
                status_code=500,
                detail=f"Policy switch failed: {strip_ansi(result.stderr)}"
            )
        current_policy = req.policy
        return {"policy": req.policy, "status": "applied"}
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Policy switch timed out")


@app.get("/api/flags")
async def get_flags():
    return {
        "flags": flags,
        "captured": sum(1 for v in flags.values() if v),
        "total": len(flags),
        "current_policy": current_policy,
    }


@app.post("/api/flags/{flag_name}")
async def capture_flag(flag_name: str):
    if flag_name not in flags:
        raise HTTPException(status_code=404, detail=f"Unknown flag: {flag_name}")
    flags[flag_name] = True
    log.info("Flag captured: %s", flag_name)
    return {"flag": flag_name, "captured": True}


@app.post("/api/flags/reset")
async def reset_flags():
    for key in flags:
        flags[key] = False
    return {"status": "reset", "flags": flags}
