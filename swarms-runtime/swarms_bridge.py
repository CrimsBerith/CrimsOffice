"""ClawOffice Persistent Swarms Runtime Daemon (HTTP + MCP Streamable HTTP).

Runs `kyegomez/swarms` workflows as a local loopback service on 127.0.0.1:8765,
bridging ClawOffice agents and Keychain-hydrated provider configs to Swarms
multi-agent architectures (`SwarmRouter`, `SequentialWorkflow`, `ConcurrentWorkflow`,
`HierarchicalSwarm`, `GroupChat`, `DebateWithJudge`, `MixtureOfAgents`, etc.).
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

RUNTIME_DIR = Path(__file__).resolve().parent
def _resolve_writable_workspace() -> Path:
    explicit = os.environ.get("WORKSPACE_DIR", "").strip()
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    # Signed .app/Contents/Resources must never be mutated at runtime
    if ".app/Contents/Resources" not in str(RUNTIME_DIR):
        candidates.append(RUNTIME_DIR / "workspace")
    candidates.append(Path.home() / ".openclaw" / "swarms-runtime" / "workspace")
    candidates.append(Path("/tmp/crimsoffice-swarms-workspace"))
    for cand in candidates:
        try:
            cand.mkdir(parents=True, exist_ok=True)
            probe = cand / ".write_probe"
            probe.write_text("ok", encoding="utf-8")
            probe.unlink(missing_ok=True)
            return cand
        except OSError:
            continue
    return Path("/tmp")

WORKSPACE_DIR = _resolve_writable_workspace()

os.environ.setdefault("SWARMS_TELEMETRY_ENABLED", "false")
os.environ.setdefault("WORKSPACE_DIR", str(WORKSPACE_DIR))
os.environ.setdefault("LITELLM_LOG", "ERROR")

import swarms  # noqa: E402
from pydantic import BaseModel, Field  # noqa: E402
from starlette.applications import Starlette  # noqa: E402
from starlette.requests import Request  # noqa: E402
from starlette.responses import JSONResponse, Response  # noqa: E402
from starlette.routing import Route  # noqa: E402
from swarms import (  # noqa: E402
    Agent,
    ConcurrentWorkflow,
    DebateWithJudge,
    GroupChat,
    HierarchicalSwarm,
    MajorityVoting,
    MixtureOfAgents,
    MultiAgentRouter,
    PlannerWorkerSwarm,
    SequentialWorkflow,
    SwarmRouter,
)
import uvicorn  # noqa: E402


STARTED_AT = time.time()
BRIDGE_VERSION = "2026.11.26.2"
MAX_RUN_HISTORY = 50
DEFAULT_HOST = os.environ.get("SWARMS_HOST", "127.0.0.1")
DEFAULT_PORT = int(os.environ.get("SWARMS_PORT", "8765"))


class SwarmCancelledError(RuntimeError):
    """Raised immediately when an active Swarms run is cancelled."""


class RuntimeLoadTracker:
    """Thread-safe shared cooldown, provider concurrency cap, and in-flight load tracker across Swarms calls."""

    def __init__(self) -> None:
        import threading
        self._lock = threading.RLock()
        self._cond = threading.Condition(self._lock)
        self._model_cooldowns: Dict[Tuple[str, str, str], float] = {}
        self._model_errors: Dict[Tuple[str, str, str], int] = {}
        self._provider_cooldowns: Dict[Tuple[str, str], float] = {}
        self._provider_errors: Dict[Tuple[str, str], int] = {}
        self._in_flight: Dict[Tuple[str, str, str], int] = {}
        self._provider_in_flight: Dict[Tuple[str, str], int] = {}

    @staticmethod
    def _prov_key(prov: ProviderSpec) -> Tuple[str, str]:
        return (prov.kind, (prov.base_url or "").strip().rstrip("/"))

    @classmethod
    def _cand_key(cls, prov: ProviderSpec, model: str) -> Tuple[str, str, str]:
        return (prov.kind, (prov.base_url or "").strip().rstrip("/"), model.strip())

    @staticmethod
    def provider_concurrency_limit(prov: ProviderSpec) -> int:
        # Leave 1 slot headroom under EVREN's 4-concurrent account limit for interactive UI turns
        if prov.kind == "evren":
            return 3
        if prov.kind == "antigravityCLI":
            return 2
        return 4

    def provider_in_flight(self, prov: ProviderSpec) -> int:
        pk = self._prov_key(prov)
        with self._lock:
            return self._provider_in_flight.get(pk, 0)

    def acquire_provider_slot(
        self,
        prov: ProviderSpec,
        model: str,
        max_wait: float = 8.0,
        cancel_check: Optional[Any] = None,
    ) -> bool:
        pk = self._prov_key(prov)
        ck = self._cand_key(prov, model)
        limit = max(1, self.provider_concurrency_limit(prov))
        deadline = time.time() + max(0.0, max_wait)
        with self._cond:
            while True:
                if cancel_check and cancel_check():
                    raise SwarmCancelledError("Swarm görevi kullanıcı tarafından iptal edildi.")
                if self._provider_in_flight.get(pk, 0) < limit:
                    self._in_flight[ck] = self._in_flight.get(ck, 0) + 1
                    self._provider_in_flight[pk] = self._provider_in_flight.get(pk, 0) + 1
                    return True
                rem = deadline - time.time()
                if rem <= 0:
                    return False
                self._cond.wait(timeout=min(0.25, rem))

    def begin_in_flight(self, prov: ProviderSpec, model: str) -> None:
        pk = self._prov_key(prov)
        ck = self._cand_key(prov, model)
        with self._lock:
            self._in_flight[ck] = self._in_flight.get(ck, 0) + 1
            self._provider_in_flight[pk] = self._provider_in_flight.get(pk, 0) + 1

    def end_in_flight(self, prov: ProviderSpec, model: str) -> None:
        pk = self._prov_key(prov)
        ck = self._cand_key(prov, model)
        with self._cond:
            cur = self._in_flight.get(ck, 0)
            self._in_flight[ck] = max(0, cur - 1)
            p_cur = self._provider_in_flight.get(pk, 0)
            self._provider_in_flight[pk] = max(0, p_cur - 1)
            self._cond.notify_all()

    def mark_success(self, prov: ProviderSpec, model: str) -> None:
        pk = self._prov_key(prov)
        ck = self._cand_key(prov, model)
        with self._lock:
            self._model_cooldowns.pop(ck, None)
            self._model_errors[ck] = 0
            self._provider_cooldowns.pop(pk, None)
            self._provider_errors[pk] = 0

    def mark_failure(self, prov: ProviderSpec, model: str, exc: Exception) -> bool:
        pk = self._prov_key(prov)
        ck = self._cand_key(prov, model)
        is_fatal = _is_provider_fatal_error(exc)
        low = str(exc).lower()
        is_rate = any(k in low for k in (
            "429", "rate limit", "ratelimiterror", "too many",
            "quota", "overloaded", "busy", "capacity", "eşzamanlı", "yoğun",
        ))
        now = time.time()
        with self._lock:
            m_err = self._model_errors.get(ck, 0) + 1
            self._model_errors[ck] = m_err
            if is_rate:
                secs = min(180.0, 30.0 * (2 ** min(3, m_err - 1)))
            else:
                secs = min(120.0, float(max(1, m_err)) * 25.0)
            self._model_cooldowns[ck] = now + secs

            p_err = self._provider_errors.get(pk, 0) + 1
            self._provider_errors[pk] = p_err
            if is_fatal:
                self._provider_cooldowns[pk] = now + 300.0
            elif p_err >= 2:
                self._provider_cooldowns[pk] = now + 45.0
        return is_fatal

    def is_cooled(self, prov: ProviderSpec, model: str) -> bool:
        now = time.time()
        pk = self._prov_key(prov)
        ck = self._cand_key(prov, model)
        with self._lock:
            p_until = self._provider_cooldowns.get(pk)
            if p_until is not None:
                if now < p_until:
                    return True
                self._provider_cooldowns.pop(pk, None)
            m_until = self._model_cooldowns.get(ck)
            if m_until is not None:
                if now < m_until:
                    return True
                self._model_cooldowns.pop(ck, None)
            return False

    def order_candidates(self, candidates: List[Tuple[ProviderSpec, str]]) -> List[Tuple[ProviderSpec, str]]:
        now = time.time()
        with self._lock:
            idle_uncooled: List[Tuple[int, int, int, Tuple[ProviderSpec, str]]] = []
            busy_uncooled: List[Tuple[int, int, int, int, Tuple[ProviderSpec, str]]] = []
            cooled: List[Tuple[float, int, Tuple[ProviderSpec, str]]] = []
            for idx, (prov, model) in enumerate(candidates):
                pk = self._prov_key(prov)
                ck = self._cand_key(prov, model)
                p_until = self._provider_cooldowns.get(pk, 0.0)
                m_until = self._model_cooldowns.get(ck, 0.0)
                until = max(p_until, m_until)
                if until > now:
                    cooled.append((until, idx, (prov, model)))
                else:
                    inflight = self._in_flight.get(ck, 0)
                    p_inflight = self._provider_in_flight.get(pk, 0)
                    p_saturated = 1 if p_inflight >= self.provider_concurrency_limit(prov) else 0
                    if inflight == 0:
                        idle_uncooled.append((p_saturated, p_inflight, idx, (prov, model)))
                    else:
                        busy_uncooled.append((p_saturated, inflight, p_inflight, idx, (prov, model)))
            idle_uncooled.sort(key=lambda x: (x[0], x[1], x[2]))
            busy_uncooled.sort(key=lambda x: (x[0], x[1], x[2], x[3]))
            cooled.sort(key=lambda x: (x[0], x[1]))
            return (
                [c for _, _, _, c in idle_uncooled]
                + [c for _, _, _, _, c in busy_uncooled]
                + [c for _, _, c in cooled]
            )

    def clear(self) -> None:
        with self._cond:
            self._model_cooldowns.clear()
            self._model_errors.clear()
            self._provider_cooldowns.clear()
            self._provider_errors.clear()
            self._in_flight.clear()
            self._provider_in_flight.clear()
            self._cond.notify_all()


RUNTIME_TRACKER = RuntimeLoadTracker()


class SwarmTelemetryCollector:
    """Records per-run successes and failures to feed cooldown state back to Swift."""

    def __init__(self) -> None:
        import threading
        self._lock = threading.Lock()
        self.failed_candidates: List[Dict[str, Any]] = []
        self.used_routes: List[Dict[str, Any]] = []
        self.events: List[str] = []

    def log_event(self, message: str) -> None:
        with self._lock:
            self.events.append(message[:240])

    def record_failure(self, prov: ProviderSpec, model: str, error: str, is_fatal: bool) -> None:
        with self._lock:
            self.failed_candidates.append(
                {
                    "provider_kind": prov.kind,
                    "provider_name": prov.name,
                    "model_name": model,
                    "error": error[:240],
                    "is_provider_fatal": is_fatal,
                }
            )

    def record_success(self, prov: ProviderSpec, model: str, used_fallback: bool) -> None:
        with self._lock:
            self.used_routes.append(
                {
                    "provider_kind": prov.kind,
                    "provider_name": prov.name,
                    "model_name": model,
                    "used_fallback": used_fallback,
                }
            )

    def to_dict(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "failed_candidates": list(self.failed_candidates[-24:]),
                "used_routes": list(self.used_routes[-24:]),
            }

SUPPORTED_SWARM_TYPES: List[Dict[str, Any]] = [
    {
        "type": "Auto",
        "label": "Swarms Akıllı Seçim",
        "min_agents": 1,
        "description": "Görev içeriğine ve ajan sayısına göre en uygun Swarms topolojisini seçer.",
    },
    {
        "type": "SequentialWorkflow",
        "label": "Sıralı İş Akışı",
        "min_agents": 1,
        "description": "Ajanlar sırayla çalışır; her ajan bir öncekinin çıktısını devralır.",
    },
    {
        "type": "ConcurrentWorkflow",
        "label": "Eşzamanlı Paralel Akış",
        "min_agents": 1,
        "description": "Tüm ajanlar aynı görevi paralel olarak işler.",
    },
    {
        "type": "HierarchicalSwarm",
        "label": "Hiyerarşik Yönetici Swarm",
        "min_agents": 2,
        "description": "Direktör ajanı görevi alt görevlere böler ve uzman ajanlara dağıtır.",
    },
    {
        "type": "GroupChat",
        "label": "Dinamik Grup Sohbeti",
        "min_agents": 2,
        "description": "Ajanlar çok turlu dinamik tartışma yürütür.",
    },
    {
        "type": "DebateWithJudge",
        "label": "Hakemli Tartışma",
        "min_agents": 2,
        "description": "Savunan/karşıt ajanlar tartışır, hakem ajan nihai kararı verir.",
    },
    {
        "type": "MixtureOfAgents",
        "label": "Mixture of Agents (MOA)",
        "min_agents": 2,
        "description": "Uzman ajanlar paralel yanıt üretir, toplayıcı ajan tek sentez çıkarır.",
    },
    {
        "type": "MajorityVoting",
        "label": "Çoğunluk Oylaması & Uzlaşı",
        "min_agents": 2,
        "description": "Ajanların yanıtlarını değerlendirip uzlaşı kararı üretir.",
    },
    {
        "type": "AgentRearrange",
        "label": "Özel Akış Grafı",
        "min_agents": 2,
        "description": "Özel yönlendirme ifadesiyle (A -> B, C -> D) karma akış çalıştırır.",
    },
    {
        "type": "RoundRobin",
        "label": "Sıralı Tur (Round Robin)",
        "min_agents": 2,
        "description": "Ajanlar sırayla tur bazlı katkı verir.",
    },
    {
        "type": "PlannerWorkerSwarm",
        "label": "Planlayıcı & Çalışanlar",
        "min_agents": 2,
        "description": "Planlayıcı görevleri planlar, çalışan ajanlar uygular.",
    },
    {
        "type": "MultiAgentRouter",
        "label": "Çoklu Ajan Yönlendirici",
        "min_agents": 2,
        "description": "Görevi yeteneklerine göre en uygun uzman ajana yönlendirir.",
    },
]


class ProviderSpec(BaseModel):
    """In-memory provider configuration forwarded per request (never persisted)."""

    kind: str = "custom"
    name: str = "OpenAI Compatible"
    base_url: str = ""
    api_key: str = ""
    auth_style: str = "bearer"
    model_name: str = "deepseek-v4.1-flash"
    fallback_models: List[str] = Field(default_factory=list)
    timeout_seconds: Optional[int] = None


class AgentSpec(BaseModel):
    """Agent specification mapped from ClawOffice OfficeAgent."""

    name: str
    title: str = "Uzman Ajan"
    system_prompt: str = ""
    model_name: str = "deepseek-v4.1-flash"
    temperature: float = 0.25
    role: str = "worker"
    provider: ProviderSpec = Field(default_factory=ProviderSpec)
    fallback_provider: Optional[ProviderSpec] = None
    fallback_providers: List[ProviderSpec] = Field(default_factory=list)
    retry_policy: Optional[Dict[str, Any]] = None


class SwarmRunRequest(BaseModel):
    """Payload accepted by POST /v1/swarm/run."""

    task: str
    swarm_type: str = "Auto"
    max_loops: int = 1
    rearrange_flow: Optional[str] = None
    workspace_path: Optional[str] = None
    allow_local_edits: bool = False
    agents: List[AgentSpec] = Field(default_factory=list)
    director: Optional[AgentSpec] = None
    retry_policy: Optional[Dict[str, Any]] = None


@dataclass
class RunState:
    """Tracks live and historical swarm executions."""

    run_id: str
    swarm_type: str
    task_preview: str
    agent_names: List[str]
    status: str = "running"
    started_at: float = field(default_factory=time.time)
    duration_ms: int = 0
    final_output: str = ""
    steps: List[Dict[str, Any]] = field(default_factory=list)
    error: Optional[str] = None
    cancelled: bool = False
    telemetry: Optional[SwarmTelemetryCollector] = None

    def to_summary(self) -> Dict[str, Any]:
        return {
            "run_id": self.run_id,
            "swarm_type": self.swarm_type,
            "task_preview": self.task_preview,
            "agent_names": self.agent_names,
            "status": self.status,
            "duration_ms": self.duration_ms,
            "step_count": len(self.steps),
            "output_preview": self.final_output[:260],
            "error": self.error,
        }


ACTIVE_RUNS: Dict[str, RunState] = {}
RUN_HISTORY: deque[RunState] = deque(maxlen=MAX_RUN_HISTORY)
TOTAL_RUNS = 0


def redact_secrets(text: str, secrets: List[str]) -> str:
    """Scrubs API keys and bearer tokens from diagnostic text."""
    cleaned = text
    for sec in secrets:
        s = (sec or "").strip()
        if len(s) >= 6:
            cleaned = cleaned.replace(s, "***REDACTED***")
    cleaned = re.sub(r"Bearer\s+[A-Za-z0-9._\-]{8,}", "Bearer ***REDACTED***", cleaned)
    return cleaned


def resolve_agy_binary(hint: str = "") -> Optional[str]:
    """Finds executable Antigravity CLI (`agy`) path if installed."""
    candidates = [
        hint.strip(),
        str(Path.home() / ".local/bin/agy"),
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy",
        "/usr/bin/agy",
    ]
    for cand in candidates:
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return shutil.which("agy")


class AntigravityCLILLM:
    """Minimal Swarms-compatible LLM adapter calling local `agy` CLI."""

    def __init__(
        self,
        model_name: str,
        system_prompt: str = "",
        bin_hint: str = "",
        cwd: Optional[str] = None,
        allow_local_edits: bool = False,
        timeout_seconds: int = 180,
    ) -> None:
        self.model_name = model_name or "gemini-4-hydrogen-xhigh"
        self.system_prompt = system_prompt or ""
        self.bin_hint = bin_hint
        self.cwd = cwd if (cwd and os.path.isdir(cwd)) else str(WORKSPACE_DIR)
        self.allow_local_edits = allow_local_edits
        self.timeout_seconds = timeout_seconds
        self.usage: Dict[str, int] = {
            "input_tokens": 0,
            "output_tokens": 0,
            "cached_tokens": 0,
            "reasoning_tokens": 0,
            "total_tokens": 0,
        }
        self.usage_hook = None

    def _format_prompt(self, task: Optional[str], messages: Optional[List[Dict[str, Any]]]) -> str:
        parts: List[str] = []
        if self.system_prompt.strip():
            parts.append(f"[SİSTEM TALİMATI]\n{self.system_prompt.strip()[:12000]}")
        if messages:
            for msg in messages[-12:]:
                role = str(msg.get("role", "user"))
                content = msg.get("content", "")
                if isinstance(content, list):
                    content = "\n".join(
                        str(c.get("text", "")) for c in content if isinstance(c, dict)
                    )
                text = str(content).strip()
                if text and role != "system":
                    parts.append(f"[{role}]: {text[:6000]}")
        if task and str(task).strip():
            parts.append(str(task).strip())
        return "\n\n".join(parts).strip()

    def run(
        self,
        task: Optional[str] = None,
        messages: Optional[List[Dict[str, Any]]] = None,
        **_: Any,
    ) -> str:
        bin_path = resolve_agy_binary(self.bin_hint)
        if not bin_path:
            raise RuntimeError("Antigravity CLI (agy) bulunamadı.")
        prompt = self._format_prompt(task, messages)
        if not prompt:
            raise ValueError("Antigravity CLI için boş istem.")
        args = [
            bin_path,
            "-p",
            prompt,
            "--model",
            self.model_name,
            "--output-format",
            "json",
            "--disable-slash-commands",
            "--dangerously-skip-permissions" if self.allow_local_edits else "--sandbox",
        ]
        env = {k: v for k, v in os.environ.items() if not k.startswith("CLAWOFFICE_")}
        extra_paths = [
            str(Path.home() / ".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        existing_path = env.get("PATH", "")
        env["PATH"] = ":".join(extra_paths + ([existing_path] if existing_path else []))
        proc = subprocess.run(
            args,
            cwd=self.cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=self.timeout_seconds,
            check=False,
        )
        stdout = (proc.stdout or "").strip()
        if stdout:
            for line in reversed(stdout.splitlines()):
                line = line.strip()
                if line.startswith("{"):
                    try:
                        obj = json.loads(line)
                        if isinstance(obj.get("response"), str) and obj["response"].strip():
                            return obj["response"].strip()
                        res = obj.get("result")
                        if isinstance(res, dict) and isinstance(res.get("response"), str):
                            return res["response"].strip()
                    except json.JSONDecodeError:
                        pass
            if proc.returncode == 0:
                return stdout
        err = (proc.stderr or "").strip() or f"agy çıkış kodu {proc.returncode}"
        raise RuntimeError(err[:400])

    def __call__(self, task: Optional[str] = None, **kwargs: Any) -> str:
        return self.run(task=task, **kwargs)


def _normalize_provider_for_swarms(spec: AgentSpec) -> ProviderSpec:
    """Selects an HTTP-compatible provider when primary lacks HTTP config."""
    primary = spec.provider
    if primary.kind == "antigravityCLI":
        if resolve_agy_binary(primary.base_url):
            return primary
        if spec.fallback_provider and spec.fallback_provider.base_url:
            return spec.fallback_provider
    return primary


def build_extra_headers(prov: ProviderSpec) -> Dict[str, str]:
    """Builds provider-specific HTTP auth/routing headers for LiteLLM."""
    key = (prov.api_key or "").strip()
    headers: Dict[str, str] = {}
    if prov.auth_style == "bearerAndXApiKey" and key:
        headers["Authorization"] = f"Bearer {key}"
        headers["X-API-Key"] = key
    elif prov.auth_style == "xApiKey" and key:
        headers["X-API-Key"] = key
    elif prov.auth_style == "bearer" and key:
        headers["Authorization"] = f"Bearer {key}"
    if prov.kind == "openRouter":
        headers["HTTP-Referer"] = "https://clawoffice.local"
        headers["X-Title"] = "ClawOffice Swarms"
    return headers


def map_role(title: str, explicit_role: str) -> str:
    """Maps ClawOffice agent title to Swarms literal role."""
    valid_roles = {
        "supervisor", "director", "boss", "generator", "evaluator", "revisor",
        "worker", "manager", "team-leader", "team-manager", "team-lead",
        "researcher", "analyst", "architect", "developer", "tester", "qa",
        "designer", "product-owner", "scrum-master", "coordinator", "mentor",
        "trainer", "consultant", "specialist", "expert", "strategist",
        "planner", "executor", "reviewer", "auditor",
    }
    if explicit_role in valid_roles:
        return explicit_role
    low = (title or "").lower()
    if any(k in low for k in ("mimar", "architect")):
        return "architect"
    if any(k in low for k in ("direktör", "director", "lider", "lead")):
        return "director"
    if any(k in low for k in ("denet", "audit", "güvenlik")):
        return "auditor"
    if any(k in low for k in ("qa", "test")):
        return "qa"
    if any(k in low for k in ("tasar", "design", "ui", "ux")):
        return "designer"
    if any(k in low for k in ("araştır", "research")):
        return "researcher"
    if any(k in low for k in ("kod", "yazılım", "developer", "swift", "engineer")):
        return "developer"
    return "specialist"


def _is_provider_fatal_error(exc: Exception) -> bool:
    """Returns True when an error applies to the entire provider (auth/network), not a single model."""
    low = str(exc).lower()
    markers = (
        "authentication", "401", "403", "unauthorized", "invalid token",
        "api key", "sign in again", "connectionerror", "connecterror",
        "name or service not known", "nodename nor servname", "connection refused",
        "failed to establish a new connection", "ssl", "certificate",
    )
    return any(m in low for m in markers)


def _strip_think_tags(text: str) -> str:
    """Removes inline <think>...</think> blocks so reasoning-only outputs are caught cleanly."""
    cleaned = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    if "<think>" in cleaned:
        cleaned = cleaned.split("<think>", 1)[0]
    return cleaned.strip()


def _provider_candidates_for_spec(spec: AgentSpec) -> List[Tuple[ProviderSpec, str]]:
    """Builds ordered `(ProviderSpec, model_name)` failover chain without mixing provider catalogs."""
    candidates: List[Tuple[ProviderSpec, str]] = []
    seen_pairs: set[Tuple[str, str, str]] = set()

    def add_candidate(prov: ProviderSpec, model: str) -> None:
        m = (model or "").strip()
        if not m:
            return
        if prov.kind == "antigravityCLI" and not resolve_agy_binary(prov.base_url):
            return
        if prov.kind != "antigravityCLI" and not (prov.base_url or "").strip():
            return
        key = (prov.kind, prov.base_url.strip().rstrip("/"), m)
        if key not in seen_pairs:
            seen_pairs.add(key)
            candidates.append((prov, m))

    primary = spec.provider
    primary_model = (spec.model_name or primary.model_name or "deepseek-v4.1-flash").strip()
    add_candidate(primary, primary_model)
    for m in primary.fallback_models:
        add_candidate(primary, m)

    fb_list: List[ProviderSpec] = []
    if spec.fallback_provider is not None:
        fb_list.append(spec.fallback_provider)
    fb_list.extend(spec.fallback_providers)

    for fb_prov in fb_list:
        fb_primary = (fb_prov.model_name or "").strip()
        if fb_primary:
            add_candidate(fb_prov, fb_primary)
        for m in fb_prov.fallback_models:
            add_candidate(fb_prov, m)

    return candidates


class ResilientSwarmsLLM:
    """Swarms-compatible LLM adapter with cross-provider failover, cooldowns, and empty-output protection."""

    def __init__(
        self,
        spec: AgentSpec,
        workspace_path: Optional[str] = None,
        allow_local_edits: bool = False,
        timeout_seconds: int = 55,
        telemetry: Optional[SwarmTelemetryCollector] = None,
        cancel_check: Optional[Any] = None,
        retry_policy: Optional[Dict[str, Any]] = None,
    ) -> None:
        self.spec = spec
        self.workspace_path = workspace_path
        self.allow_local_edits = allow_local_edits
        self.timeout_seconds = timeout_seconds
        self.telemetry = telemetry
        self.cancel_check = cancel_check
        self.retry_policy = retry_policy or {"max_attempts": 1, "initial_delay": 1, "multiplier": 2}
        self.candidates = _provider_candidates_for_spec(spec)
        self.model_name = (
            self.candidates[0][1]
            if self.candidates
            else (spec.model_name or spec.provider.model_name or "deepseek-v4.1-flash")
        )
        self.last_used_model = self.model_name
        self.last_used_provider = spec.provider.name
        self.usage: Dict[str, int] = {
            "input_tokens": 0,
            "output_tokens": 0,
            "cached_tokens": 0,
            "reasoning_tokens": 0,
            "total_tokens": 0,
        }
        self.usage_hook = None

    def _call_http_provider(
        self,
        prov: ProviderSpec,
        model: str,
        task: Optional[str],
        messages: Optional[List[Dict[str, Any]]],
    ) -> str:
        import litellm

        sys_prompt = (self.spec.system_prompt or "").strip() or f"Sen {self.spec.name} ({self.spec.title}) uzman ajansın."
        chat_messages: List[Dict[str, str]] = [{"role": "system", "content": sys_prompt}]
        if messages:
            for msg in messages[-16:]:
                role = str(msg.get("role", "user")).strip() or "user"
                if role == "system":
                    continue
                content = msg.get("content", "")
                if isinstance(content, list):
                    content = "\n".join(str(c.get("text", "")) for c in content if isinstance(c, dict))
                text = str(content).strip()
                if text:
                    chat_messages.append({"role": role if role in ("user", "assistant") else "user", "content": text})
        if task and str(task).strip():
            if not chat_messages or chat_messages[-1].get("content") != str(task).strip():
                chat_messages.append({"role": "user", "content": str(task).strip()})

        base_url = prov.base_url.strip().rstrip("/")
        api_key = (prov.api_key or "").strip() or "sk-local-none"
        headers = build_extra_headers(prov)
        temp = max(0.0, min(2.0, float(self.spec.temperature)))

        resp = litellm.completion(
            model=model,
            messages=chat_messages,
            custom_llm_provider="openai",
            api_base=base_url,
            api_key=api_key,
            extra_headers=headers or None,
            temperature=temp,
            max_tokens=4096,
            timeout=prov.timeout_seconds or self.timeout_seconds,
            drop_params=True,
            num_retries=0,
        )
        choices = getattr(resp, "choices", None) or []
        if not choices:
            raise RuntimeError(f"{prov.name}/{model}: boş choices yanıtı")
        msg_obj = getattr(choices[0], "message", None)
        raw_content = getattr(msg_obj, "content", None) if msg_obj is not None else None
        cleaned = _strip_think_tags(str(raw_content or ""))
        if not cleaned:
            raise RuntimeError(f"{prov.name}/{model}: model boş içerik döndürdü (yalnızca reasoning veya boş)")

        usage_obj = getattr(resp, "usage", None)
        if usage_obj is not None:
            in_tok = int(getattr(usage_obj, "prompt_tokens", 0) or 0)
            out_tok = int(getattr(usage_obj, "completion_tokens", 0) or 0)
            self.usage["input_tokens"] += in_tok
            self.usage["output_tokens"] += out_tok
            self.usage["total_tokens"] += in_tok + out_tok
        return cleaned

    def run(
        self,
        task: Optional[str] = None,
        messages: Optional[List[Dict[str, Any]]] = None,
        **_: Any,
    ) -> str:
        if not self.candidates:
            raise RuntimeError(f"{self.spec.name} için geçerli sağlayıcı/model adayı bulunamadı.")

        ordered = RUNTIME_TRACKER.order_candidates(self.candidates)
        failed_providers: set[Tuple[str, str]] = set()
        errors: List[str] = []
        secrets = [p.api_key for p, _ in ordered]
        sys_prompt = (self.spec.system_prompt or "").strip() or f"Sen {self.spec.name} ({self.spec.title}) uzman ajansın."

        policy = self.retry_policy if isinstance(self.retry_policy, dict) else {}
        raw_attempts = policy.get("max_attempts", policy.get("max_retries", policy.get("maxRetries", 1)))
        max_attempts = max(1, min(3, int(raw_attempts or 1)))
        initial_delay = max(0.05, float(policy.get("initial_delay", policy.get("initialDelay", 0.5)) or 0.5))
        multiplier = max(1.0, float(policy.get("multiplier", 2.0) or 2.0))

        for idx, (prov, model) in enumerate(ordered):
            if self.cancel_check and self.cancel_check():
                raise SwarmCancelledError("Swarm görevi kullanıcı tarafından iptal edildi.")
            prov_key = (prov.kind, prov.base_url.strip().rstrip("/"))
            if prov_key in failed_providers:
                continue

            has_alt_provider = any(
                (alt_p.kind, alt_p.base_url.strip().rstrip("/")) != prov_key
                and (alt_p.kind, alt_p.base_url.strip().rstrip("/")) not in failed_providers
                and not RUNTIME_TRACKER.is_cooled(alt_p, alt_m)
                for alt_p, alt_m in ordered[idx + 1:]
            )
            slot_wait = 0.6 if has_alt_provider else min(10.0, max(2.0, float(self.timeout_seconds) * 0.2))
            if not RUNTIME_TRACKER.acquire_provider_slot(
                prov,
                model,
                max_wait=slot_wait,
                cancel_check=self.cancel_check,
            ):
                errors.append(f"{prov.name}/{model}: eşzamanlı istek sınırı dolu")
                continue

            current_delay = initial_delay
            try:
                for attempt in range(max_attempts):
                    if self.cancel_check and self.cancel_check():
                        raise SwarmCancelledError("Swarm görevi kullanıcı tarafından iptal edildi.")
                    try:
                        if prov.kind == "antigravityCLI":
                            cli = AntigravityCLILLM(
                                model_name=model,
                                system_prompt=sys_prompt,
                                bin_hint=prov.base_url,
                                cwd=self.workspace_path,
                                allow_local_edits=self.allow_local_edits,
                                timeout_seconds=max(90, self.timeout_seconds),
                            )
                            out = _strip_think_tags(cli.run(task=task, messages=messages))
                            if not out:
                                raise RuntimeError("Antigravity CLI boş çıktı döndürdü")
                        else:
                            out = self._call_http_provider(prov, model, task=task, messages=messages)

                        if out:
                            RUNTIME_TRACKER.mark_success(prov, model)
                            self.last_used_model = model
                            self.last_used_provider = prov.name
                            self.model_name = model
                            if self.telemetry is not None:
                                self.telemetry.record_success(prov, model, used_fallback=(idx > 0 or model != self.spec.model_name))
                            return out
                        raise RuntimeError(f"{prov.name}/{model}: boş yanıt döndü")
                    except SwarmCancelledError:
                        raise
                    except Exception as exc:
                        is_fatal = RUNTIME_TRACKER.mark_failure(prov, model, exc)
                        if is_fatal or attempt == max_attempts - 1:
                            err_safe = redact_secrets(str(exc), secrets)
                            errors.append(f"{prov.name}/{model}: {err_safe}")
                            if self.telemetry is not None:
                                self.telemetry.record_failure(prov, model, err_safe, is_fatal)
                            if is_fatal:
                                failed_providers.add(prov_key)
                            break
                        if self.telemetry is not None:
                            self.telemetry.log_event(
                                f"Retry {attempt + 1}/{max_attempts} for {prov.name}/{model} after {current_delay:.2f}s"
                            )
                        sleep_until = time.time() + current_delay
                        while time.time() < sleep_until:
                            if self.cancel_check and self.cancel_check():
                                raise SwarmCancelledError("Swarm görevi kullanıcı tarafından iptal edildi.")
                            time.sleep(min(0.15, max(0.0, sleep_until - time.time())))
                        current_delay *= multiplier
            finally:
                RUNTIME_TRACKER.end_in_flight(prov, model)

        raise RuntimeError(redact_secrets(" | ".join(errors[-4:]), secrets))

    def completion(self, messages: Optional[List[Dict[str, Any]]] = None, **kwargs: Any) -> Any:
        """Minimal LiteLLM-compatible completion shim used by MultiAgentRouter."""
        text = self.run(task=None, messages=messages, **kwargs)
        from types import SimpleNamespace
        return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=text))])

    def __call__(self, task: Optional[str] = None, **kwargs: Any) -> str:
        return self.run(task=task, **kwargs)


def build_swarms_agent(
    spec: AgentSpec,
    workspace_path: Optional[str] = None,
    allow_local_edits: bool = False,
    telemetry: Optional[SwarmTelemetryCollector] = None,
    cancel_check: Optional[Any] = None,
) -> Agent:
    """Constructs a `swarms.Agent` backed by `ResilientSwarmsLLM` cross-provider failover."""
    prov = _normalize_provider_for_swarms(spec)
    model_name = (spec.model_name or prov.model_name or "deepseek-v4.1-flash").strip()
    temp = max(0.0, min(2.0, float(spec.temperature)))
    role = map_role(spec.title, spec.role)
    sys_prompt = (spec.system_prompt or "").strip() or f"Sen {spec.name} ({spec.title}) uzman ajansın."

    resilient_llm = ResilientSwarmsLLM(
        spec=spec,
        workspace_path=workspace_path,
        allow_local_edits=allow_local_edits,
        telemetry=telemetry,
        cancel_check=cancel_check,
        retry_policy=getattr(spec, "retry_policy", None),
    )
    return Agent(
        agent_name=spec.name,
        agent_description=spec.title,
        system_prompt=sys_prompt,
        llm=resilient_llm,
        model_name=resilient_llm.model_name or model_name,
        max_loops=1,
        tools=None,
        temperature=temp,
        max_tokens=4096,
        role=role,
        print_on=False,
        verbose=False,
        autosave=False,
        retry_attempts=1,
        reasoning_prompt_on=False,
        context_compression=True,
    )


def choose_auto_swarm_type(task: str, agent_count: int) -> str:
    """Selects optimal Swarms topology from task intent and team size."""
    if agent_count <= 1:
        return "SequentialWorkflow"
    low = task.lower()
    if any(k in low for k in ("tartış", "debate", "karşılaştır", "hakem", "artı", "eksi")):
        return "DebateWithJudge" if agent_count >= 3 else "GroupChat"
    if any(k in low for k in ("paralel", "concurrent", "eşzamanlı", "sentez", "fikir", "brainstorm")):
        return "MixtureOfAgents" if agent_count >= 2 else "ConcurrentWorkflow"
    if any(k in low for k in ("oyla", "vote", "uzlaşı", "consensus", "karar")):
        return "MajorityVoting"
    if any(k in low for k in ("plan", "sprint", "mimari", "architect", "koordin", "hiyerarş")):
        return "HierarchicalSwarm"
    return "SequentialWorkflow"


def _resolved_agent_model(agent: Optional[Agent]) -> str:
    if agent is None:
        return ""
    llm = getattr(agent, "llm", None)
    used = getattr(llm, "last_used_model", None)
    return str(used or getattr(agent, "model_name", "") or "")


def normalize_swarm_steps(
    raw_result: Any,
    agents: List[Agent],
) -> Tuple[str, List[Dict[str, Any]]]:
    """Normalizes varied Swarms return payloads into `(final_output, steps)`."""
    agent_map = {a.agent_name: a for a in agents}
    steps: List[Dict[str, Any]] = []

    if isinstance(raw_result, list):
        for item in raw_result:
            if isinstance(item, dict):
                role = str(item.get("role", "")).strip()
                content = _strip_think_tags(str(item.get("content", "") or ""))
                if not content or role.lower() in ("user", "system", "human"):
                    continue
                matched = agent_map.get(role)
                steps.append(
                    {
                        "agent_name": role or "Swarm",
                        "role": matched.agent_description if matched else "Swarm Katılımcısı",
                        "model": _resolved_agent_model(matched),
                        "output": content,
                    }
                )
            elif isinstance(item, str) and item.strip():
                cleaned = _strip_think_tags(item)
                if cleaned:
                    steps.append(
                        {
                            "agent_name": "Swarm",
                            "role": "Swarm Çıktısı",
                            "model": "",
                            "output": cleaned,
                        }
                    )
    elif isinstance(raw_result, dict):
        messages = raw_result.get("messages") or raw_result.get("outputs")
        if isinstance(messages, list):
            return normalize_swarm_steps(messages, agents)
        text = json.dumps(raw_result, ensure_ascii=False, indent=2)
        steps.append(
            {
                "agent_name": agents[-1].agent_name if agents else "Swarm",
                "role": agents[-1].agent_description if agents else "Swarm",
                "model": _resolved_agent_model(agents[-1] if agents else None),
                "output": text,
            }
        )
    elif raw_result is not None:
        text = _strip_think_tags(str(raw_result))
        if text:
            steps.append(
                {
                    "agent_name": agents[-1].agent_name if agents else "Swarm",
                    "role": agents[-1].agent_description if agents else "Swarm",
                    "model": _resolved_agent_model(agents[-1] if agents else None),
                    "output": text,
                }
            )

    final_output = steps[-1]["output"] if steps else ""
    return final_output, steps


def _make_clone_judge(
    base_spec: AgentSpec,
    suffix: str,
    prompt: str,
    workspace_path: Optional[str],
    allow_local_edits: bool,
    telemetry: Optional[SwarmTelemetryCollector] = None,
    cancel_check: Optional[Any] = None,
) -> Agent:
    cloned = base_spec.model_copy(
        update={
            "name": f"{base_spec.name}-{suffix}",
            "title": f"{base_spec.title} ({suffix})",
            "system_prompt": prompt,
            "role": "evaluator",
        }
    )
    return build_swarms_agent(
        cloned,
        workspace_path=workspace_path,
        allow_local_edits=allow_local_edits,
        telemetry=telemetry,
        cancel_check=cancel_check,
    )


def run_swarm_sync(req: SwarmRunRequest, run_state: RunState) -> Tuple[str, str, List[Dict[str, Any]]]:
    """Executes the requested Swarms topology synchronously in a worker thread."""
    if not req.agents:
        raise ValueError("En az bir ajan tanımı gereklidir.")

    telemetry = run_state.telemetry
    cancel_check = lambda: run_state.cancelled  # noqa: E731
    secrets = _collect_secrets(req)

    def _log_fallback(arch: str, exc: Exception) -> None:
        msg = redact_secrets(str(exc), secrets)
        print(f"[swarms_bridge] ⚠️ {arch} fallback -> Sequential/Concurrent ({msg[:220]})", file=sys.stderr, flush=True)

    def _with_req_retry(spec: AgentSpec) -> AgentSpec:
        if spec.retry_policy is not None or req.retry_policy is None:
            return spec
        return spec.model_copy(update={"retry_policy": req.retry_policy})

    swarms_agents = [
        build_swarms_agent(
            _with_req_retry(spec),
            workspace_path=req.workspace_path,
            allow_local_edits=req.allow_local_edits,
            telemetry=telemetry,
            cancel_check=cancel_check,
        )
        for spec in req.agents
    ]
    requested_type = (req.swarm_type or "Auto").strip()
    effective_type = (
        choose_auto_swarm_type(req.task, len(swarms_agents))
        if requested_type.lower() == "auto"
        else requested_type
    )
    loops = max(1, min(6, int(req.max_loops or 1)))

    if len(swarms_agents) == 1 and effective_type not in ("SequentialWorkflow", "ConcurrentWorkflow"):
        effective_type = "SequentialWorkflow"

    run_state.swarm_type = effective_type

    def _run_router(s_type: str, agents_list: List[Agent], flow: Optional[str] = None) -> Any:
        router = SwarmRouter(
            name=f"clawoffice-{s_type.lower()}",
            description="ClawOffice Swarms Multi-Agent Runtime",
            max_loops=loops,
            agents=agents_list,
            swarm_type=s_type,  # type: ignore[arg-type]
            rearrange_flow=flow,
            output_type="dict",
            autosave=False,
            verbose=False,
        )
        return router.run(req.task)

    raw_result: Any = None

    if effective_type == "HierarchicalSwarm":
        director_spec = req.director or req.agents[0]
        director_agent = build_swarms_agent(
            director_spec,
            workspace_path=req.workspace_path,
            allow_local_edits=req.allow_local_edits,
            telemetry=telemetry,
            cancel_check=cancel_check,
        )
        workers = swarms_agents[1:] if (req.director is None and len(swarms_agents) > 1) else swarms_agents
        try:
            swarm = HierarchicalSwarm(
                name="ClawOffice-Hierarchical",
                director=director_agent,
                agents=workers,
                max_loops=loops,
                output_type="dict-all-except-first",
                director_model_name=director_agent.model_name,
                feedback_director_model_name=director_agent.model_name,
                director_settings={"llm": director_agent.llm, "model_name": director_agent.model_name},
                verbose=False,
                print_on=False,
                autosave=False,
            )
            # Route internal planning/feedback directors through ResilientSwarmsLLM instead of raw OPENAI_API_KEY
            swarm._planning_director = director_agent
            swarm._feedback_director = director_agent
            raw_result = swarm.run(req.task)
        except Exception as exc:
            if isinstance(exc, SwarmCancelledError):
                raise
            _log_fallback("HierarchicalSwarm", exc)
            effective_type = "SequentialWorkflow"
            run_state.swarm_type = "SequentialWorkflow (Hierarchical Fallback)"
            raw_result = _run_router("SequentialWorkflow", swarms_agents)

    elif effective_type == "DebateWithJudge":
        if len(swarms_agents) >= 3:
            pro, con, judge = swarms_agents[0], swarms_agents[1], swarms_agents[2]
        else:
            pro, con = swarms_agents[0], swarms_agents[1]
            judge_spec = req.director or req.agents[0]
            judge = _make_clone_judge(
                judge_spec,
                "Hakem",
                "Sen tarafsız teknik hakemsin. İki görüşü karşılaştır ve net karar ver.",
                req.workspace_path,
                req.allow_local_edits,
                telemetry=telemetry,
                cancel_check=cancel_check,
            )
        try:
            debate = DebateWithJudge(
                pro_agent=pro,
                con_agent=con,
                judge_agent=judge,
                max_loops=loops,
                output_type="str-all-except-first",
                verbose=False,
            )
            raw_result = debate.run(req.task)
        except Exception as exc:
            if isinstance(exc, SwarmCancelledError):
                raise
            _log_fallback("DebateWithJudge", exc)
            effective_type = "SequentialWorkflow"
            run_state.swarm_type = "SequentialWorkflow (Debate Fallback)"
            raw_result = _run_router("SequentialWorkflow", swarms_agents)

    elif effective_type == "MajorityVoting":
        consensus_spec = req.director or req.agents[0]
        consensus_llm = ResilientSwarmsLLM(
            consensus_spec,
            workspace_path=req.workspace_path,
            allow_local_edits=req.allow_local_edits,
            telemetry=telemetry,
            cancel_check=cancel_check,
        )
        try:
            mv = MajorityVoting(
                name="ClawOffice-MajorityVoting",
                agents=swarms_agents,
                max_loops=loops,
                output_type="dict",
                consensus_agent_model_name=consensus_llm.model_name,
                autosave=False,
                verbose=False,
            )
            mv.consensus_agent.llm = consensus_llm
            mv.consensus_agent.model_name = consensus_llm.model_name
            raw_result = mv.run(req.task)
        except Exception as exc:
            if isinstance(exc, SwarmCancelledError):
                raise
            _log_fallback("MajorityVoting", exc)
            effective_type = "ConcurrentWorkflow"
            run_state.swarm_type = "ConcurrentWorkflow (MajorityVoting Fallback)"
            raw_result = _run_router("ConcurrentWorkflow", swarms_agents)

    elif effective_type == "MixtureOfAgents":
        agg_spec = req.director or req.agents[0]
        agg_agent = _make_clone_judge(
            agg_spec,
            "Sentez",
            "Sen uzman ajanların paralel yanıtlarını analiz edip en doğru tek sentez raporu üreten toplayıcı ajansın.",
            req.workspace_path,
            req.allow_local_edits,
            telemetry=telemetry,
            cancel_check=cancel_check,
        )
        try:
            moa = MixtureOfAgents(
                name="ClawOffice-MixtureOfAgents",
                agents=swarms_agents,
                aggregator_agent=agg_agent,
                layers=1,
                max_loops=loops,
                output_type="dict-all-except-first",
                aggregator_model_name=agg_agent.model_name,
            )
            raw_result = moa.run(req.task)
        except Exception as exc:
            if isinstance(exc, SwarmCancelledError):
                raise
            _log_fallback("MixtureOfAgents", exc)
            effective_type = "ConcurrentWorkflow"
            run_state.swarm_type = "ConcurrentWorkflow (MOA Fallback)"
            raw_result = _run_router("ConcurrentWorkflow", swarms_agents)

    elif effective_type == "GroupChat":
        try:
            gc = GroupChat(
                name="ClawOffice-GroupChat",
                agents=swarms_agents,
                max_loops=max(2, min(8, loops * len(swarms_agents))),
                output_type="str-all-except-first",
                verbose=False,
                auto_equip=False,
            )
            raw_result = gc.run(req.task)
            gc_out, gc_steps = normalize_swarm_steps(raw_result, swarms_agents)
            if not gc_out.strip() and not gc_steps:
                raise RuntimeError("GroupChat ilk turda yanıt üretmedi")
        except Exception as exc:
            if isinstance(exc, SwarmCancelledError):
                raise
            _log_fallback("GroupChat", exc)
            effective_type = "RoundRobin"
            run_state.swarm_type = "RoundRobin (GroupChat Fallback)"
            raw_result = _run_router("RoundRobin", swarms_agents)

    elif effective_type == "AgentRearrange":
        flow = (req.rearrange_flow or "").strip()
        if not flow:
            flow = " -> ".join(a.agent_name for a in swarms_agents)
        raw_result = _run_router("AgentRearrange", swarms_agents, flow=flow)

    elif effective_type in ("ConcurrentWorkflow", "SequentialWorkflow", "RoundRobin"):
        raw_result = _run_router(effective_type, swarms_agents)

    elif effective_type == "PlannerWorkerSwarm":
        try:
            planner_spec = req.director or req.agents[0]
            planner_llm = ResilientSwarmsLLM(
                planner_spec,
                workspace_path=req.workspace_path,
                allow_local_edits=req.allow_local_edits,
                telemetry=telemetry,
                cancel_check=cancel_check,
            )
            pw = PlannerWorkerSwarm(
                name="ClawOffice-PlannerWorker",
                agents=swarms_agents,
                max_loops=loops,
                planner_model_name=planner_llm.model_name,
                judge_model_name=planner_llm.model_name,
                output_type="dict-all-except-first",
                autosave=False,
                verbose=False,
            )
            orig_create_planner = pw._create_planner_agent
            def _patched_planner(self_pw: Any, name: str = "Planner") -> Agent:
                ag = orig_create_planner(name=name)
                ag.llm = planner_llm
                ag.model_name = planner_llm.model_name
                return ag
            import types
            pw._create_planner_agent = types.MethodType(_patched_planner, pw)
            raw_result = pw.run(req.task)
        except Exception as exc:
            if isinstance(exc, SwarmCancelledError):
                raise
            _log_fallback("PlannerWorkerSwarm", exc)
            effective_type = "SequentialWorkflow"
            run_state.swarm_type = "SequentialWorkflow (Planner Fallback)"
            raw_result = _run_router("SequentialWorkflow", swarms_agents)

    elif effective_type == "MultiAgentRouter":
        try:
            router_spec = req.director or req.agents[0]
            router_llm = ResilientSwarmsLLM(
                router_spec,
                workspace_path=req.workspace_path,
                allow_local_edits=req.allow_local_edits,
                telemetry=telemetry,
                cancel_check=cancel_check,
            )
            mar = MultiAgentRouter(
                name="ClawOffice-MultiAgentRouter",
                agents=swarms_agents,
                model=router_llm.model_name,
                output_type="dict",
                print_on=False,
            )
            mar.function_caller = router_llm
            raw_result = mar.run(req.task)
        except Exception as exc:
            if isinstance(exc, SwarmCancelledError):
                raise
            _log_fallback("MultiAgentRouter", exc)
            effective_type = "SequentialWorkflow"
            run_state.swarm_type = "SequentialWorkflow (Router Fallback)"
            raw_result = _run_router("SequentialWorkflow", swarms_agents)

    else:
        effective_type = "SequentialWorkflow"
        raw_result = _run_router("SequentialWorkflow", swarms_agents)

    final_output, steps = normalize_swarm_steps(raw_result, swarms_agents)
    if not final_output.strip() and not steps and effective_type not in ("SequentialWorkflow", "RoundRobin"):
        _log_fallback(effective_type, RuntimeError("Topoloji boş çıktı döndürdü"))
        fallback_from = effective_type
        effective_type = "RoundRobin"
        run_state.swarm_type = f"RoundRobin ({fallback_from} Empty Fallback)"
        raw_result = _run_router("RoundRobin", swarms_agents)
        final_output, steps = normalize_swarm_steps(raw_result, swarms_agents)
    return effective_type, final_output, steps


def _collect_secrets(req: SwarmRunRequest) -> List[str]:
    secrets: List[str] = []
    for a in req.agents:
        secrets.append(a.provider.api_key)
        if a.fallback_provider:
            secrets.append(a.fallback_provider.api_key)
        for fp in a.fallback_providers:
            secrets.append(fp.api_key)
    if req.director:
        secrets.append(req.director.provider.api_key)
        for fp in req.director.fallback_providers:
            secrets.append(fp.api_key)
    return secrets


async def execute_swarm_request(req: SwarmRunRequest) -> Dict[str, Any]:
    """Runs a Swarms request asynchronously while recording live run telemetry."""
    global TOTAL_RUNS
    run_id = uuid.uuid4().hex[:12]
    telemetry = SwarmTelemetryCollector()
    state = RunState(
        run_id=run_id,
        swarm_type=req.swarm_type,
        task_preview=req.task[:140],
        agent_names=[a.name for a in req.agents],
        telemetry=telemetry,
    )
    ACTIVE_RUNS[run_id] = state
    TOTAL_RUNS += 1
    secrets = _collect_secrets(req)
    t0 = time.time()

    try:
        effective_type, final_output, steps = await asyncio.to_thread(
            run_swarm_sync, req, state
        )
        state.swarm_type = effective_type
        state.duration_ms = int((time.time() - t0) * 1000)
        state.final_output = final_output
        state.steps = steps
        state.status = "cancelled" if state.cancelled else "completed"
        return {
            "run_id": run_id,
            "swarm_type": effective_type,
            "status": state.status,
            "duration_ms": state.duration_ms,
            "final_output": final_output,
            "steps": steps,
            "telemetry": telemetry.to_dict(),
        }
    except Exception as exc:
        state.duration_ms = int((time.time() - t0) * 1000)
        state.status = "cancelled" if isinstance(exc, SwarmCancelledError) else "error"
        state.error = redact_secrets(str(exc), secrets)
        raise
    finally:
        ACTIVE_RUNS.pop(run_id, None)
        RUN_HISTORY.appendleft(state)


# MARK: - HTTP Endpoints

def _check_auth(request: Request) -> bool:
    expected = (os.environ.get("SWARMS_AUTH_TOKEN") or "").strip()
    if not expected:
        return True
    auth = request.headers.get("Authorization", "")
    return auth == f"Bearer {expected}"


async def health_endpoint(request: Request) -> JSONResponse:
    return JSONResponse(
        {
            "status": "ok",
            "service": "clawoffice-swarms-daemon",
            "swarms_version": getattr(swarms, "__version__", "unknown"),
            "bridge_version": BRIDGE_VERSION,
            "uptime_seconds": round(time.time() - STARTED_AT, 1),
            "active_runs": len(ACTIVE_RUNS),
            "total_runs": TOTAL_RUNS,
            "workspace_dir": str(WORKSPACE_DIR),
            "supported_swarm_types": [t["type"] for t in SUPPORTED_SWARM_TYPES],
        }
    )


async def list_types_endpoint(request: Request) -> JSONResponse:
    return JSONResponse({"swarm_types": SUPPORTED_SWARM_TYPES})


async def list_runs_endpoint(request: Request) -> JSONResponse:
    active = [r.to_summary() for r in ACTIVE_RUNS.values()]
    history = [r.to_summary() for r in RUN_HISTORY]
    return JSONResponse({"active": active, "recent": history, "total_runs": TOTAL_RUNS})


async def run_swarm_endpoint(request: Request) -> JSONResponse:
    if not _check_auth(request):
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    try:
        payload = await request.json()
        req = SwarmRunRequest.model_validate(payload)
    except Exception as exc:
        return JSONResponse({"error": f"Geçersiz istek: {exc}"}, status_code=400)

    secrets = _collect_secrets(req)
    try:
        result = await execute_swarm_request(req)
        return JSONResponse(result)
    except Exception as exc:
        return JSONResponse(
            {"error": redact_secrets(str(exc), secrets), "status": "error"},
            status_code=500,
        )


async def cancel_run_endpoint(request: Request) -> JSONResponse:
    run_id = request.path_params.get("run_id", "")
    state = ACTIVE_RUNS.get(run_id)
    if not state:
        return JSONResponse({"cancelled": False, "message": "Aktif çalışma bulunamadı"}, status_code=404)
    state.cancelled = True
    state.status = "cancelling"
    return JSONResponse({"cancelled": True, "run_id": run_id})


# MARK: - Streamable HTTP MCP Endpoint (/mcp)

MCP_TOOLS = [
    {
        "name": "swarm_status",
        "description": "Returns Swarms daemon uptime, version, active runs, and supported architectures.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "swarm_list_types",
        "description": "Lists all supported Swarms topologies (SequentialWorkflow, ConcurrentWorkflow, HierarchicalSwarm, DebateWithJudge, etc.).",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "swarm_recent_runs",
        "description": "Returns recent and active Swarms multi-agent executions.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "swarm_run",
        "description": "Executes a Swarms multi-agent workflow (`task`, optional `swarm_type`, `agents`, `max_loops`).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {"type": "string", "description": "Task prompt for the swarm."},
                "swarm_type": {"type": "string", "description": "Swarm topology name or 'Auto'."},
                "max_loops": {"type": "integer", "description": "Iterations (1-6)."},
                "agents": {"type": "array", "description": "Optional AgentSpec objects."},
            },
            "required": ["task"],
        },
    },
]


def _default_mcp_agent() -> AgentSpec:
    agy = resolve_agy_binary()
    if agy:
        return AgentSpec(
            name="SwarmLead",
            title="Swarms Otonom Lideri",
            model_name="gemini-4-hydrogen-high",
            provider=ProviderSpec(kind="antigravityCLI", name="Antigravity CLI", base_url=agy),
        )
    api_key = os.environ.get("OPENROUTER_API_KEY") or os.environ.get("OPENAI_API_KEY") or ""
    base_url = "https://openrouter.ai/api/v1" if os.environ.get("OPENROUTER_API_KEY") else "https://api.openai.com/v1"
    model = "openrouter/free" if os.environ.get("OPENROUTER_API_KEY") else "gpt-4o-mini"
    return AgentSpec(
        name="SwarmLead",
        title="Swarms Otonom Lideri",
        model_name=model,
        provider=ProviderSpec(kind="custom", base_url=base_url, api_key=api_key, model_name=model),
    )


async def mcp_endpoint(request: Request) -> Response:
    if not _check_auth(request):
        return JSONResponse({"error": "Unauthorized"}, status_code=401)
    try:
        msg = await request.json()
    except Exception:
        return JSONResponse({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}, status_code=400)

    mid = msg.get("id")
    method = msg.get("method", "")
    params = msg.get("params") or {}
    session_id = request.headers.get("Mcp-Session-Id") or uuid.uuid4().hex
    headers = {"Mcp-Session-Id": session_id}

    if method == "initialize":
        return JSONResponse(
            {
                "jsonrpc": "2.0",
                "id": mid,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {
                        "name": "clawoffice-swarms-mcp",
                        "version": getattr(swarms, "__version__", "1.0.0"),
                    },
                },
            },
            headers=headers,
        )

    if method == "notifications/initialized":
        return JSONResponse({}, status_code=202, headers=headers)

    if method == "ping":
        return JSONResponse({"jsonrpc": "2.0", "id": mid, "result": {}}, headers=headers)

    if method == "tools/list":
        return JSONResponse({"jsonrpc": "2.0", "id": mid, "result": {"tools": MCP_TOOLS}}, headers=headers)

    if method == "tools/call":
        tool_name = params.get("name", "")
        args = params.get("arguments") or {}
        if tool_name == "swarm_status":
            payload = {
                "status": "ok",
                "swarms_version": getattr(swarms, "__version__", "unknown"),
                "uptime_seconds": round(time.time() - STARTED_AT, 1),
                "active_runs": len(ACTIVE_RUNS),
                "total_runs": TOTAL_RUNS,
            }
            return JSONResponse(
                {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False, indent=2)}]}},
                headers=headers,
            )
        if tool_name == "swarm_list_types":
            return JSONResponse(
                {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": json.dumps(SUPPORTED_SWARM_TYPES, ensure_ascii=False, indent=2)}]}},
                headers=headers,
            )
        if tool_name == "swarm_recent_runs":
            data = {"active": [r.to_summary() for r in ACTIVE_RUNS.values()], "recent": [r.to_summary() for r in RUN_HISTORY]}
            return JSONResponse(
                {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False, indent=2)}]}},
                headers=headers,
            )
        if tool_name == "swarm_run":
            task = str(args.get("task", "")).strip()
            if not task:
                return JSONResponse(
                    {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "task parametresi gerekli"}},
                    headers=headers,
                )
            raw_agents = args.get("agents") or []
            parsed_agents = [AgentSpec.model_validate(a) for a in raw_agents] if raw_agents else [_default_mcp_agent()]
            req = SwarmRunRequest(
                task=task,
                swarm_type=str(args.get("swarm_type", "Auto")),
                max_loops=int(args.get("max_loops", 1)),
                agents=parsed_agents,
            )
            try:
                res = await execute_swarm_request(req)
                return JSONResponse(
                    {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False, indent=2)}]}},
                    headers=headers,
                )
            except Exception as exc:
                return JSONResponse(
                    {"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": redact_secrets(str(exc), _collect_secrets(req))}},
                    headers=headers,
                )

        return JSONResponse(
            {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"Bilinmeyen MCP aracı: {tool_name}"}},
            headers=headers,
        )

    return JSONResponse(
        {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"Desteklenmeyen metot: {method}"}},
        headers=headers,
    )


app = Starlette(
    routes=[
        Route("/health", health_endpoint, methods=["GET"]),
        Route("/v1/swarm/types", list_types_endpoint, methods=["GET"]),
        Route("/v1/swarm/runs", list_runs_endpoint, methods=["GET"]),
        Route("/v1/swarm/run", run_swarm_endpoint, methods=["POST"]),
        Route("/v1/swarm/cancel/{run_id}", cancel_run_endpoint, methods=["POST"]),
        Route("/mcp", mcp_endpoint, methods=["POST"]),
    ]
)


def main() -> None:
    if "--help" in sys.argv:
        print("Usage: swarms_bridge.py [--host 127.0.0.1] [--port 8765]")
        return
    host = DEFAULT_HOST
    port = DEFAULT_PORT
    if "--host" in sys.argv:
        idx = sys.argv.index("--host")
        if idx + 1 < len(sys.argv):
            host = sys.argv[idx + 1]
    if "--port" in sys.argv:
        idx = sys.argv.index("--port")
        if idx + 1 < len(sys.argv):
            port = int(sys.argv[idx + 1])

    uvicorn.run(app, host=host, port=port, log_level="warning")


if __name__ == "__main__":
    main()
